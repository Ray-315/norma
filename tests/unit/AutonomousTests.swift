import XCTest
import Foundation
import ResearchContracts
import ComputeController
@testable import ResearchKernel

private actor ResearchFixture {
    let first = UUID(), second = UUID()
    func execute(_ invocation: AgentInvocation) throws -> AgentResult {
        var output: [String: JSONValue] = ["summary": .string("依据实际材料完成核查。"), "decision": .string("accept")]
        if invocation.role == .seedGenerator {
            let hypotheses = [Hypothesis(title: "验证中心化计算", mechanism: "用中心化公式对照已知解"), Hypothesis(title: "验证正规方程", mechanism: "用正规方程对照已知解")]
            output["hypotheses"] = try Codec.decode(JSONValue.self, from: Codec.encode(hypotheses))
        }
        if AutonomousPolicy.codingRoles.contains(invocation.role) {
            output["experiment"] = try Codec.decode(JSONValue.self, from: Codec.encode(ProposedExperiment(question: "验证五个数的均值", python: "def run(data):\n    return {'mean': sum(data) / len(data)}", data: .array([1,2,3,4,5].map { .number(Double($0)) }), metric: "mean")))
        }
        if [.subsetCritic, .fullSetCritic, .ablationCritic, .comparison].contains(invocation.role) { output["decision"] = .string("good") }
        if invocation.role == .selector {
            let prefix = "研究思路："
            let json = invocation.prompt.components(separatedBy: prefix)[1].components(separatedBy: "\n实际运行记录：")[0]
            let hypotheses = try Codec.decode([Hypothesis].self, from: Data(json.utf8))
            output["candidateID"] = .string(hypotheses.first(where: { $0.status == .fullGood })!.id.uuidString)
        }
        if [.writer, .enhancer].contains(invocation.role) {
            XCTAssertTrue(invocation.prompt.contains("实际执行器返回清单"))
            XCTAssertTrue(invocation.prompt.contains("\"seed\":0"))
            XCTAssertTrue(invocation.prompt.contains("\"batch\":1"))
            let json = invocation.prompt.components(separatedBy: "实际运行记录：")[1].components(separatedBy: "\n完整成功/失败历史索引：")[0]
            let runs = try Codec.decode([ExperimentRun].self, from: Data(json.utf8)).filter { $0.state == .succeeded }
            output["manuscript"] = .string("已知问题验证报告：五个数的均值为 3；运行证据：" + runs.map { $0.id.uuidString }.joined(separator: "、") + "。仅限五条输入，不主张科研创新。")
            output["evidenceIDs"] = .array(runs.map { .string($0.id.uuidString) })
        }
        if [.peerReviewer, .scoreVerifier].contains(invocation.role) { output["score"] = .number(8); output["empiricalObjections"] = .bool(false) }
        return AgentResult(invocationID: invocation.id, threadID: "fixture", text: String(decoding: try Codec.encode(JSONValue.object(output)), as: UTF8.self))
    }
}
final class AutonomousTests: XCTestCase {
    private var worker: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("workers/experiment-runner/worker.py") }
    func testSixStagesWithRealBoundedPythonAndMockRoles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("norma-autonomy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ResearchFixture()
        let service = try ResearchService(root: root, worker: worker, testExecutor: { try await fixture.execute($0) })
        let id = try await service.createResearch(ResearchContract(title: "均值验证", question: "验证五个数的均值", metric: "mean"))
        try await service.startAutonomous(AutonomousStart(id: id, revision: 0, maxModelCalls: 40, maxRuns: 10, knownProblem: true))
        let deadline = Date().addingTimeInterval(90)
        var observed = Set<ResearchPhase>()
        var finished = false
        while Date() < deadline {
            var state = try await service.snapshot(id); observed.insert(state.phase)
            if state.operation == .waitingApproval {
                // Verify execution is impossible without exact plan/target/preflight confirmation.
                do { try await service.executeAutonomous(ResearchCommand(id: id, revision: state.revision)); XCTFail("Unconfirmed dispatch") } catch {}
                state = try await service.confirmPlan(ResearchCommand(id: id, revision: state.revision))
                state = try await service.selectLocal(ResearchCommand(id: id, revision: state.revision))
                state = try await service.preflight(ResearchCommand(id: id, revision: state.revision))
                try await service.executeAutonomous(ResearchCommand(id: id, revision: state.revision))
                do { try await service.executeAutonomous(ResearchCommand(id: id, revision: state.revision)); XCTFail("Duplicate dispatch") } catch {}
            } else if state.phase == .finished {
                XCTAssertEqual(state.outcome, .knownProblemVerified, state.runs.map(\.log).joined(separator: "\n"))
                XCTAssertEqual(state.runs.count, 8)
                XCTAssertTrue(state.runs.allSatisfy { $0.state == .succeeded && $0.metrics["mean"] == 3 })
                XCTAssertFalse(state.hypotheses.isEmpty); XCTAssertFalse(state.manuscript.isEmpty)
                XCTAssertTrue(state.metaAccepted); XCTAssertEqual(state.integrity.filter { $0.status == .pass }.count, 4)
                let phases = Set(state.autonomy!.history.map { $0.phase.group })
                XCTAssertEqual(phases, Set(0...5))
                let confirmed = try await service.confirmExport(ResearchCommand(id: id, revision: state.revision))
                let bundle = try await ResearchArchive.export(confirmed, database: service.store, objects: service.artifacts, directory: root.appendingPathComponent("exports"))
                try ResearchArchive.validate(bundle)
                finished = true; break
            } else if [.failed, .unknown].contains(state.operation) {
                XCTFail(state.lastError ?? "Pipeline failed"); break
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(finished, "Pipeline deadline; observed \(observed)")
    }
    func testMalformedAndEnglishOnlyProposalsAreRejected() throws {
        XCTAssertTrue(AutonomousPolicy.assignment(.limitationExtractor).contains("尚无运行记录是正常的"))
        XCTAssertTrue(AutonomousPolicy.assignment(.limitationVerifier).contains("不要求实验结果"))
        XCTAssertThrowsError(try RoleProposal.parse("not JSON"))
        XCTAssertThrowsError(try RoleProposal.parse("{\"summary\":\"English only\",\"decision\":\"accept\"}"))
        XCTAssertThrowsError(try ProposedExperiment(question: "验证", python: "def run(data): return {}", data: .array([]), metric: "m").validate())
    }
    func testReportCanCiteResolvedFailuresAndActualReviewRecords() throws {
        var state = ResearchSnapshot(contract: ResearchContract(title: "引用核查", question: "验证", metric: "mean"))
        let plan = ExperimentPlan(researchID: state.id, contractVersion: 1, kind: .baseline, question: "验证", datasetHash: "data", codeHash: "code", protocolHash: "protocol", runtimeSeconds: 10)
        let environment = EnvironmentSnapshot(nodeID: "local", python: "/usr/bin/python3", version: "fixture", architecture: "arm64", platform: "macOS", freeBytes: 0)
        var good = ExperimentRun(kind: .baseline, plan: plan, environment: environment); good.state = .succeeded
        var failed = ExperimentRun(kind: .baseline, plan: plan, environment: environment); failed.state = .failed
        let review = RoleStep(id: UUID(), role: .ablationCritic, phase: .ablation, proposal: try RoleProposal.parse("{\"summary\":\"未发现优势\",\"decision\":\"bad\"}"))
        state.runs = [good, failed]
        state.autonomy = AutonomousSession(workflow: Data(), knownProblem: true)
        state.autonomy?.history = [review]
        let citations = Set([good.id, failed.id, review.id])
        state.manuscript = citations.map(\.uuidString).joined(separator: "、")
        XCTAssertTrue(AutonomousPolicy.reportCitationsValid(state, cited: citations))
        XCTAssertFalse(AutonomousPolicy.reportCitationsValid(state, cited: [failed.id, review.id]))
        let invented = UUID(); state.manuscript += invented.uuidString
        XCTAssertFalse(AutonomousPolicy.reportCitationsValid(state, cited: citations.union([invented])))
        state.runs[1].state = .unknown
        XCTAssertFalse(AutonomousPolicy.reportCitationsValid(state, cited: citations))
    }
    func testRevisedResearchCanStartWithoutDeletingPreviousRuns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("norma-revised-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ResearchFixture()
        let service = try ResearchService(root: root, worker: worker, testExecutor: { try await fixture.execute($0) })
        let id = try await service.createResearch(ResearchContract(title: "历史实验", question: "原要求", metric: "mean"))
        var state = try await service.prepareSmoke(ResearchCommand(id: id, revision: 0))
        let environment = try await service.compute.discover()
        var oldRun = ExperimentRun(kind: .baseline, plan: state.plan!, environment: environment)
        oldRun.state = .failed; oldRun.log = "旧版本实验失败记录"
        state.runs = [oldRun]
        state = try await service.store.update(state, expected: state.revision, kind: "test.oldRun", detail: "fixture")
        var revised = state.contract; revised.version += 1; revised.question = "验证五个数的均值"
        state = try await service.revise(revised, expected: state.revision)
        try await service.startAutonomous(AutonomousStart(id: id, revision: state.revision, maxModelCalls: 1, maxRuns: 2, knownProblem: true))
        for _ in 0..<100 {
            state = try await service.snapshot(id)
            if state.phase == .finished {
                XCTAssertEqual(state.outcome, .budgetExhausted)
                XCTAssertEqual(state.runs.map(\.id), [oldRun.id])
                XCTAssertEqual(state.runs.first?.log, "旧版本实验失败记录")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Revised research did not start")
    }
    func testModelBudgetIsTerminalWithoutStartingExperiment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("norma-budget-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ResearchFixture()
        let service = try ResearchService(root: root, worker: worker, testExecutor: { try await fixture.execute($0) })
        let id = try await service.createResearch(ResearchContract(title: "预算", question: "验证", metric: "m"))
        try await service.startAutonomous(AutonomousStart(id: id, revision: 0, maxModelCalls: 1, maxRuns: 2, knownProblem: true))
        for _ in 0..<100 {
            let state = try await service.snapshot(id)
            if state.phase == .finished {
                XCTAssertEqual(state.outcome, .budgetExhausted); XCTAssertEqual(state.modelCalls, 1); XCTAssertTrue(state.runs.isEmpty)
                XCTAssertFalse(state.exportReady); return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Budget did not stop the flow")
    }
    func testPauseIsPersistedAtStepBoundaryAndCanResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("norma-pause-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = ResearchFixture()
        let service = try ResearchService(root: root, worker: worker, testExecutor: { invocation in
            try await Task.sleep(for: .milliseconds(100))
            return try await fixture.execute(invocation)
        })
        let id = try await service.createResearch(ResearchContract(title: "暂停", question: "验证", metric: "m"))
        try await service.startAutonomous(AutonomousStart(id: id, revision: 0, maxModelCalls: 2, maxRuns: 2, knownProblem: true))
        var state = try await service.snapshot(id)
        // Retry CAS if admission raced the pause command; never override a concurrent write.
        for _ in 0..<10 {
            do { try await service.pause(id, expectedRevision: state.revision); break }
            catch NormaError.conflict { state = try await service.snapshot(id) }
        }
        for _ in 0..<100 {
            state = try await service.snapshot(id)
            if state.operation == .paused { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(state.operation, .paused); XCTAssertTrue(state.autonomy!.requestedPause)
        let reopened = try ResearchService(root: root, worker: worker, testExecutor: { try await fixture.execute($0) })
        let restored = try await reopened.snapshot(id)
        XCTAssertEqual(restored.autonomy?.history.count, state.autonomy?.history.count)
        XCTAssertEqual(restored.operation, .paused)
        try await reopened.resumeAutonomous(ResearchCommand(id: id, revision: restored.revision))
        for _ in 0..<100 {
            let resumed = try await reopened.snapshot(id)
            if resumed.phase == .finished {
                XCTAssertEqual(resumed.outcome, .budgetExhausted); XCTAssertEqual(resumed.modelCalls, 2); return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Resume did not progress")
    }
}
