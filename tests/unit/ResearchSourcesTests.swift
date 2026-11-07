import XCTest
import Foundation
import ResearchContracts
import ResearchKernel

final class ResearchSourcesTests: XCTestCase {
    func testAttachmentsPersistAndProjectsReadMemoryWithoutFollowingSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("norma-sources-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("workers/experiment-runner/worker.py")
        let service = try ResearchService(root: root.appendingPathComponent("app"), worker: worker)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let attachment = root.appendingPathComponent("previous.txt")
        try Data("previous research result".utf8).write(to: attachment)
        try Data("project memory marker".utf8).write(to: project.appendingPathComponent("MEMORY.md"))
        try Data("SECRET_SENTINEL".utf8).write(to: project.appendingPathComponent(".env"))
        let outside = root.appendingPathComponent("outside.txt")
        try Data("OUTSIDE_SENTINEL".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("linked.txt"), withDestinationURL: outside)
        let id = try await service.createResearch(ResearchContract(title: "source test", question: "q", metric: "m"))
        var state = try await service.importSources(SourceImportCommand(id: id, revision: 0, paths: [attachment.path], project: false))
        state = try await service.importSources(SourceImportCommand(id: id, revision: state.revision, paths: [project.path], project: true))
        try FileManager.default.removeItem(at: attachment)
        let reopened = try ResearchService(root: root.appendingPathComponent("app"), worker: worker)
        let recovered = try await reopened.snapshot(id)
        XCTAssertEqual(recovered.sources?.count, 2)
        let context = try await ResearchContextReader.read(recovered, artifacts: reopened.artifacts)
        XCTAssertTrue(context.contains("previous research result"))
        XCTAssertTrue(context.contains("project memory marker"))
        XCTAssertFalse(context.contains("SECRET_SENTINEL")); XCTAssertFalse(context.contains("OUTSIDE_SENTINEL"))
        do { _ = try await service.importSources(SourceImportCommand(id: id, revision: 0, paths: [project.path], project: true)); XCTFail("Stale revision accepted") } catch {}
        state = try await service.removeSource(SourceRemoveCommand(id: id, revision: state.revision, sourceID: state.sources!.last!.id))
        XCTAssertEqual(state.sources?.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path))
    }
    func testLegacySnapshotDecodesWithoutSourcesOrUsage() throws {
        let state = ResearchSnapshot(contract: ResearchContract(title: "legacy", question: "q", metric: "m"))
        let recovered = try Codec.decode(ResearchSnapshot.self, from: Codec.encode(state))
        XCTAssertNil(recovered.sources); XCTAssertNil(recovered.tokenUsage)
    }
}
