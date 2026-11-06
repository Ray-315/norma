import XCTest
@testable import ResearchKernel
import ResearchContracts
import ExperimentManager
import ReviewEngine
import ResearchStore
import NORMAUI

final class PolicyTests: XCTestCase {
    func fixture(now: Date = Date()) -> (ExperimentPlan, ResearchAuthorization, TargetPreflightReport) {
        let id = UUID()
        let node = ComputeNode(id: "local", name: "test", kind: .local, workDirectory: "/tmp/norma-test", python: "/usr/bin/python3")
        var plan = ExperimentPlan(researchID: id, contractVersion: 1, kind: .subset, question: "test",
            datasetHash: "data", codeHash: "code", protocolHash: "protocol", runtimeSeconds: 10)
        plan.frozen = true
        let auth = ResearchAuthorization(researchID: id, contractVersion: 1, target: node, fingerprint: "env",
            expiresAt: now.addingTimeInterval(600), maxModelCalls: 0, maxRuns: 2, maxRuntimeSeconds: 30)
        let report = TargetPreflightReport(planHash: plan.hash, targetID: "local", fingerprint: "env", checks: [Check("test", .pass, "")], now: now)
        return (plan, auth, report)
    }
    func testMissingAuthorizationAndBudgetReject() throws {
        let (plan, auth, report) = fixture()
        XCTAssertThrowsError(try ExecutionGate.validate(plan: plan, authorization: nil, preflight: report, currentFingerprint: "env", reservedRuns: 0))
        XCTAssertThrowsError(try ExecutionGate.validate(plan: plan, authorization: auth, preflight: report, currentFingerprint: "env", reservedRuns: 2))
        XCTAssertNoThrow(try ExecutionGate.validate(plan: plan, authorization: auth, preflight: report, currentFingerprint: "env", reservedRuns: 1))
    }
    func testExpiredRevokedDriftAndChangedPlanReject() {
        var (plan, auth, report) = fixture()
        XCTAssertThrowsError(try ExecutionGate.validate(plan: plan, authorization: auth, preflight: report, currentFingerprint: "drift", reservedRuns: 0))
        report.validUntil = .distantPast
        XCTAssertThrowsError(try ExecutionGate.validate(plan: plan, authorization: auth, preflight: report, currentFingerprint: "env", reservedRuns: 0))
        report.validUntil = .distantFuture; plan.codeHash = "changed"
        XCTAssertThrowsError(try ExecutionGate.validate(plan: plan, authorization: auth, preflight: report, currentFingerprint: "env", reservedRuns: 0))
        auth.revoked = true
        XCTAssertThrowsError(try ExecutionGate.validate(plan: plan, authorization: auth, preflight: report, currentFingerprint: "env", reservedRuns: 0))
    }
    func testNoImprovementPreservesPriorBest() {
        XCTAssertEqual(ReviewPolicy.meta(accepted: false, refinementAttempted: true, improved: false, remaining: 1), .finishPriorBest)
        XCTAssertFalse(ReviewPolicy.strictImprovement(old: 1, new: 2, higherIsBetter: true, sameProtocol: false, constraintsPassed: true, evidencePassed: true))
        XCTAssertFalse(ReviewPolicy.strictImprovement(old: 1, new: .nan, higherIsBetter: true, sameProtocol: true, constraintsPassed: true, evidencePassed: true))
    }
    func testEightSlotsAndFairAdmission() async throws {
        let scheduler = FairScheduler()
        let topics = (0..<4).map { _ in UUID() }
        for topic in topics {
            try await scheduler.register(topic)
            for _ in 0..<3 { try await scheduler.enqueue(topic: topic, task: UUID()) }
        }
        var admitted: [(UUID, UUID)] = []
        for _ in 0..<8 {
            guard let next = await scheduler.next() else { return XCTFail("Missing admitted task") }
            admitted.append(next); try await scheduler.beginModel(topic: next.0, task: next.1)
        }
        XCTAssertEqual(Array(admitted.prefix(4).map(\.0)), topics)
        let extra = await scheduler.next(); XCTAssertNil(extra)
        let first = admitted[0]
        do { try await scheduler.beginModel(topic: first.0, task: first.1); XCTFail("Duplicate model invocation") } catch {}
        await scheduler.release(topic: first.0, task: first.1)
        let replacement = await scheduler.next(); XCTAssertEqual(replacement?.0, first.0)
        await scheduler.setMemoryPressure(true)
        await scheduler.release(topic: first.0, task: replacement!.1)
        let pressured = await scheduler.next(); XCTAssertNil(pressured)
    }
    func testSnapshotAuditCASAtomicity() async throws {
        let store = try ResearchDatabase(path: ":memory:")
        let contract = ResearchContract(title: "test", question: "test", metric: "mse")
        let initial = try await store.create(contract)
        let updated = try await store.update(initial, expected: 0, kind: "test", detail: "one")
        XCTAssertEqual(updated.revision, 1); XCTAssertEqual(updated.events.count, 1)
        do { _ = try await store.update(initial, expected: 0, kind: "bad", detail: "stale"); XCTFail("Stale write accepted") } catch { XCTAssertEqual(error as? NormaError, .conflict) }
        let current = try await store.snapshot(initial.id)
        XCTAssertEqual(current.revision, 1)
        let events = try await store.events(after: 0); XCTAssertEqual(events.count, 1)
    }
    @MainActor func testThemePersistsAndRejectsInvalidHex() {
        let name = "norma.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let theme = ThemeManager(defaults: defaults)
        XCTAssertEqual(theme.mode, .system)
        XCTAssertFalse(theme.saveCustom("xyz")); XCTAssertTrue(theme.saveCustom("#123ABC"))
        theme.mode = .dark
        let restored = ThemeManager(defaults: defaults)
        XCTAssertEqual(restored.mode, .dark); XCTAssertEqual(restored.accentHex, "123ABC")
    }
    func testSmokeNeverBecomesExportReady() {
        var state = ResearchSnapshot(contract: ResearchContract(title: "smoke", question: "known", metric: "mse"))
        state.phase = .finished; state.outcome = .smokeVerified; state.exportConfirmed = true
        state.integrity = (1...4).map { Check("I" + String($0), .pass, "") }
        XCTAssertFalse(state.exportReady)
    }
    func testModelBudgetIsBoundToTopicAndAuthorization() {
        var state = ResearchSnapshot(contract: ResearchContract(title: "scope", question: "q", metric: "m"))
        var (_, auth, _) = fixture()
        auth.maxModelCalls = 1; auth.usedModelCalls = 0
        state.authorization = auth
        XCTAssertThrowsError(try ExecutionGate.validateModel(state, model: auth.model))
        auth.researchID = state.id; state.authorization = auth; state.modelCalls = 100
        XCTAssertNoThrow(try ExecutionGate.validateModel(state, model: auth.model))
        state.authorization?.usedModelCalls = 1
        XCTAssertThrowsError(try ExecutionGate.validateModel(state, model: auth.model))
        state.authorization?.usedModelCalls = 0; state.operation = .cancelPending
        XCTAssertThrowsError(try ExecutionGate.validateModel(state, model: auth.model))
    }
}
