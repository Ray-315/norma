import XCTest
@testable import NORMAUI
import ResearchContracts

final class PresentationTests: XCTestCase {
    func testLegacySmokeReportAndMethodRemainScopedToBuiltInVerification() {
        XCTAssertEqual(DisplayText.manuscript(NumericalSmoke.legacyReport), NumericalSmoke.report)
        XCTAssertEqual(DisplayText.manuscript("An actual research manuscript."), "An actual research manuscript.")
        XCTAssertFalse(NumericalSmoke.matches(nil))
        let id = UUID()
        var plan = ExperimentPlan(researchID: id, contractVersion: 1, kind: .subset, question: "旧方案", datasetHash: "data", codeHash: "code", protocolHash: Codec.hash(Data(NumericalSmoke.protocolID.utf8)), runtimeSeconds: 30)
        XCTAssertTrue(NumericalSmoke.matches(plan))
        plan.protocolHash = "another-protocol"
        XCTAssertFalse(NumericalSmoke.matches(plan))
    }
    func testPreparationProgressUsesPersistedConfirmation() {
        var state = ResearchSnapshot(contract: ResearchContract(title: "验证", question: "拟合", metric: "MSE"))
        XCTAssertEqual(state.nextStep(), "准备实验方案")
        state.plan = ExperimentPlan(researchID: state.id, contractVersion: 1, kind: .subset, question: "拟合", datasetHash: "data", codeHash: "code", protocolHash: "protocol", runtimeSeconds: 30)
        XCTAssertEqual(state.nextStep(), "确认实验方案")
        state.confirmedPlanHash = state.plan!.hash
        XCTAssertEqual(state.nextStep(), "选择执行设备")
        state.selectedTargetID = "local"
        XCTAssertEqual(state.nextStep(), "检查运行条件")
    }
    func testExpiredChecksAndChangedEnvironmentRequireRenewal() {
        let now = Date()
        var state = ResearchSnapshot(contract: ResearchContract(title: "验证", question: "拟合", metric: "MSE"))
        state.plan = ExperimentPlan(researchID: state.id, contractVersion: 1, kind: .subset, question: "拟合", datasetHash: "data", codeHash: "code", protocolHash: "protocol", runtimeSeconds: 30)
        state.confirmedPlanHash = state.plan!.hash; state.selectedTargetID = "local"
        state.preflight = TargetPreflightReport(planHash: state.plan!.hash, targetID: "local", fingerprint: "env", checks: [Check("Scope", .pass, "")], now: now)
        XCTAssertEqual(state.nextStep(now: now), "授权本次实验")
        let node = ComputeNode(id: "local", name: "本机", kind: .local, workDirectory: "/tmp", python: "/usr/bin/python3")
        state.authorization = ResearchAuthorization(researchID: state.id, contractVersion: 1, target: node, fingerprint: "env", expiresAt: now.addingTimeInterval(3600), maxModelCalls: 0, maxRuns: 2, maxRuntimeSeconds: 30)
        XCTAssertEqual(state.nextStep(now: now), "开始本机实验")
        XCTAssertEqual(state.nextStep(now: now.addingTimeInterval(301)), "检查运行条件")
        state.authorization?.environmentFingerprint = "changed"
        XCTAssertEqual(state.nextStep(now: now), "授权本次实验")
        state.authorization?.environmentFingerprint = "env"; state.authorization?.usedRuns = 2
        XCTAssertEqual(state.nextStep(now: now), "授权本次实验")
    }
    func testPausedAndTerminalTopicsDoNotPromptExecution() {
        var state = ResearchSnapshot(contract: ResearchContract(title: "验证", question: "拟合", metric: "MSE"))
        state.operation = .paused; XCTAssertEqual(state.nextStep(), "恢复课题")
        state.operation = .unknown; XCTAssertEqual(state.nextStep(), "核对执行结果")
        state.operation = .failed; XCTAssertEqual(state.nextStep(), "查看失败记录")
        state.operation = .succeeded; state.phase = .finished
        XCTAssertEqual(state.nextStep(), "查看实验结果")
    }
    func testProgressDoesNotTreatPreparationAsExperimentCompletion() {
        let now = Date()
        var state = ResearchSnapshot(contract: ResearchContract(title: "验证", question: "拟合", metric: "MSE"))
        XCTAssertEqual(state.completedExecutionSteps(now: now), 0)
        XCTAssertEqual(state.startActionTitle, "开始研究")
        let plan = ExperimentPlan(researchID: state.id, contractVersion: 1, kind: .subset, question: "拟合", datasetHash: "data", codeHash: "code", protocolHash: "protocol", runtimeSeconds: 30)
        state.plan = plan; state.confirmedPlanHash = plan.hash
        XCTAssertEqual(state.completedExecutionSteps(now: now), 1)
        state.selectedTargetID = "local"
        XCTAssertEqual(state.completedExecutionSteps(now: now), 2)
        state.preflight = TargetPreflightReport(planHash: plan.hash, targetID: "local", fingerprint: "env", checks: [Check("Scope", .pass, "")], now: now)
        XCTAssertEqual(state.completedExecutionSteps(now: now), 3)
        let node = ComputeNode(id: "local", name: "本机", kind: .local, workDirectory: "/tmp", python: "/usr/bin/python3")
        state.authorization = ResearchAuthorization(researchID: state.id, contractVersion: 1, target: node, fingerprint: "env", expiresAt: now.addingTimeInterval(3600), maxModelCalls: 0, maxRuns: 2, maxRuntimeSeconds: 30)
        XCTAssertEqual(state.completedExecutionSteps(now: now), 4)
        XCTAssertEqual(state.completedExecutionSteps(now: now.addingTimeInterval(301)), 2)
        state.authorization?.revoked = true
        XCTAssertEqual(state.completedExecutionSteps(now: now), 3)
    }
    func testProgressRequiresActualRunsAndResultChecks() {
        var state = ResearchSnapshot(contract: ResearchContract(title: "验证", question: "拟合", metric: "MSE"))
        let plan = ExperimentPlan(researchID: state.id, contractVersion: 1, kind: .subset, question: "拟合", datasetHash: "data", codeHash: "code", protocolHash: "protocol", runtimeSeconds: 30)
        state.plan = plan
        let environment = EnvironmentSnapshot(nodeID: "local", python: "python", version: "3", architecture: "arm64", platform: "macOS", freeBytes: 1000)
        var first = ExperimentRun(kind: .subset, plan: plan, environment: environment)
        first.state = .failed; state.runs = [first]; state.operation = .failed
        XCTAssertEqual(state.completedExecutionSteps(), 4)
        XCTAssertEqual(state.startActionTitle, "查看失败记录")
        first.state = .succeeded
        var second = ExperimentRun(kind: .reproduction, plan: plan, environment: environment); second.state = .succeeded
        state.runs = [first, second]
        XCTAssertEqual(state.completedExecutionSteps(), 5)
        state.phase = .finished; state.operation = .succeeded
        state.integrity = [Check("I1", .pass, ""), Check("I2", .pass, "")]
        XCTAssertEqual(state.completedExecutionSteps(), 6)
        XCTAssertEqual(state.startActionTitle, "查看实验结果")
        state.plan?.question = "新的方案"
        XCTAssertEqual(state.completedExecutionSteps(), 0)
    }

}
