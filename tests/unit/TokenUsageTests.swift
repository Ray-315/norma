import XCTest
import Foundation
import ResearchContracts
import ResearchStore
import AgentRuntime
import CodexBridge

final class TokenUsageTests: XCTestCase {
    func testRepeatedUsageUpdatesDoNotDoubleCountAndSurviveFailureAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("norma-tokens-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ResearchDatabase(path: root.appendingPathComponent("research.sqlite").path)
        let initial = try await store.create(ResearchContract(title: "tokens", question: "q", metric: "m"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/fake-codex.py")
        for model in ["fixture", "fixture-failed"] {
            var state = try await store.snapshot(initial.id); state.modelCalls += 1
            let invocation = AgentInvocation(researchID: state.id, role: .writer, model: model, reasoning: "medium", prompt: "test", workspace: root.path, profile: "test")
            _ = try await store.update(state, expected: state.revision, kind: "model.reserved", detail: "test", invocation: AgentCheckpoint(id: invocation.id, researchID: state.id, role: .writer, model: model, state: .queued))
            let bridge = JSONLTransport()
            try await bridge.start(executable: fixture.path, home: root)
            let runtime = RoleRuntime(bridge: bridge, checkpoint: { try await store.checkpoint($0) })
            if model == "fixture" {
                let result = try await runtime.execute(invocation); XCTAssertEqual(result.text, "fixture answer")
            } else {
                do { _ = try await runtime.execute(invocation); XCTFail("Failed turn accepted") } catch {}
            }
            await bridge.stop()
        }
        let reopened = try ResearchDatabase(path: root.appendingPathComponent("research.sqlite").path)
        var records = try await reopened.invocations()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.compactMap(\.tokenUsage).map(\.totalTokens).sorted(), [20, 20])
        var terminal = records[0]; terminal.state = .unknown; terminal.tokenUsage = nil
        try await reopened.checkpoint(terminal)
        records = try await reopened.invocations()
        let summary = TokenUsageSummary(records: records.compactMap(\.tokenUsage))
        XCTAssertEqual(summary.recordedCalls, 2)
        XCTAssertEqual(summary.usage.totalTokens, 40)
        XCTAssertEqual(summary.usage.inputTokens, 30)
        XCTAssertEqual(summary.usage.outputTokens, 10)
        XCTAssertEqual(summary.usage.cachedInputTokens, 6)
        XCTAssertEqual(summary.usage.reasoningOutputTokens, 4)
    }
}
