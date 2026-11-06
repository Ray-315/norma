import Foundation
import CryptoKit

public enum NormaError: Error, Codable, Sendable, Equatable, LocalizedError {
    case invalid(String), unavailable(String), conflict, forbidden(String), budgetExhausted, cancelled
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .unavailable(let s), .forbidden(let s): s
        case .conflict: "Revision conflict"
        case .budgetExhausted: "Authorized budget exhausted"
        case .cancelled: "Cancelled"
        }
    }
}
public enum Codec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .millisecondsSince1970
        return try e.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970
        return try d.decode(type, from: data)
    }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func digest<T: Encodable>(_ value: T) throws -> String { hash(try encode(value)) }
}
public enum ResearchPhase: String, Codable, CaseIterable, Sendable {
    case created, limitations, seeds, baseline, subset, fullSet, evolution, selection, ablation, refinement, writing, peerReview, rebuttal, metaReview, integrity, finished
    public var group: Int {
        switch self {
        case .created, .limitations, .seeds, .evolution: 0
        case .baseline, .subset, .fullSet: 1
        case .selection, .ablation, .refinement: 2
        case .writing: 3
        case .peerReview, .rebuttal: 4
        case .metaReview, .integrity, .finished: 5
        }
    }
}
public enum OperationState: String, Codable, Sendable {
    case ready, queued, running, waitingApproval, waitingAuth, waitingResource, paused, cancelPending, cancelled, failed, unknown, succeeded
    public var occupiesSlot: Bool { self == .running || self == .cancelPending || self == .unknown }
}
public enum ResearchOutcome: String, Codable, Sendable { case noCandidate, noContribution, priorBest, unresolvedReview, budgetExhausted, integrityFailed, verified, smokeVerified }
public enum Role: String, Codable, CaseIterable, Sendable {
    case limitationExtractor, limitationVerifier, seedGenerator, noveltyChecker, evolver
    case baselineCoder, subsetCoder, subsetCritic, subsetEngineer, fullSetCoder, fullSetCritic, fullSetEngineer
    case selector, ablationPlanner, ablationCoder, ablationCritic, comparison, writer, enhancer, peerReviewer, rebuttalPlanner, rebuttalCoder, metaReviewer, scoreVerifier, specificationAuditor, referenceVerifier, alignmentAuditor
}
public enum CandidateStatus: String, Codable, Sendable { case untested, subsetGood, fullGood, bad, inconclusive }
public struct Hypothesis: Codable, Sendable, Identifiable {
    public var id = UUID(); public var title: String; public var mechanism: String
    public var parentIDs: [UUID] = []; public var evolved = false; public var status: CandidateStatus = .untested
    public var noveltyReferences: [String] = []; public var diagnostics = ""
    public init(title: String, mechanism: String) { self.title = title; self.mechanism = mechanism }
}
public struct ResearchProfile: Codable, Sendable, Equatable {
    public var limitationIterations = 16; public var ideaRounds = 4; public var successThreshold = 4
    public var engineeringRetries = 2; public var ablationRefinements = 1; public var peerRounds = 2
    public var peerEarlyStopScore = 8; public var metaRefinements = 1; public var noveltyReferences = 2
    public var seedCount: Int; public var initialCandidateCount: Int
    public init(seedCount: Int, initialCandidateCount: Int) { self.seedCount = seedCount; self.initialCandidateCount = initialCandidateCount }
    public func validate() throws {
        guard seedCount > 0, initialCandidateCount > 0, initialCandidateCount <= seedCount,
              limitationIterations > 0, ideaRounds > 0, successThreshold > 0,
              engineeringRetries >= 0, ablationRefinements >= 0, peerRounds > 0,
              (0...10).contains(peerEarlyStopScore), metaRefinements >= 0, noveltyReferences >= 2 else { throw NormaError.invalid("Invalid research profile") }
    }
}
public struct ResearchContract: Codable, Sendable, Equatable {
    public var id = UUID(); public var version = 1
    public var title: String; public var question: String; public var metric: String; public var constraints: String
    public var profile = ResearchProfile(seedCount: 2, initialCandidateCount: 1)
    public var createdAt = Date()
    public init(title: String, question: String, metric: String, constraints: String = "") {
        self.title = title; self.question = question; self.metric = metric; self.constraints = constraints
    }
}
