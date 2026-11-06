import Foundation
import ResearchContracts

public actor ArtifactStore {
    private let root: URL
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func put(_ data: Data, kind: ArtifactKind, researchID: UUID) throws -> EvidenceArtifact {
        let hash = Codec.hash(data)
        let relative = researchID.uuidString + "/" + String(hash.prefix(2)) + "/" + hash
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: url.path) {
            guard Codec.hash(try Data(contentsOf: url)) == hash else { throw NormaError.invalid("Existing object was tampered with") }
        } else {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        }
        return EvidenceArtifact(hash: hash, kind: kind, researchID: researchID, createdAt: Date(), byteCount: data.count, relativePath: relative)
    }
    public func read(_ artifact: EvidenceArtifact, researchID: UUID) throws -> Data {
        guard artifact.researchID == researchID else { throw NormaError.forbidden("Cross-topic artifact access") }
        let expected = researchID.uuidString + "/" + String(artifact.hash.prefix(2)) + "/" + artifact.hash
        guard artifact.relativePath == expected, artifact.hash.count == 64, artifact.hash.allSatisfy({ $0.isHexDigit }) else { throw NormaError.invalid("Invalid object identity") }
        let url = root.appendingPathComponent(expected).resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw NormaError.forbidden("Artifact path escape") }
        let data = try Data(contentsOf: url)
        guard data.count == artifact.byteCount, Codec.hash(data) == artifact.hash else { throw NormaError.invalid("Evidence integrity failure") }
        return data
    }
}
