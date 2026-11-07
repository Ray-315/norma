import Foundation
import Security
import ResearchContracts
import ResearchKernel

final class ConnectionHandler: NSObject, ResearchXPCProtocol, @unchecked Sendable {
    let service: ResearchService
    init(service: ResearchService) { self.service = service }
    func request(_ data: Data, reply: @escaping (Data) -> Void) {
        let callback = Callback(reply)
        guard data.count <= 2_000_000, let request = try? Codec.decode(IPCRequest.self, from: data) else {
            callback.invoke(Data()); return
        }
        Task { let response = await service.handle(request); callback.invoke((try? Codec.encode(response)) ?? Data()) }
    }
}
final class Callback: @unchecked Sendable {
    let block: (Data) -> Void
    init(_ block: @escaping (Data) -> Void) { self.block = block }
    func invoke(_ data: Data) { block(data) }
}
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let handler: ConnectionHandler
    init(service: ResearchService) { handler = ConnectionHandler(service: service) }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid(), trusted(pid: connection.processIdentifier) else { return false }
        connection.exportedInterface = NSXPCInterface(with: ResearchXPCProtocol.self)
        connection.exportedObject = handler; connection.resume(); return true
    }
    private func trusted(pid: pid_t) -> Bool {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { return false }
        var own: SecStaticCode?, peer: SecCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &own) == errSecSuccess, let own,
              SecCodeCopyDesignatedRequirement(own, [], &requirement) == errSecSuccess,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &peer) == errSecSuccess,
              let peer, let requirement else { return false }
        return SecCodeCheckValidity(peer, [], requirement) == errSecSuccess
    }
}

let root = ProcessInfo.processInfo.environment["NORMA_DATA_ROOT"].map { URL(fileURLWithPath: $0) } ??
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NORMA")
let override = ProcessInfo.processInfo.environment["NORMA_WORKER"]
let worker = override.map { URL(fileURLWithPath: $0) } ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/worker.py")
do {
    let accountRoot = ProcessInfo.processInfo.environment["NORMA_ACCOUNT_ROOT"].map { URL(fileURLWithPath: $0) }
    let service = try ResearchService(root: root, worker: worker, accountRoot: accountRoot)
    if ProcessInfo.processInfo.arguments.contains("--autonomy-account-check") {
        Task {
            do {
                let account = try await service.accounts.status("chatgpt")
                let models = try await service.accounts.models("chatgpt")
                print("ChatGPT authenticated: \(account.authenticated)")
                print("Requested model available: \(models.contains { $0.id == "gpt-6.1-sol" && $0.reasoning.contains("medium") })")
                exit(account.authenticated ? 0 : 1)
            } catch { print("Account check failed: " + error.localizedDescription); exit(1) }
        }
        RunLoop.current.run(); exit(1)
    }
    if ProcessInfo.processInfo.arguments.contains("--autonomous-live") || ProcessInfo.processInfo.arguments.contains("--autonomous-live-continue") || ProcessInfo.processInfo.arguments.contains("--autonomous-live-export") {
        // Explicit opt-in integration harness. Never reuses the production research database.
        guard ProcessInfo.processInfo.environment["NORMA_DATA_ROOT"] != nil, let accountRoot,
              root.resolvingSymlinksInPath() != accountRoot.resolvingSymlinksInPath(),
              let calls = ProcessInfo.processInfo.environment["NORMA_LIVE_CALL_LIMIT"].flatMap(Int.init), (1...40).contains(calls) else {
            throw NormaError.forbidden("Live validation requires an isolated data root and an explicit 1–40 call limit.")
        }
        Task {
            do {
                if ProcessInfo.processInfo.arguments.contains("--autonomous-live-export") {
                    let saved = try Codec.decode(ResearchSnapshot.self, from: Data(contentsOf: root.appendingPathComponent("live-research.json")))
                    let current = try await service.snapshot(saved.id)
                    guard current.authorization?.maxModelCalls == calls else { throw NormaError.forbidden("Export budget does not match the original validation") }
                    let confirmed = try await service.confirmExport(ResearchCommand(id: current.id, revision: current.revision))
                    let archive = try await ResearchArchive.export(confirmed, database: service.store, objects: service.artifacts, directory: root.appendingPathComponent("exports"))
                    try ResearchArchive.validate(archive)
                    try Codec.encode(confirmed).write(to: root.appendingPathComponent("live-research.json"), options: .atomic)
                    try Data(confirmed.manuscript.utf8).write(to: root.appendingPathComponent("report.md"), options: .atomic)
                    print("Verified export: " + archive.path)
                    exit(0)
                }
                let contract = ResearchContract(title: "真实模型验收：五个数的均值", question: "对固定数据 [1,2,3,4,5] 验证直接求和均值与增量均值算法是否得到已知答案 3，比较浮点误差。完成基线、候选验证、必要消融、中文报告和评审。不要主张新的科研发现。", metric: "绝对误差", constraints: "仅此五条数据；单批次、种子0、不训练；仅 math/statistics/random 标准库；不安装依赖、不联网、不扩大数据规模。")
                let continuation = ProcessInfo.processInfo.arguments.contains("--autonomous-live-continue")
                let saved = continuation ? try Codec.decode(ResearchSnapshot.self, from: Data(contentsOf: root.appendingPathComponent("live-research.json"))) : nil
                let id: UUID
                if let saved { id = saved.id } else { id = try await service.createResearch(contract) }
                print("Research: \(id)"); fflush(stdout)
                if let saved {
                    guard saved.authorization?.maxModelCalls == calls else { throw NormaError.forbidden("Continuation cannot enlarge the original model budget") }
                    if saved.outcome == .noContribution {
                        try await service.continueKnownVerificationReport(ResearchCommand(id: id, revision: saved.revision))
                    } else if saved.outcome == .integrityFailed {
                        let workflow = try Codec.decode(WorkflowState.self, from: saved.autonomy!.workflow)
                        if saved.events.contains(where: { $0.kind == "integrity.evidenceRecheck" }) {
                            try await service.supplementLegacyExecutionEvidence(ResearchCommand(id: id, revision: saved.revision))
                        } else if (workflow.reportRevisions ?? 0) > 0 {
                            try await service.recheckLegacyIntegrityEvidence(ResearchCommand(id: id, revision: saved.revision))
                        } else {
                            try await service.reviseFailedIntegrityReport(ResearchCommand(id: id, revision: saved.revision))
                        }
                    } else {
                        try await service.resumeAutonomous(ResearchCommand(id: id, revision: saved.revision))
                    }
                } else {
                    try await service.startAutonomous(AutonomousStart(id: id, revision: 0, maxModelCalls: calls, maxRuns: 10, knownProblem: true))
                }
                var lastRevision = -1
                let deadline = Date().addingTimeInterval(3600)
                while Date() < deadline {
                    var state = try await service.snapshot(id)
                    if state.revision != lastRevision {
                        print("Stage: \(state.phase.rawValue); state: \(state.operation.rawValue); calls: \(state.modelCalls); runs: \(state.runs.count)")
                        fflush(stdout); lastRevision = state.revision
                        try Codec.encode(state).write(to: root.appendingPathComponent("live-research.json"), options: .atomic)
                    }
                    if state.operation == .waitingApproval {
                        guard let experiment = state.autonomy?.pendingExperiment else { throw NormaError.invalid("Missing proposal") }
                        try experiment.validate()
                        guard experiment.data == .array([1,2,3,4,5].map { .number(Double($0)) }) else { throw NormaError.forbidden("Model changed the explicitly authorized dataset.") }
                        state = try await service.confirmPlan(ResearchCommand(id: id, revision: state.revision))
                        state = try await service.selectLocal(ResearchCommand(id: id, revision: state.revision))
                        state = try await service.preflight(ResearchCommand(id: id, revision: state.revision))
                        try await service.executeAutonomous(ResearchCommand(id: id, revision: state.revision))
                    } else if state.phase == .finished {
                        print("Outcome: \(state.outcome?.rawValue ?? "unknown")")
                        exit(state.outcome == .verified || state.outcome == .knownProblemVerified ? 0 : 2)
                    } else if [.failed, .unknown, .cancelled].contains(state.operation) {
                        throw NormaError.unavailable(state.lastError ?? "Live run stopped")
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
                let state = try await service.snapshot(id)
                try await service.cancel(id, expectedRevision: state.revision)
                throw NormaError.unavailable("Live validation reached the one-hour deadline")
            } catch { print("Live validation stopped: " + error.localizedDescription); exit(1) }
        }
        RunLoop.current.run(); exit(1)
    }
    if ProcessInfo.processInfo.arguments.contains("--local-smoke") {
        Task {
            do {
                let contract = ResearchContract(title: "Known solved: least-squares line", question: "Do five points on y=2x+1 recover the analytic line?", metric: "MSE")
                let id = try await service.createResearch(contract)
                var state = try await service.prepareSmoke(ResearchCommand(id: id, revision: 0))
                state = try await service.confirmPlan(ResearchCommand(id: id, revision: state.revision))
                state = try await service.selectLocal(ResearchCommand(id: id, revision: state.revision))
                state = try await service.preflight(ResearchCommand(id: id, revision: state.revision))
                guard let report = state.preflight, report.passed else { throw NormaError.unavailable("Smoke preflight failed") }
                let auth = ResearchAuthorization(researchID: id, contractVersion: 1, target: await service.compute.node(),
                    fingerprint: report.environmentFingerprint, expiresAt: Date().addingTimeInterval(300),
                    maxModelCalls: 0, maxRuns: 2, maxRuntimeSeconds: 30)
                state = try await service.authorize(AuthorizeCommand(revision: state.revision, authorization: auth))
                try await service.startSmoke(ResearchCommand(id: id, revision: state.revision))
                for _ in 0..<120 {
                    try await Task.sleep(for: .milliseconds(250))
                    state = try await service.snapshot(id)
                    if state.operation != .running { break }
                }
                let data = try Codec.encode(state)
                try data.write(to: root.appendingPathComponent("smoke-report.json"), options: .atomic)
                print("Smoke: " + state.operation.rawValue + "; model calls: " + String(state.modelCalls))
                guard state.outcome == .smokeVerified, state.runs.count == 2, state.integrity.first?.status == .pass else {
                    throw NormaError.unavailable(state.lastError ?? "Smoke incomplete")
                }
                exit(0)
            } catch { print("Smoke failed: " + error.localizedDescription); exit(1) }
        }
        RunLoop.current.run()
        exit(1)
    }
    let delegate = ListenerDelegate(service: service)
    let listener = NSXPCListener(machServiceName: "app.norma.research")
    listener.delegate = delegate
    Task { try? await service.recover() }
    listener.resume()
    RunLoop.current.run()
    withExtendedLifetime(delegate) {}
} catch {
    fputs("NORMA service initialization failed\n", stderr)
    exit(1)
}
