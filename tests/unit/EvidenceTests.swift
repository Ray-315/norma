import XCTest
import Foundation
import ResearchContracts
import EvidenceEngine
import ResearchStore

final class EvidenceTests: XCTestCase {
    func testCrossTopicAndTamperingAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("norma-evidence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(root: root)
        let topic = UUID()
        let artifact = try await store.put(Data("original".utf8), kind: .code, researchID: topic)
        do { _ = try await store.read(artifact, researchID: UUID()); XCTFail("Cross-topic read") } catch {}
        let url = root.appendingPathComponent(artifact.relativePath)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try Data("tampered".utf8).write(to: url)
        do { _ = try await store.read(artifact, researchID: topic); XCTFail("Tampering accepted") } catch {}
    }
    func testBrokenEvidenceEdgeRollsBackStateAndAudit() async throws {
        let db = try ResearchDatabase(path: ":memory:")
        let state = try await db.create(ResearchContract(title: "test", question: "test", metric: "mse"))
        do {
            _ = try await db.update(state, expected: 0, kind: "invalid", detail: "",
                edges: [EvidenceEdge(sourceHash: "missing", targetHash: "missing", relation: "derivedFrom")])
            XCTFail("Dangling evidence accepted")
        } catch {}
        let restored = try await db.snapshot(state.id)
        let events = try await db.events(after: 0)
        XCTAssertEqual(restored.revision, 0)
        XCTAssertTrue(events.isEmpty)
    }
}
