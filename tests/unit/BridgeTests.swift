import XCTest
import Foundation
import CodexBridge
import ResearchContracts

final class BridgeTests: XCTestCase {
    func testIsolatedEnvironmentAndDeniedToolApproval() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("fixtures/fake-codex.py")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("norma-bridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let bridge = JSONLTransport()
        try await bridge.start(executable: fixture.path, home: home)
        let environment = try await bridge.request("test/environment", params: .object([:]))
        XCTAssertEqual(environment["home"].string, home.path)
        XCTAssertFalse(environment["apiKeyInherited"].bool)
        XCTAssertFalse(environment["sshAgentInherited"].bool)
        XCTAssertFalse(environment["externalAuthInherited"].bool)
        let approval = try await bridge.request("test/approval", params: .object([:]))
        XCTAssertTrue(approval["declined"].bool)
        do { _ = try await bridge.request("test/error", params: .object([:])); XCTFail("RPC error ignored") } catch {}
        await bridge.stop()
    }
}
