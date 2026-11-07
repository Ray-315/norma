import Foundation
import ResearchContracts
import EvidenceEngine
import ExperimentManager

extension ResearchService {
    public func startAutonomous(_ command: AutonomousStart) async throws {
        var state = try await store.snapshot(command.id)
        guard state.revision == command.revision, state.autonomy == nil, state.phase == .created,
              !state.operation.occupiesSlot, state.operation != .cancelled,
              state.runs.allSatisfy({ [.succeeded, .failed, .cancelled].contains($0.state) }),
              (1...200).contains(command.maxModelCalls), (2...40).contains(command.maxRuns) else { throw NormaError.forbidden("课题状态或授权额度不符合要求。") }
        let environment = try await compute.discover()
        let target = await compute.node()
        state.authorization = ResearchAuthorization(researchID: state.id, contractVersion: state.contract.version,
            target: target, fingerprint: environment.fingerprint, expiresAt: Date().addingTimeInterval(4 * 3600),
            maxModelCalls: command.maxModelCalls, maxRuns: command.maxRuns, maxRuntimeSeconds: 30)
        state.authorization?.usedModelCalls = 0; state.authorization?.usedRuns = 0
        var profile = state.contract.profile
        if command.knownProblem { profile.ideaRounds = 1; profile.successThreshold = 1 }
        var workflow = WorkflowState(profile: profile)
        workflow.knownProblem = command.knownProblem
        try workflow.apply(.contractAuthorized)
        state.autonomy = AutonomousSession(workflow: try Codec.encode(workflow), knownProblem: command.knownProblem)
        state.phase = workflow.phase; state.operation = .running; state.plan = nil; state.preflight = nil
        state.confirmedPlanHash = nil; state.selectedTargetID = nil; state.manuscript = ""; state.reviews = []; state.hypotheses = []
        _ = try await store.update(state, expected: state.revision, kind: "autonomy.started", detail: "已授权本机研究；模型与实验分别按额度计数，实验方案需确认。")
        launchAutonomous(state.id)
    }
    private func launchAutonomous(_ id: UUID) {
        running[id] = Task { await self.driveAutonomous(id) }
    }
    /// Resume the already-authorized known-problem validation after the pre-report contribution gate.
    /// Existing experiments and negative contribution findings remain unchanged.
    public func continueKnownVerificationReport(_ command: ResearchCommand) async throws {
        var state = try await store.snapshot(command.id)
        guard state.revision == command.revision, state.outcome == .noContribution,
              var session = state.autonomy, session.knownProblem, running[state.id] == nil,
              AutonomousPolicy.reproduced(state.runs.filter { $0.planHash == state.plan?.hash }) else { throw NormaError.forbidden("只能继续已有复现证据的已知问题报告。") }
        try ExecutionGate.validateModelForResume(state)
        var workflow = try Codec.decode(WorkflowState.self, from: session.workflow)
        workflow.knownProblem = true; workflow.outcome = nil; workflow.phase = .ablation
        try workflow.apply(.knownProblemComparison(verified: true))
        session.workflow = try Codec.encode(workflow); session.roleIndex = 0; session.stepID = nil
        state.autonomy = session; state.phase = .writing; state.outcome = nil; state.operation = .running
        _ = try await store.update(state, expected: state.revision, kind: "verification.reporting", detail: "保留未发现优势的结论，继续完成已知问题验证报告；不增加原授权额度。")
        launchAutonomous(state.id)
    }
    public func resumeAutonomous(_ command: ResearchCommand) async throws {
        var state = try await store.snapshot(command.id)
        guard state.revision == command.revision, state.autonomy != nil, state.phase != .finished,
              running[state.id] == nil, [.paused, .failed, .waitingAuth, .ready].contains(state.operation) else { throw NormaError.conflict }
        try ExecutionGate.validateModelForResume(state)
        state.autonomy?.requestedPause = false
        if let step = state.autonomy?.stepID {
            let record = try await store.invocations().first { $0.id == step }
            if record?.state != .succeeded { state.autonomy?.stepID = nil }
        }
        state.lastError = nil
        state.operation = state.autonomy?.pendingExperiment == nil ? .running : .waitingApproval
        _ = try await store.update(state, expected: state.revision, kind: "research.resumed", detail: "从已保存步骤继续；不会重复提交已有实验。")
        if state.operation == .running { launchAutonomous(state.id) }
    }
    /// Explicit continuation for runs completed before bounded report-revision support existed.
    public func reviseFailedIntegrityReport(_ command: ResearchCommand) async throws {
        var state = try await store.snapshot(command.id)
        guard state.revision == command.revision, state.outcome == .integrityFailed,
              var session = state.autonomy, running[state.id] == nil,
              state.integrity.first(where: { $0.id == "I1" })?.status == .pass,
              !session.history.suffix(3).contains(where: { $0.proposal.empiricalObjections == true }) else { throw NormaError.forbidden("当前核查结果不允许仅修订报告。") }
        try ExecutionGate.validateModelForResume(state)
        for object in try await store.artifacts(state.id) { _ = try await artifacts.read(object, researchID: state.id) }
        var workflow = try Codec.decode(WorkflowState.self, from: session.workflow)
        workflow.outcome = nil; workflow.phase = .integrity
        try workflow.apply(.integrityReportRevision(evidenceIntact: true))
        session.workflow = try Codec.encode(workflow); session.roleIndex = 0; session.stepID = nil
        state.autonomy = session; state.phase = .writing; state.outcome = nil; state.metaAccepted = false
        state.exportConfirmed = false; state.operation = .running; state.lastError = nil
        _ = try await store.update(state, expected: state.revision, kind: "report.revision", detail: "根据实际审计意见修订报告，保留原结果与拒绝记录，沿用剩余额度。")
        launchAutonomous(state.id)
    }
    /// One migration recheck for an earlier validation that omitted raw execution receipts from audit context.
    public func recheckLegacyIntegrityEvidence(_ command: ResearchCommand) async throws {
        var state = try await store.snapshot(command.id)
        guard state.revision == command.revision, state.outcome == .integrityFailed,
              var session = state.autonomy, running[state.id] == nil, state.metaAccepted,
              state.integrity.first(where: { $0.id == "I1" })?.status == .pass,
              !state.events.contains(where: { $0.kind == "integrity.evidenceRecheck" }) else { throw NormaError.forbidden("当前研究不能重复迁移核查。") }
        try ExecutionGate.validateModelForResume(state)
        for object in try await store.artifacts(state.id) { _ = try await artifacts.read(object, researchID: state.id) }
        var workflow = try Codec.decode(WorkflowState.self, from: session.workflow)
        workflow.outcome = nil; workflow.phase = .integrity
        session.workflow = try Codec.encode(workflow); session.roleIndex = 0; session.stepID = nil
        state.autonomy = session; state.phase = .integrity; state.outcome = nil; state.operation = .running
        state.exportConfirmed = false; state.lastError = nil
        _ = try await store.update(state, expected: state.revision, kind: "integrity.evidenceRecheck", detail: "补齐原始执行清单后进行一次迁移核查；不改动报告、实验、旧意见或剩余额度。")
        launchAutonomous(state.id)
    }
    /// Migrate a report written before raw receipt context was supplied. The original manuscript
    /// remains immutable; a clearly attributed evidence supplement must pass the full review chain.
    public func supplementLegacyExecutionEvidence(_ command: ResearchCommand) async throws {
        var state = try await store.snapshot(command.id)
        guard state.revision == command.revision, state.outcome == .integrityFailed,
              var session = state.autonomy, running[state.id] == nil,
              state.events.contains(where: { $0.kind == "integrity.evidenceRecheck" }),
              !state.events.contains(where: { $0.kind == "report.evidenceSupplement" }),
              let auth = state.authorization, auth.maxModelCalls - (auth.usedModelCalls ?? 0) >= 6 else {
            throw NormaError.forbidden("证据补充要求已有迁移核查记录、未补充过的报告及至少六次剩余评审额度。")
        }
        try ExecutionGate.validateModelForResume(state)
        let evidence = try await store.artifacts(state.id)
        var rows: [String] = []
        for run in state.runs where run.state == .succeeded {
            guard let hash = run.artifactHash, let object = evidence.first(where: { $0.hash == hash && $0.kind == .metric }) else { throw NormaError.invalid("缺少执行清单。") }
            let record = try Codec.decode(JSONValue.self, from: await artifacts.read(object, researchID: state.id))
            let scope: JSONValue = .object(["samples": record["samples"], "batch": record["batch"], "seed": record["seed"], "steps": record["steps"]])
            rows.append("- 运行 \(run.id.uuidString)：\(String(decoding: try Codec.encode(scope), as: UTF8.self))；原始清单 SHA-256：\(hash)")
        }
        guard !rows.isEmpty else { throw NormaError.invalid("缺少可补充的实际运行证据。") }
        let supplement = """
        # 执行证据更正说明

        本说明由应用直接读取并校验已保存的原始执行清单生成，不是模型新提出的实验结论。本次没有追加实验或修改原始运行记录；此前稿件、失败记录和拒绝意见继续保留。

        原稿曾依据不包含执行清单的简化记录，写出“记录未单列实际种子值”“实际种子证据不足”等表述。这些关于证据缺失的表述现予更正，并以本说明取代：以下实际执行器清单包含样本数 samples、批次 batch、种子 seed 和训练步数 steps。它们证明执行器记录了相应设置，不代表审稿模型重新运行程序或独立测量运行时状态。成功代码自身没有随机操作或种子设置语句的描述仍成立；执行器设置与模型代码设置应区分。

        \(rows.joined(separator: "\n"))

        以下保留前稿内容用于追溯，其中关于种子记录缺失的陈述已由上文明确更正。数值结论与适用范围没有改变，历史失败仍未被追认为合规。本补充版须重新经过同行评审、综合评审和四项核查；接受状态以针对本补充版其后保存的记录为准。

        ---

        """
        state.manuscript = supplement + state.manuscript
        let object = try await artifacts.put(Data(state.manuscript.utf8), kind: .manuscript, researchID: state.id)
        var workflow = try Codec.decode(WorkflowState.self, from: session.workflow)
        workflow.outcome = nil; workflow.phase = .writing; workflow.metaAccepted = false
        try workflow.apply(.manuscript(evidenceComplete: true))
        session.workflow = try Codec.encode(workflow); session.roleIndex = 0; session.stepID = nil
        state.autonomy = session; state.phase = workflow.phase; state.outcome = nil; state.operation = .running
        state.metaAccepted = false; state.exportConfirmed = false; state.lastError = nil
        _ = try await store.update(state, expected: state.revision, kind: "report.evidenceSupplement", detail: "根据原始执行清单生成具名证据更正，旧稿保留，完整重审；不增加额度。", artifacts: [object])
        launchAutonomous(state.id)
    }
    public func preflightAutonomous(_ command: ResearchCommand) async throws -> ResearchSnapshot {
        var state = try await store.snapshot(command.id)
        guard state.revision == command.revision, !state.operation.occupiesSlot, let plan = state.plan,
              state.autonomy?.pendingExperiment != nil, state.confirmedPlanHash == plan.hash, state.selectedTargetID == "local" else { throw NormaError.conflict }
        let environment = try await compute.discover()
        let saved = try await store.artifacts(state.id)
        guard let runnerHash = plan.runnerHash, runnerHash == (try await compute.workerHash()) else { throw NormaError.forbidden("实验执行器已变化，请重新确认方案。") }
        for hash in [plan.codeHash, plan.datasetHash, plan.protocolHash, runnerHash] {
            guard let object = saved.first(where: { $0.hash == hash }) else { throw NormaError.invalid("实验依据缺失。") }
            _ = try await artifacts.read(object, researchID: state.id)
        }
        state.preflight = TargetPreflightReport(planHash: plan.hash, targetID: "local", fingerprint: environment.fingerprint,
            checks: [Check("Python", .pass, environment.version), Check("Code", .pass, "已核对冻结代码、数据与方案"),
                     Check("Scope", .pass, "本机受限 Python；最多 5 条数据、1 批次、1 种子、不训练；每次最多 30 秒"),
                     Check("Sandbox", FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") ? .pass : .fail, "禁止网络、外部程序和用户目录访问")])
        // Environment changes require a new research authorization, not silently rebinding an old one.
        if state.authorization?.environmentFingerprint != environment.fingerprint {
            state.preflight?.checks.append(Check("Environment", .fail, "运行环境已变化，请重新授权课题。"))
        }
        return try await store.update(state, expected: state.revision, kind: "preflight.completed", detail: state.preflight!.passed ? "pass" : "fail")
    }
    public func executeAutonomous(_ command: ResearchCommand) async throws {
        var state = try await store.snapshot(command.id)
        guard state.revision == command.revision, running[state.id] == nil, state.operation == .waitingApproval,
              state.autonomy?.pendingExperiment != nil, let plan = state.plan, state.confirmedPlanHash == plan.hash,
              state.selectedTargetID == "local", state.autonomy?.pendingRunIDs.isEmpty == true else { throw NormaError.conflict }
        let environment = try await compute.discover()
        try ExecutionGate.validate(plan: plan, authorization: state.authorization, preflight: state.preflight,
            currentFingerprint: environment.fingerprint, reservedRuns: (state.authorization?.usedRuns ?? 0) + 1)
        let original = ExperimentRun(kind: plan.kind, plan: plan, environment: environment)
        let reproduction = ExperimentRun(kind: .reproduction, plan: plan, environment: environment)
        state.autonomy?.pendingRunIDs = [original.id, reproduction.id]
        state.runs += [original, reproduction]
        let usedRuns = (state.authorization?.usedRuns ?? 0) + 2
        state.authorization?.usedRuns = usedRuns; state.reservedRuns += 2
        state.operation = .running
        _ = try await store.update(state, expected: state.revision, kind: "run.authorized", detail: plan.hash,
            dispatch: (key: plan.id.uuidString, hash: plan.hash, payload: try Codec.encode(plan)))
        running[state.id] = Task { await self.runAutonomousExperiments(state.id, environment: environment) }
    }
    private func runAutonomousExperiments(_ id: UUID, environment: EnvironmentSnapshot) async {
        defer { running.removeValue(forKey: id) }
        do {
            let initial = try await store.snapshot(id)
            guard let session = initial.autonomy, let proposal = session.pendingExperiment, let plan = initial.plan else { throw NormaError.conflict }
            for runID in session.pendingRunIDs {
                try Task.checkCancellation()
                var state = try await store.snapshot(id)
                guard state.operation == .running, let auth = state.authorization, !auth.revoked, auth.expiresAt > Date(),
                      let index = state.runs.firstIndex(where: { $0.id == runID }) else { throw NormaError.cancelled }
                state.runs[index].state = .running
                _ = try await store.update(state, expected: state.revision, kind: "run.started", detail: runID.uuidString)
                do {
                    let result = try await compute.executeGenerated(runID: runID, proposal: proposal, plan: plan, environment: environment, expiresAt: auth.expiresAt)
                    try await saveGeneratedResult(id, runID: runID, value: result)
                } catch {
                    // A failed/terminated execution is recorded. The next coder may revise it, but this ID is never retried.
                    state = try await store.snapshot(id)
                    if let index = state.runs.firstIndex(where: { $0.id == runID }) {
                        state.runs[index].state = .failed; state.runs[index].finishedAt = Date(); state.runs[index].log = error.localizedDescription
                    }
                    _ = try await store.update(state, expected: state.revision, kind: "run.failed", detail: error.localizedDescription)
                    if error is CancellationError || (error as? NormaError) == .cancelled { throw error }
                    break
                }
            }
            try await finishAutonomousExperiment(id)
            // Continue in this task, retaining the single topic-owner until completion or the next gate.
            await driveAutonomous(id, ownsTask: false)
        } catch { await stopAutonomous(id, error: error) }
    }
    private func saveGeneratedResult(_ id: UUID, runID: UUID, value: JSONValue) async throws {
        var state = try await store.snapshot(id)
        guard let index = state.runs.firstIndex(where: { $0.id == runID }), let plan = state.plan,
              let proposal = state.autonomy?.pendingExperiment, let path = value["artifactPath"].string, let hash = value["artifactHash"].string else { throw NormaError.invalid("缺少实验产物。") }
        let root = await compute.root
        guard URL(fileURLWithPath: path).resolvingSymlinksInPath() == root.appendingPathComponent("runs/\(runID.uuidString)/result.json").resolvingSymlinksInPath() else { throw NormaError.forbidden("实验产物路径不匹配。") }
        try EvidenceValidator.file(path: path, expectedHash: hash, allowedRoot: root)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let record = try Codec.decode(JSONValue.self, from: data)
        guard record["codeHash"].string == plan.codeHash, record["dataHash"].string == plan.datasetHash,
              record["workerHash"].string == plan.runnerHash,
              record["planHash"].string == plan.hash, record["environmentFingerprint"].string == state.runs[index].environmentFingerprint,
              record["samples"] == .number(Double(proposal.data.array.count)), record["steps"] == .number(0),
              record["batch"] == .number(1), record["seed"] == .number(0), record["exitCode"] == .number(0),
              case .object(let metrics) = record["metrics"] else { throw NormaError.invalid("实验来源或规模校验失败。") }
        var values: [String: Double] = [:]
        for (name, value) in metrics {
            guard case .number(let number) = value, number.isFinite else { throw NormaError.invalid("指标不是有限数值。") }
            values[name] = number
        }
        guard values[proposal.metric] != nil else { throw NormaError.invalid("缺少指定指标。") }
        let metric = try await artifacts.put(data, kind: .metric, researchID: id)
        let environment = try await artifacts.put(Codec.encode(state.runs[index].environment), kind: .environment, researchID: id)
        state.runs[index].state = .succeeded; state.runs[index].metrics = values
        state.runs[index].artifactPath = path; state.runs[index].artifactHash = hash; state.runs[index].finishedAt = Date()
        _ = try await store.update(state, expected: state.revision, kind: "run.completed", detail: runID.uuidString,
            artifacts: [metric, environment], edges: ([plan.codeHash, plan.datasetHash, plan.protocolHash, environment.hash] + (plan.runnerHash.map { [$0] } ?? [])).map {
                EvidenceEdge(sourceHash: metric.hash, targetHash: $0, relation: "derivedFrom")
            })
    }
    private func finishAutonomousExperiment(_ id: UUID) async throws {
        var state = try await store.snapshot(id)
        guard var session = state.autonomy, let plan = state.plan else { throw NormaError.conflict }
        for index in state.runs.indices where session.pendingRunIDs.contains(state.runs[index].id) && state.runs[index].state == .queued {
            state.runs[index].state = .cancelled; state.runs[index].log = "前一运行失败，未派发此复现任务。"
        }
        session.pendingExperiment = nil; session.pendingRunIDs = []; state.autonomy = session
        _ = try await store.update(state, expected: state.revision, kind: "experiment.recorded", detail: plan.hash)
        try await store.acknowledge(plan.id.uuidString)
    }
    public func recoverAutonomous(_ command: ResearchCommand) async throws {
        var state = try await store.snapshot(command.id)
        guard state.revision == command.revision, state.autonomy != nil, running[state.id] == nil else { throw NormaError.conflict }
        for id in state.autonomy!.pendingRunIDs {
            guard let run = state.runs.first(where: { $0.id == id }), run.state != .succeeded else { continue }
            do { try await saveGeneratedResult(state.id, runID: id, value: compute.recover(id)) }
            catch {
                state = try await store.snapshot(state.id)
                state.lastError = "上次实验结果尚不能确认，禁止重复派发：" + error.localizedDescription
                _ = try await store.update(state, expected: state.revision, kind: "recovery.unresolved", detail: state.lastError!)
                return
            }
        }
        if !state.autonomy!.pendingRunIDs.isEmpty { try await finishAutonomousExperiment(state.id) }
        state = try await store.snapshot(state.id); state.operation = .paused
        _ = try await store.update(state, expected: state.revision, kind: "recovery.ready", detail: "已读取保存的实验结果，可继续课题。")
    }
    private func driveAutonomous(_ id: UUID, ownsTask: Bool = true) async {
        defer { if ownsTask { running.removeValue(forKey: id) } }
        do {
            while true {
                try Task.checkCancellation()
                var state = try await store.snapshot(id)
                guard var session = state.autonomy, state.phase != .finished, state.operation == .running else { return }
                if session.requestedPause {
                    state.operation = .paused
                    _ = try await store.update(state, expected: state.revision, kind: "research.paused", detail: "已在步骤边界暂停")
                    return
                }
                var workflow = try Codec.decode(WorkflowState.self, from: session.workflow)
                let sequence = AutonomousPolicy.roles(for: workflow)
                if session.roleIndex >= sequence.count {
                    try await advanceAutonomous(state, workflow: &workflow)
                    continue
                }
                let role = sequence[session.roleIndex]
                if session.stepID == nil {
                    session.stepID = UUID(); state.autonomy = session
                    state = try await store.update(state, expected: state.revision, kind: "role.started", detail: role.rawValue)
                }
                let result = try await roles.execute(researchID: id, role: role, prompt: AutonomousPolicy.prompt(state, role: role), invocationID: session.stepID)
                let proposal = try RoleProposal.parse(result.text)
                if AutonomousPolicy.codingRoles.contains(role) {
                    guard let experiment = proposal.experiment else { throw NormaError.invalid("实验实现角色未提供可执行方案。") }
                    try experiment.validate()
                } else if proposal.experiment != nil { throw NormaError.forbidden("当前角色无权提出执行代码。") }
                state = try await store.snapshot(id)
                guard state.operation == .running, var latest = state.autonomy else { throw NormaError.cancelled }
                latest.history.append(RoleStep(id: result.invocationID, role: role, phase: state.phase, proposal: proposal))
                guard latest.history.count <= 200 else { throw NormaError.budgetExhausted }
                latest.roleIndex += 1; latest.stepID = nil
                if let hypotheses = proposal.hypotheses, role == .seedGenerator || role == .evolver {
                    guard hypotheses.count <= 8, !hypotheses.isEmpty else { throw NormaError.invalid("候选方案数量无效。") }
                    guard Set(hypotheses.map(\.id)).count == hypotheses.count,
                          Set(hypotheses.map(\.id)).isDisjoint(with: Set(state.hypotheses.map(\.id))), state.hypotheses.count + hypotheses.count <= 64 else {
                        throw NormaError.invalid("候选编号重复或数量超出限制。")
                    }
                    for var hypothesis in hypotheses {
                        guard !hypothesis.title.isEmpty, !hypothesis.mechanism.isEmpty else { throw NormaError.invalid("研究思路缺少内容。") }
                        hypothesis.status = .untested
                        if role == .evolver { hypothesis.evolved = true; hypothesis.parentIDs = state.hypotheses.map(\.id) }
                        state.hypotheses.append(hypothesis)
                    }
                }
                if let manuscript = proposal.manuscript, role == .writer || role == .enhancer {
                    guard manuscript.range(of: "[\\p{Han}]", options: .regularExpression) != nil else { throw NormaError.invalid("研究报告必须使用中文。") }
                    state.manuscript = manuscript
                }
                if [.peerReviewer, .metaReviewer, .subsetCritic, .fullSetCritic, .ablationCritic, .alignmentAuditor, .referenceVerifier].contains(role) {
                    state.reviews.append(ReviewRecord(role: role, text: proposal.summary, score: proposal.score.map(Double.init), evidenceIDs: proposal.evidenceIDs ?? []))
                }
                state.autonomy = latest
                let object = try await artifacts.put(Data(result.text.utf8), kind: .review, researchID: id)
                if let experiment = proposal.experiment {
                    try await freezeAutonomousExperiment(state, proposal: experiment, role: role, roleEvidence: object)
                    return
                }
                _ = try await store.update(state, expected: state.revision, kind: "role.completed", detail: role.rawValue, artifacts: [object])
            }
        } catch { await stopAutonomous(id, error: error) }
    }
    private func freezeAutonomousExperiment(_ initial: ResearchSnapshot, proposal: ProposedExperiment, role: Role, roleEvidence: EvidenceArtifact) async throws {
        try proposal.validate()
        var state = initial
        guard let auth = state.authorization, (auth.usedRuns ?? 0) + 2 <= auth.maxRuns else { throw NormaError.budgetExhausted }
        let code = try await artifacts.put(Data(proposal.python.utf8), kind: .code, researchID: state.id)
        let data = try await artifacts.put(Codec.encode(proposal.data), kind: .data, researchID: state.id)
        let runner = try await artifacts.put(Data(contentsOf: compute.worker), kind: .code, researchID: state.id)
        let protocolObject = try await artifacts.put(Data(("本机数值研究；5 条以内；1 批次；种子 0；不训练；指标：" + proposal.metric).utf8), kind: .protocolDefinition, researchID: state.id)
        let kind: ExperimentKind = state.phase == .baseline ? .baseline : state.phase == .fullSet || state.phase == .refinement ? .fullSet : state.phase == .ablation ? .ablation : state.phase == .rebuttal ? .rebuttal : .subset
        var plan = ExperimentPlan(researchID: state.id, contractVersion: state.contract.version, kind: kind, question: proposal.question,
            datasetHash: data.hash, codeHash: code.hash, protocolHash: protocolObject.hash, runtimeSeconds: 30)
        plan.runnerHash = runner.hash; plan.frozen = true
        state.plan = plan; state.preflight = nil; state.confirmedPlanHash = nil; state.selectedTargetID = nil
        state.autonomy?.pendingExperiment = proposal; state.operation = .waitingApproval
        _ = try await store.update(state, expected: state.revision, kind: "plan.frozen", detail: plan.hash, artifacts: [code, data, protocolObject, runner, roleEvidence])
    }
    private func stopAutonomous(_ id: UUID, error: Error) async {
        guard var state = try? await store.snapshot(id), var session = state.autonomy else { return }
        if (error as? NormaError) == .budgetExhausted {
            if var workflow = try? Codec.decode(WorkflowState.self, from: session.workflow) {
                try? workflow.apply(.budgetExhausted); session.workflow = (try? Codec.encode(workflow)) ?? session.workflow
            }
            state.phase = .finished; state.outcome = .budgetExhausted; state.operation = .succeeded
        } else if state.authorization?.revoked == true { state.operation = .cancelled }
        else if session.requestedPause { state.operation = .paused }
        else { state.operation = .failed }
        session.failureCount += 1
        if error is DecodingError { session.stepID = nil }
        if case .invalid = error as? NormaError { session.stepID = nil }
        state.autonomy = session
        state.lastError = (error as? NormaError) == .budgetExhausted ? "已达到本次授权的调用或实验额度。" : error.localizedDescription
        for i in state.runs.indices where state.runs[i].state == .running { state.runs[i].state = .unknown; state.operation = .unknown }
        _ = try? await store.update(state, expected: state.revision, kind: "autonomy.stopped", detail: error.localizedDescription)
    }
}

extension ExecutionGate {
    static func validateModelForResume(_ state: ResearchSnapshot) throws {
        guard let auth = state.authorization, !auth.revoked, auth.expiresAt > Date(),
              auth.contractVersion == state.contract.version else { throw NormaError.forbidden("课题授权已失效。") }
        guard (auth.usedModelCalls ?? 0) < auth.maxModelCalls else { throw NormaError.budgetExhausted }
    }
}
