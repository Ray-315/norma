import Foundation

public struct AutonomousStart: Codable, Sendable {
    public var id: UUID; public var revision: Int; public var maxModelCalls: Int; public var maxRuns: Int
    public var knownProblem: Bool
    public init(id: UUID, revision: Int, maxModelCalls: Int, maxRuns: Int, knownProblem: Bool) {
        self.id = id; self.revision = revision; self.maxModelCalls = maxModelCalls; self.maxRuns = maxRuns; self.knownProblem = knownProblem
    }
}
public struct ProposedExperiment: Codable, Sendable {
    public var question: String
    public var python: String
    public var data: JSONValue
    public var metric: String
    public init(question: String, python: String, data: JSONValue, metric: String) {
        self.question = question; self.python = python; self.data = data; self.metric = metric
    }
    public func validate() throws {
        guard !question.isEmpty, !metric.isEmpty, !python.isEmpty, python.utf8.count <= 64_000,
              case .array(let rows) = data, (1...5).contains(rows.count), try Codec.encode(data).count <= 32_000 else {
            throw NormaError.invalid("实验必须提供 1–5 条数据、评价指标及不超过 64 KB 的 Python 程序。")
        }
    }
}
public struct RoleProposal: Codable, Sendable {
    public var summary: String
    public var decision: String
    public var hypotheses: [Hypothesis]?
    public var experiment: ProposedExperiment?
    public var manuscript: String?
    public var score: Int?
    public var empiricalObjections: Bool?
    public var candidateID: UUID?
    public var evidenceIDs: [UUID]?
    public var references: [String]?
    public var citations: [CitationClaim]?
    public static func parse(_ text: String) throws -> Self {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), let newline = text.firstIndex(of: "\n"), text.hasSuffix("```") {
            text = String(text[text.index(after: newline)...].dropLast(3))
        }
        guard text.utf8.count <= 256_000 else { throw NormaError.invalid("模型输出超出限制。") }
        let result = try Codec.decode(Self.self, from: Data(text.utf8))
        guard !result.summary.isEmpty, ["continue", "good", "engineer", "bad", "accept", "reject", "no_candidate"].contains(result.decision),
              result.summary.range(of: "[\\p{Han}]", options: .regularExpression) != nil else {
            throw NormaError.invalid("模型未返回有效的中文结构化结果。")
        }
        return result
    }
}
public struct CitationClaim: Codable, Sendable {
    public var doi: String; public var title: String; public var sourceHash: String
    public var quote: String; public var claim: String
}
public struct RoleStep: Codable, Sendable, Identifiable {
    public var id: UUID; public var role: Role; public var phase: ResearchPhase; public var proposal: RoleProposal
    public var createdAt = Date()
    public init(id: UUID, role: Role, phase: ResearchPhase, proposal: RoleProposal) {
        self.id = id; self.role = role; self.phase = phase; self.proposal = proposal
    }
}
public struct AutonomousSession: Codable, Sendable {
    public var workflow: Data
    public var knownProblem: Bool
    public var roleIndex = 0
    public var history: [RoleStep] = []
    public var pendingExperiment: ProposedExperiment?
    public var pendingRunIDs: [UUID] = []
    public var currentCandidate: UUID?
    public var candidatesUsed: [UUID] = []
    public var revisionAttempts = 0
    public var failureCount = 0
    public var stepID: UUID?
    public var requestedPause = false
    public init(workflow: Data, knownProblem: Bool) { self.workflow = workflow; self.knownProblem = knownProblem }
}
