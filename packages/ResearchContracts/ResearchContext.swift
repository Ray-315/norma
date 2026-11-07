import Foundation

public struct ResearchSource: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case attachment, project }
    public var id = UUID()
    public var kind: Kind
    public var name: String
    public var path: String?
    public var bookmark: Data?
    public var artifact: EvidenceArtifact?
    public init(kind: Kind, name: String, path: String? = nil, bookmark: Data? = nil, artifact: EvidenceArtifact? = nil) {
        self.kind = kind; self.name = name; self.path = path; self.bookmark = bookmark; self.artifact = artifact
    }
}
public struct SourceImportCommand: Codable, Sendable {
    public var id: UUID; public var revision: Int; public var paths: [String]; public var project: Bool
    public init(id: UUID, revision: Int, paths: [String], project: Bool) {
        self.id = id; self.revision = revision; self.paths = paths; self.project = project
    }
}
public struct SourceRemoveCommand: Codable, Sendable {
    public var id: UUID; public var revision: Int; public var sourceID: UUID
    public init(id: UUID, revision: Int, sourceID: UUID) { self.id = id; self.revision = revision; self.sourceID = sourceID }
}
public struct TokenUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int; public var outputTokens: Int; public var totalTokens: Int
    public var cachedInputTokens: Int; public var reasoningOutputTokens: Int
    public var cacheWriteInputTokens: Int?
    public init(inputTokens: Int = 0, outputTokens: Int = 0, totalTokens: Int = 0, cachedInputTokens: Int = 0, reasoningOutputTokens: Int = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.totalTokens = totalTokens
        self.cachedInputTokens = cachedInputTokens; self.reasoningOutputTokens = reasoningOutputTokens
    }
    public var isValid: Bool {
        [inputTokens, outputTokens, totalTokens, cachedInputTokens, reasoningOutputTokens, cacheWriteInputTokens ?? 0].allSatisfy { (0...1_000_000_000_000).contains($0) }
    }
}
public struct TokenUsageSummary: Codable, Sendable {
    public var usage = TokenUsage()
    public var recordedCalls = 0
    public init(records: [TokenUsage]) {
        for record in records {
            usage.inputTokens += record.inputTokens; usage.outputTokens += record.outputTokens
            usage.totalTokens += record.totalTokens; usage.cachedInputTokens += record.cachedInputTokens
            usage.reasoningOutputTokens += record.reasoningOutputTokens
            recordedCalls += 1
        }
    }
}
