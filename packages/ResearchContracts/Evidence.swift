import Foundation
public enum ArtifactKind: String, Codable, Sendable { case code, data, protocolDefinition, environment, log, metric, manuscript, citation, review }
public struct EvidenceArtifact: Codable, Sendable, Identifiable {
    public var id: String { hash }
    public var hash: String; public var kind: ArtifactKind; public var researchID: UUID
    public var createdAt: Date; public var byteCount: Int; public var relativePath: String
    public init(hash: String, kind: ArtifactKind, researchID: UUID, createdAt: Date, byteCount: Int, relativePath: String) {
        self.hash = hash; self.kind = kind; self.researchID = researchID; self.createdAt = createdAt
        self.byteCount = byteCount; self.relativePath = relativePath
    }
}
public struct EvidenceEdge: Codable, Sendable, Hashable {
    public var sourceHash: String; public var targetHash: String; public var relation: String
    public init(sourceHash: String, targetHash: String, relation: String) {
        self.sourceHash = sourceHash; self.targetHash = targetHash; self.relation = relation
    }
}
