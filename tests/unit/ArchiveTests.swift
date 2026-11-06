import XCTest
import Foundation
import ResearchContracts
import ResearchKernel
import ResearchStore
import EvidenceEngine

final class ArchiveTests: XCTestCase {
    func testBackupIncludesVerifiedEvidenceAndDetectsTampering() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("norma-backup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let objects = try ArtifactStore(root: root.appendingPathComponent("objects"))
        let db = try ResearchDatabase(path: root.appendingPathComponent("source.sqlite").path)
        let state = try await db.create(ResearchContract(title: "backup", question: "q", metric: "m"))
        let object = try await objects.put(Data("frozen code".utf8), kind: .code, researchID: state.id)
        _ = try await db.update(state, expected: 0, kind: "test", detail: "", artifacts: [object])
        let archive = try await ResearchArchive.backup(database: db, objects: objects, directory: root.appendingPathComponent("backups"))
        try ResearchArchive.validate(archive)
        let copied = try ResearchDatabase(path: archive.appendingPathComponent("research.sqlite").path)
        let saved = try await copied.snapshot(state.id)
        XCTAssertEqual(saved.revision, 1)
        try await copied.close()
        let url = archive.appendingPathComponent("objects/" + object.relativePath)
        try Data("modified".utf8).write(to: url)
        XCTAssertThrowsError(try ResearchArchive.validate(archive))
    }
    func testUnverifiedResearchCannotBeExported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("norma-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let objects = try ArtifactStore(root: root)
        let db = try ResearchDatabase(path: ":memory:")
        let state = try await db.create(ResearchContract(title: "not verified", question: "q", metric: "m"))
        do { _ = try await ResearchArchive.export(state, database: db, objects: objects, directory: root); XCTFail("Export gate bypass") } catch {}
    }
}
