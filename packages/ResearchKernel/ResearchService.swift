import Foundation
import ResearchContracts
import ResearchStore
import ComputeController
import ExperimentManager
import EvidenceEngine
import AuthCoordinator

public actor ResearchService: ResearchOrchestrating {
    public let store: ResearchDatabase
    public let compute: LocalCompute
    public let accounts: Accounts
    public let artifacts: ArtifactStore
    private var running: [UUID: Task<Void, Never>] = [:]
    public let root: URL
    public init(root: URL, worker: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        store = try ResearchDatabase(path: root.appendingPathComponent("research.sqlite").path)
        compute = try LocalCompute(root: root.appendingPathComponent("worker"), worker: worker)
        accounts = Accounts(root: root)
        artifacts = try ArtifactStore(root: root.appendingPathComponent("objects"))
    }
    public func recover() async throws {
        for var invocation in try await store.invocations() where invocation.state == .running || invocation.state == .queued {
            invocation.state = .unknown
            try await store.checkpoint(invocation)
        }
        for var state in try await store.list() where state.operation.occupiesSlot {
            state.operation = .unknown
            state.lastError = "Service restarted; reconcile persisted worker evidence before resubmission"
            state = try await store.update(state, expected: state.revision, kind: "recovery.required", detail: state.lastError!)
            try await reconcile(ResearchCommand(id: state.id, revision: state.revision))
        }
    }
    public func createResearch(_ contract: ResearchContract) async throws -> UUID {
        guard !contract.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NormaError.invalid("Research title required") }
        let active = try await store.list().filter { $0.phase != .finished && $0.operation != .cancelled }
        guard active.count < 4 else { throw NormaError.forbidden("Maximum four active topics") }
        return try await store.create(contract).id
    }
    public func snapshot(_ id: UUID) async throws -> ResearchSnapshot { try await store.snapshot(id) }
    public func list() async throws -> [ResearchSnapshot] { try await store.list() }
    public func prepareSmoke(_ command: ResearchCommand) async throws -> ResearchSnapshot {
        var state = try await store.snapshot(command.id)
        guard state.revision == command.revision, !state.operation.occupiesSlot else { throw NormaError.conflict }
        let data = Data("[[0,1],[1,3],[2,5],[3,7],[4,9]]".utf8)
        var plan = ExperimentPlan(researchID: state.id, contractVersion: state.contract.version, kind: .subset,
            question: "Fit y=2x+1 to five points and independently reproduce the analytic solution",
            datasetHash: Codec.hash(data), codeHash: try await compute.workerHash(),
            protocolHash: Codec.hash(Data("least-squares-five-points-v1".utf8)), runtimeSeconds: 30)
        let code = try await artifacts.put(Data(contentsOf: compute.worker), kind: .code, researchID: state.id)
        let dataset = try await artifacts.put(data, kind: .data, researchID: state.id)
        let protocolArtifact = try await artifacts.put(Data("least-squares-five-points-v1".utf8), kind: .protocolDefinition, researchID: state.id)
        guard code.hash == plan.codeHash else { throw NormaError.forbidden("Worker changed while freezing plan") }
        plan.frozen = true; state.plan = plan; state.operation = .waitingApproval
        state.phase = .created; state.manuscript = ""; state.metaAccepted = false
        state.preflight = nil; state.authorization = nil; state.outcome = nil; state.integrity = []; state.exportConfirmed = false
        state.confirmedPlanHash = nil; state.selectedTargetID = nil
        return try await store.update(state, expected: command.revision, kind: "plan.frozen", detail: plan.hash, artifacts: [code, dataset, protocolArtifact])
    }
    public func confirmPlan(_ command: ResearchCommand) async throws -> ResearchSnapshot {
        var state = try await store.snapshot(command.id)
        guard state.revision == command.revision, !state.operation.occupiesSlot, let plan = state.plan, plan.frozen else { throw NormaError.conflict }
        if state.confirmedPlanHash == plan.hash { return state }
        state.confirmedPlanHash = plan.hash; state.selectedTargetID = nil; state.preflight = nil; state.authorization = nil
        return try await store.update(state, expected: command.revision, kind: "plan.userConfirmed", detail: plan.hash)
    }
    public func selectLocal(_ command: ResearchCommand) async throws -> ResearchSnapshot {
        var state = try await store.snapshot(command.id)
        guard state.revision == command.revision, !state.operation.occupiesSlot, let plan = state.plan,
              state.confirmedPlanHash == plan.hash else { throw NormaError.forbidden("Confirm the frozen plan before selecting a target") }
        if state.selectedTargetID == "local" { return state }
        state.selectedTargetID = "local"; state.preflight = nil; state.authorization = nil
        return try await store.update(state, expected: command.revision, kind: "target.userSelected", detail: "local")
    }
    public func preflight(_ command: ResearchCommand) async throws -> ResearchSnapshot {
        var state = try await store.snapshot(command.id)
        guard state.revision == command.revision, !state.operation.occupiesSlot, let plan = state.plan, plan.frozen else { throw NormaError.conflict }
        guard state.confirmedPlanHash == plan.hash, state.selectedTargetID == "local" else { throw NormaError.forbidden("Plan confirmation and explicit target selection required") }
        let environment = try await compute.discover()
        state.preflight = TargetPreflightReport(planHash: plan.hash, targetID: "local", fingerprint: environment.fingerprint,
            checks: [Check("Python", environment.version.isEmpty ? .fail : .pass, environment.version),
                     Check("Disk", environment.freeBytes > 1_048_576 ? .pass : .fail, String(environment.freeBytes)),
                     Check("Scope", .pass, "Five points, local CPU, no model invocation"),
                     Check("Code", plan.codeHash == (try await compute.workerHash()) ? .pass : .fail, plan.codeHash)])
        return try await store.update(state, expected: command.revision, kind: "preflight.completed", detail: state.preflight!.passed ? "pass" : "fail")
    }
    public func authorize(_ command: AuthorizeCommand) async throws -> ResearchSnapshot {
        var state = try await store.snapshot(command.authorization.researchID)
        var auth = command.authorization
        guard state.revision == command.revision, state.plan?.frozen == true, auth.contractVersion == state.contract.version,
              state.confirmedPlanHash == state.plan?.hash, state.selectedTargetID == "local",
              auth.target == (await compute.node()), auth.maxRuns >= 2, auth.maxRuns <= 100,
              !state.operation.occupiesSlot, !auth.revoked, auth.maxModelCalls == 0, auth.expiresAt > Date(), auth.maxRuntimeSeconds == 30,
              state.preflight?.passed == true, state.preflight!.validUntil > Date(), state.preflight!.planHash == state.plan!.hash,
              auth.environmentFingerprint == state.preflight?.environmentFingerprint else { throw NormaError.forbidden("Authorization outside local smoke scope") }
        auth.usedRuns = 0; auth.usedModelCalls = 0
        state.authorization = auth; state.operation = .ready
        return try await store.update(state, expected: command.revision, kind: "authorization.userApproved", detail: auth.id.uuidString)
    }
    public func startSmoke(_ command: ResearchCommand) async throws {
        var state = try await store.snapshot(command.id)
        guard state.revision == command.revision, running[state.id] == nil, state.operation == .ready, let plan = state.plan else { throw NormaError.conflict }
        if state.runs.contains(where: { $0.planHash == plan.hash }) { return }
        guard plan.codeHash == (try await compute.workerHash()) else { throw NormaError.forbidden("Worker changed after plan freeze") }
        let environment = try await compute.discover()
        try ExecutionGate.validate(plan: plan, authorization: state.authorization, preflight: state.preflight,
            currentFingerprint: environment.fingerprint, reservedRuns: (state.authorization?.usedRuns ?? state.reservedRuns) + 1)
        let nextUsedRuns = (state.authorization?.usedRuns ?? state.reservedRuns) + 2
        state.authorization?.usedRuns = nextUsedRuns
        state.reservedRuns += 2; state.operation = .running; state.phase = .subset
        state = try await store.update(state, expected: command.revision, kind: "smoke.queued", detail: "Reserved two bounded runs; zero model calls",
            dispatch: (key: plan.id.uuidString, hash: plan.hash, payload: try Codec.encode(plan)))
        let id = state.id
        running[id] = Task { await self.runSmoke(id, environment: environment) }
    }
    private func runSmoke(_ id: UUID, environment: EnvironmentSnapshot) async {
        defer { running.removeValue(forKey: id) }
        do {
            var results: [ExperimentRun] = []
            for independent in [false, true] {
                try Task.checkCancellation()
                var state = try await store.snapshot(id)
                guard let plan = state.plan, let auth = state.authorization, !auth.revoked, auth.expiresAt > Date(),
                      state.operation == .running else { throw NormaError.cancelled }
                var run = ExperimentRun(kind: independent ? .reproduction : .subset, plan: plan, environment: environment)
                run.state = .running; state.runs.append(run)
                _ = try await store.update(state, expected: state.revision, kind: "run.started", detail: run.id.uuidString)
                let value = try await compute.fit(runID: run.id, environment: environment, independent: independent, expiresAt: auth.expiresAt)
                run = try await recordResult(value, run: run, researchID: id)
                results.append(run)
            }
            let state = try await store.snapshot(id)
            guard state.operation == .running else { throw NormaError.cancelled }
            try await completeSmoke(state, results: results)
        } catch {
            if var state = try? await store.snapshot(id) {
                state.operation = error is CancellationError || (error as? NormaError) == .cancelled ? .cancelled : .failed
                state.lastError = error.localizedDescription
                for index in state.runs.indices where state.runs[index].state == .running {
                    state.runs[index].state = .unknown
                }
                if state.runs.contains(where: { $0.state == .unknown }) { state.operation = .unknown }
                _ = try? await store.update(state, expected: state.revision, kind: "execution.stopped", detail: error.localizedDescription)
            }
        }
    }
    private func recordResult(_ value: JSONValue, run original: ExperimentRun, researchID: UUID) async throws -> ExperimentRun {
        var run = original
        let workerRoot = await compute.root
        guard let environment = run.environment, let path = value["artifactPath"].string, let hash = value["artifactHash"].string,
              path == workerRoot.appendingPathComponent("runs/" + run.id.uuidString + "/result.json").path else {
            throw NormaError.invalid("Missing or mismatched worker evidence")
        }
        try EvidenceValidator.file(path: path, expectedHash: hash, allowedRoot: workerRoot)
        if let previous = run.artifactHash, previous != hash { throw NormaError.invalid("Previously recorded evidence changed") }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let document = try Codec.decode(JSONValue.self, from: bytes)
        guard document["workerHash"].string == run.codeHash,
              document["environmentFingerprint"].string == run.environmentFingerprint,
              document["samples"] == .number(5), document["batch"] == .number(1), document["seed"] == .number(0),
              document["steps"] == .number(0), document["exitCode"] == .number(0),
              document["independent"] == .bool(run.kind == .reproduction) else { throw NormaError.invalid("Run provenance mismatch") }
        for name in ["slope", "intercept", "mse"] {
            guard case .number(let number) = document["metrics"][name], number.isFinite else { throw NormaError.invalid("Missing finite metric") }
            run.metrics[name] = number
        }
        let metric = try await artifacts.put(bytes, kind: .metric, researchID: researchID)
        let stored = try await store.artifacts(researchID)
        var sources: [EvidenceArtifact] = []
        for expected in [run.codeHash, run.dataHash, run.protocolHash] {
            guard let artifact = stored.first(where: { $0.hash == expected }) else { throw NormaError.invalid("Missing frozen input evidence") }
            _ = try await artifacts.read(artifact, researchID: researchID)
            sources.append(artifact)
        }
        sources.append(try await artifacts.put(Codec.encode(environment), kind: .environment, researchID: researchID))
        run.state = .succeeded; run.finishedAt = Date(); run.artifactPath = path; run.artifactHash = hash
        var state = try await store.snapshot(researchID)
        guard let index = state.runs.firstIndex(where: { $0.id == run.id }), state.runs[index].planHash == run.planHash else { throw NormaError.invalid("Run identity changed") }
        state.runs[index] = run
        _ = try await store.update(state, expected: state.revision, kind: "run.completed", detail: run.id.uuidString,
            artifacts: [metric] + sources, edges: sources.map { EvidenceEdge(sourceHash: metric.hash, targetHash: $0.hash, relation: "derivedFrom") })
        return run
    }
    private func completeSmoke(_ initial: ResearchSnapshot, results: [ExperimentRun]) async throws {
        guard results.count == 2, let original = results.first(where: { $0.kind == .subset }),
              let reproduction = results.first(where: { $0.kind == .reproduction }) else { throw NormaError.invalid("Incomplete smoke execution") }
        var state = initial
        state.integrity = EvidenceValidator.smoke(original: original, reproduction: reproduction)
        guard state.integrity.filter({ $0.id == "I1" || $0.id == "I2" }).allSatisfy({ $0.status == .pass }) else { throw NormaError.invalid("Numerical evidence failed verification") }
        state.phase = .finished; state.operation = .succeeded; state.outcome = .smokeVerified; state.lastError = nil
        state.manuscript = "Known solved numerical verification: five points on y = 2x + 1. Normal equations and an independent centered-covariance rerun agree. This is a connectivity/evidence smoke, not a scientific novelty claim or full paper audit."
        _ = try await store.update(state, expected: state.revision, kind: "smoke.completed", detail: "I1/I2 verified; I3/I4 remain unknown")
        if let plan = state.plan { try await store.acknowledge(plan.id.uuidString) }
    }
    public func reconcile(_ command: ResearchCommand) async throws {
        var state = try await store.snapshot(command.id)
        guard state.revision == command.revision, state.operation == .unknown, running[state.id] == nil else { throw NormaError.conflict }
        guard let plan = state.plan else { return }
        for run in state.runs where run.planHash == plan.hash {
            do {
                let value = try await compute.recover(run.id)
                _ = try await recordResult(value, run: run, researchID: state.id)
            } catch {
                // An unresolved worker claim never authorizes another submission.
                state = try await store.snapshot(state.id)
                state.lastError = "Worker result cannot yet be reconciled: " + error.localizedDescription
                _ = try await store.update(state, expected: state.revision, kind: "recovery.unresolved", detail: state.lastError!)
                return
            }
        }
        state = try await store.snapshot(state.id)
        let completed = state.runs.filter { $0.planHash == plan.hash && $0.state == .succeeded }
        if completed.count == 2 {
            if state.authorization?.revoked == true {
                state.operation = .cancelled; state.lastError = nil
                _ = try await store.update(state, expected: state.revision, kind: "recovery.cancelled", detail: "Worker results recovered; authorization remains revoked")
                try await store.acknowledge(plan.id.uuidString)
            } else { try await completeSmoke(state, results: completed) }
        }
    }
    public func pause(_ id: UUID, expectedRevision: Int) async throws {
        var state = try await store.snapshot(id)
        guard state.revision == expectedRevision else { throw NormaError.conflict }
        guard !state.operation.occupiesSlot, state.phase != .finished, state.operation != .cancelled else { throw NormaError.forbidden("Cannot pause active or terminal execution") }
        state.operation = .paused
        _ = try await store.update(state, expected: expectedRevision, kind: "research.paused", detail: "User action")
    }
    public func resume(_ id: UUID, expectedRevision: Int) async throws {
        var state = try await store.snapshot(id)
        guard state.operation == .paused, state.phase != .finished else { throw NormaError.invalid("Research is not paused") }
        state.operation = .ready
        _ = try await store.update(state, expected: expectedRevision, kind: "research.resumed", detail: "User action")
    }
    public func cancel(_ id: UUID, expectedRevision: Int) async throws {
        var state = try await store.snapshot(id)
        state.authorization?.revoked = true
        state.operation = running[id] != nil ? .cancelPending : state.operation == .unknown ? .unknown : .cancelled
        _ = try await store.update(state, expected: expectedRevision, kind: "research.cancelRequested", detail: "Authorization revoked")
        running[id]?.cancel()
    }
    public func revise(_ contract: ResearchContract, expected: Int) async throws -> ResearchSnapshot {
        try contract.profile.validate()
        guard !contract.title.isEmpty, !contract.question.isEmpty, !contract.metric.isEmpty else { throw NormaError.invalid("Contract fields cannot be empty") }
        var state = try await store.snapshot(contract.id)
        guard !state.operation.occupiesSlot, contract.version == state.contract.version + 1 else { throw NormaError.forbidden("Stop active execution before revising contract") }
        state.contract = contract; state.authorization = nil; state.plan = nil; state.preflight = nil
        state.confirmedPlanHash = nil; state.selectedTargetID = nil
        state.operation = .ready; state.phase = .created; state.outcome = nil; state.integrity = []; state.exportConfirmed = false
        return try await store.update(state, expected: expected, kind: "contract.revised", detail: String(contract.version))
    }
    public func confirmExport(_ command: ResearchCommand) async throws -> ResearchSnapshot {
        var state = try await store.snapshot(command.id)
        state.exportConfirmed = true
        guard state.exportReady else { throw NormaError.forbidden("Research has not passed the export gate") }
        return try await store.update(state, expected: command.revision, kind: "export.userConfirmed", detail: "Contract v" + String(state.contract.version))
    }
    public func handle(_ request: IPCRequest) async -> IPCResponse {
        do {
            guard request.version == 1, request.payload.count <= 2_000_000 else { throw NormaError.invalid("Unsupported IPC envelope") }
            func decode<T: Decodable>(_ type: T.Type) throws -> T { try Codec.decode(type, from: request.payload) }
            let payload: Data
            switch request.method {
            case "research.list": payload = try Codec.encode(await list())
            case "research.create": payload = try Codec.encode(await createResearch(decode(ResearchContract.self)))
            case "research.snapshot": payload = try Codec.encode(await snapshot(decode(UUID.self)))
            case "contract.revise":
                let command = try decode(ReviseCommand.self)
                payload = try Codec.encode(await revise(command.contract, expected: command.revision))
            case "storage.backup":
                payload = try Codec.encode(await ResearchArchive.backup(database: store, objects: artifacts, directory: root.appendingPathComponent("Backups")).path)
            case "export.confirm": payload = try Codec.encode(await confirmExport(decode(ResearchCommand.self)))
            case "export.bundle":
                let command = try decode(ResearchCommand.self)
                let state = try await store.snapshot(command.id)
                guard state.revision == command.revision else { throw NormaError.conflict }
                payload = try Codec.encode(await ResearchArchive.export(state, database: store, objects: artifacts, directory: root.appendingPathComponent("Exports")).path)
            case "smoke.prepare": payload = try Codec.encode(await prepareSmoke(decode(ResearchCommand.self)))
            case "plan.confirm": payload = try Codec.encode(await confirmPlan(decode(ResearchCommand.self)))
            case "target.selectLocal": payload = try Codec.encode(await selectLocal(decode(ResearchCommand.self)))
            case "target.preflight": payload = try Codec.encode(await preflight(decode(ResearchCommand.self)))
            case "target.authorize": payload = try Codec.encode(await authorize(decode(AuthorizeCommand.self)))
            case "smoke.start": try await startSmoke(decode(ResearchCommand.self)); payload = try Codec.encode(Empty())
            case "research.reconcile": try await reconcile(decode(ResearchCommand.self)); payload = try Codec.encode(Empty())
            case "evidence.list": payload = try Codec.encode(await store.artifacts(decode(UUID.self)))
            case "evidence.edges": payload = try Codec.encode(await store.edges(decode(UUID.self)))
            case "research.pause", "research.resume", "research.cancel":
                let cmd = try decode(ResearchCommand.self)
                if request.method == "research.pause" { try await pause(cmd.id, expectedRevision: cmd.revision) }
                else if request.method == "research.resume" { try await resume(cmd.id, expectedRevision: cmd.revision) }
                else { try await cancel(cmd.id, expectedRevision: cmd.revision) }
                payload = try Codec.encode(Empty())
            case "environment.local": payload = try Codec.encode(await compute.discover())
            case "target.local": payload = try Codec.encode(await compute.node())
            case "account.status": payload = try Codec.encode(await accounts.status((try? decode(String.self)) ?? "chatgpt"))
            case "account.login": payload = try Codec.encode(await accounts.loginURL())
            case "account.apiLogin":
                try await accounts.loginAPI(key: decode(String.self))
                payload = try Codec.encode(await accounts.status("api"))
            case "model.list": payload = try Codec.encode(await accounts.models((try? decode(String.self)) ?? "chatgpt"))
            default: throw NormaError.invalid("Unsupported service method")
            }
            return IPCResponse(id: request.id, payload: payload)
        } catch { return IPCResponse(id: request.id, error: (error as? NormaError) ?? .unavailable(error.localizedDescription)) }
    }
}
