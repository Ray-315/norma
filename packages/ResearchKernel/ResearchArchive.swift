import Foundation
import ResearchContracts
import ResearchStore
import EvidenceEngine

public enum ResearchArchive {
    /// A consistent database snapshot plus exactly the immutable objects referenced by it.
    /// Account profiles, worker authorization keys and keychain data are never copied.
    public static func backup(database: ResearchDatabase, objects: ArtifactStore, directory: URL) async throws -> URL {
        let destination = directory.appendingPathComponent(UUID().uuidString + ".normabackup")
        let staging = directory.appendingPathComponent(UUID().uuidString + ".partial")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let dbURL = staging.appendingPathComponent("research.sqlite")
            try await database.backup(to: dbURL.path)
            let snapshot = try ResearchDatabase(path: dbURL.path)
            var files: [ArchiveFile] = []
            for topic in try await snapshot.list() {
                for artifact in try await snapshot.artifacts(topic.id) {
                    let bytes = try await objects.read(artifact, researchID: topic.id)
                    files.append(try write(bytes, path: "objects/" + artifact.relativePath, root: staging))
                }
            }
            try await snapshot.close()
            let data = try Data(contentsOf: dbURL)
            files.append(ArchiveFile(path: "research.sqlite", hash: Codec.hash(data), bytes: data.count))
            try Codec.encode(ArchiveManifest(kind: "backup", files: files)).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            try validate(staging)
            try FileManager.default.moveItem(at: staging, to: destination)
            return destination
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
    }
    public static func export(_ state: ResearchSnapshot, database: ResearchDatabase, objects: ArtifactStore, directory: URL) async throws -> URL {
        guard state.exportReady, !state.manuscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NormaError.forbidden("Export requires verified I1–I4, meta acceptance and explicit confirmation") }
        let evidence = try await database.artifacts(state.id)
        let edges = try await database.edges(state.id)
        guard state.runs.contains(where: { $0.state == .succeeded }), state.runs.allSatisfy({ [.succeeded, .failed, .cancelled].contains($0.state) }) else { throw NormaError.forbidden("Unresolved experiment evidence") }
        for run in state.runs where run.state == .succeeded {
            guard let metricHash = run.artifactHash, evidence.contains(where: { $0.hash == metricHash && $0.kind == .metric }) else { throw NormaError.invalid("Missing metric artifact") }
            let inputs = Set(edges.filter { $0.sourceHash == metricHash && $0.relation == "derivedFrom" }.map(\.targetHash))
            guard inputs.isSuperset(of: [run.codeHash, run.dataHash, run.protocolHash]), evidence.contains(where: { $0.kind == .environment && inputs.contains($0.hash) }) else { throw NormaError.invalid("Incomplete metric provenance") }
        }
        let staging = directory.appendingPathComponent(UUID().uuidString + ".partial")
        let destination = directory.appendingPathComponent(state.id.uuidString + "-v" + String(state.contract.version) + "-" + UUID().uuidString + ".normaresearch")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            var files = [try write(Codec.encode(state), path: "research.json", root: staging),
                         try write(Data(state.manuscript.utf8), path: "manuscript.md", root: staging),
                         try write(Codec.encode(edges), path: "evidence-edges.json", root: staging),
                         try write(Codec.encode(evidence), path: "evidence-index.json", root: staging)]
            for artifact in evidence { files.append(try write(await objects.read(artifact, researchID: state.id), path: "objects/" + artifact.relativePath, root: staging)) }
            try Codec.encode(ArchiveManifest(kind: "research", files: files)).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            try validate(staging)
            try FileManager.default.moveItem(at: staging, to: destination)
            return destination
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
    }
    public static func validate(_ directory: URL) throws {
        let manifest = try Codec.decode(ArchiveManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest.version == 1, !manifest.files.isEmpty, Set(manifest.files.map(\.path)).count == manifest.files.count else { throw NormaError.invalid("Invalid archive manifest") }
        let root = directory.resolvingSymlinksInPath().path + "/"
        for file in manifest.files {
            guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains("..") else { throw NormaError.forbidden("Invalid archive path") }
            let url = directory.appendingPathComponent(file.path).resolvingSymlinksInPath()
            guard url.path.hasPrefix(root) else { throw NormaError.forbidden("Archive path escape") }
            let bytes = try Data(contentsOf: url)
            guard bytes.count == file.bytes, Codec.hash(bytes) == file.hash else { throw NormaError.invalid("Archive checksum mismatch") }
        }
    }
    private static func write(_ data: Data, path: String, root: URL) throws -> ArchiveFile {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return ArchiveFile(path: path, hash: Codec.hash(data), bytes: data.count)
    }
}
