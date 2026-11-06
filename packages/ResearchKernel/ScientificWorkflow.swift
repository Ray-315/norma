import Foundation
import ResearchContracts
import ReviewEngine

/// Decisions are proposed by roles and accepted only with verified evidence.
/// This reducer contains no model transport and cannot manufacture experiment results.
public enum ScientificSignal: Sendable {
    case contractAuthorized
    case budgetExhausted
    case limitations(verified: Bool)
    case seeds(verifiedCount: Int)
    case baseline(reproduced: Bool)
    case subset(verdict: ExperimentVerdict, evidence: Bool)
    case fullSet(verdict: ExperimentVerdict, evidence: Bool, compliant: Bool)
    case nextRound(hasUntriedSeed: Bool, evolvedFromCompleteHistory: Bool)
    case selection(candidateID: UUID, fullGoodIDs: Set<UUID>)
    case ablation(attributable: Bool, needsRefinement: Bool)
    case comparison(improved: Bool, sameProtocol: Bool, evidence: Bool)
    case manuscript(evidenceComplete: Bool)
    case peer(score: Int, empiricalObjections: Bool)
    case rebuttal(experimentsComplete: Bool)
    case meta(accepted: Bool)
    case integrity([Check])
}
public enum ExperimentVerdict: String, Codable, Sendable { case good, engineer, bad }
public enum RefinementOrigin: String, Codable, Sendable { case ablation, meta }
public struct WorkflowState: Codable, Sendable {
    public var phase: ResearchPhase = .created
    public var outcome: ResearchOutcome?
    public var limitationAttempts = 0; public var seedAttempts = 0
    public var round = 0; public var successes = 0; public var engineeringAttempts = 0
    public var ablationRefinements = 0; public var peerRounds = 0; public var metaRefinements = 0
    public var best: UUID?; public var refinementOrigin: RefinementOrigin?; public var metaAccepted = false
    public var candidatesRemaining = 0
    public var priorAttributionPassed = false
    public var profile: ResearchProfile
    public init(profile: ResearchProfile) { self.profile = profile }
    public mutating func apply(_ signal: ScientificSignal) throws {
        var candidate = self
        try candidate.reduce(signal)
        self = candidate
    }
    private mutating func reduce(_ signal: ScientificSignal) throws {
        guard outcome == nil else { throw NormaError.invalid("Research is terminal") }
        if case .budgetExhausted = signal { finish(.budgetExhausted); return }
        switch (phase, signal) {
        case (.created, .contractAuthorized): phase = .limitations
        case (.limitations, .limitations(let verified)):
            limitationAttempts += 1
            if verified { phase = .seeds }
            else if limitationAttempts >= profile.limitationIterations { finish(.noCandidate) }
        case (.seeds, .seeds(let count)):
            seedAttempts += 1
            if count >= profile.seedCount { phase = .baseline }
        case (.baseline, .baseline(let reproduced)):
            guard reproduced else { throw NormaError.forbidden("Baseline reproduction required") }
            phase = .subset; engineeringAttempts = 0; candidatesRemaining = profile.initialCandidateCount
        case (.subset, .subset(let verdict, let evidence)):
            guard evidence else { throw NormaError.forbidden("Missing subset evidence") }
            switch verdict {
            case .good: phase = .fullSet; engineeringAttempts = 0
            case .bad: finishCandidate()
            case .engineer:
                if engineeringAttempts < profile.engineeringRetries { engineeringAttempts += 1 }
                else { finishCandidate() }
            }
        case (.fullSet, .fullSet(let verdict, let evidence, let compliant)):
            guard evidence else { throw NormaError.forbidden("Missing full-set evidence") }
            if !compliant { finishCandidate(); break }
            switch verdict {
            case .good: successes += 1; finishCandidate()
            case .bad: finishCandidate()
            case .engineer:
                if engineeringAttempts < profile.engineeringRetries { engineeringAttempts += 1 }
                else { finishCandidate() }
            }
        case (.evolution, .nextRound(let seed, let history)):
            round += 1
            if successes >= profile.successThreshold || round >= profile.ideaRounds {
                if successes == 0 { finish(.noCandidate) } else { phase = .selection }
            } else {
                guard history else { throw NormaError.forbidden("Evolution requires complete success/failure history index") }
                guard seed else { throw NormaError.forbidden("Untried seed pool exhausted; explicitly replenish before proceeding") }
                phase = .subset; engineeringAttempts = 0; candidatesRemaining = 2
            }
        case (.selection, .selection(let candidate, let fullGood)):
            guard fullGood.contains(candidate), successes > 0 else { throw NormaError.forbidden("Best candidate must be full-good") }
            best = candidate; phase = .ablation
        case (.ablation, .ablation(let attributable, let needsRefinement)):
            priorAttributionPassed = attributable
            if needsRefinement && ablationRefinements < profile.ablationRefinements {
                ablationRefinements += 1; refinementOrigin = .ablation; phase = .refinement
            } else if attributable { phase = .writing }
            else { finish(.noContribution) }
        case (.refinement, .comparison(let improved, let sameProtocol, let evidence)):
            guard sameProtocol, evidence else { throw NormaError.forbidden("Comparable full-set evidence required") }
            if improved { phase = .ablation; peerRounds = 0 }
            else if refinementOrigin == .meta { finish(.priorBest) }
            else if priorAttributionPassed { phase = .writing }
            else { finish(.noContribution) }
        case (.writing, .manuscript(let complete)):
            guard complete else { throw NormaError.forbidden("Manuscript claims require evidence") }
            phase = .peerReview
        case (.peerReview, .peer(let score, let empirical)):
            guard (0...10).contains(score) else { throw NormaError.invalid("Invalid peer score") }
            peerRounds += 1
            if score >= profile.peerEarlyStopScore && !empirical { phase = .metaReview }
            else if peerRounds < profile.peerRounds { phase = .rebuttal }
            else { phase = .metaReview }
        case (.rebuttal, .rebuttal(let complete)):
            guard complete else { throw NormaError.forbidden("Empirical objections need actual supplementary experiments") }
            phase = .writing
        case (.metaReview, .meta(let accepted)):
            metaAccepted = accepted
            if accepted { phase = .integrity }
            else if metaRefinements < profile.metaRefinements {
                metaRefinements += 1; refinementOrigin = .meta; phase = .refinement
            } else { finish(.unresolvedReview) }
        case (.integrity, .integrity(let checks)):
            guard checks.count == 4, Set(checks.map(\.id)) == Set(["I1", "I2", "I3", "I4"]) else { throw NormaError.forbidden("All four integrity dimensions required") }
            finish(checks.allSatisfy { $0.status == .pass } ? .verified : .integrityFailed)
        default: throw NormaError.invalid("Illegal scientific stage transition")
        }
    }
    private mutating func finish(_ value: ResearchOutcome) { outcome = value; phase = .finished }
    private mutating func finishCandidate() {
        candidatesRemaining = max(0, candidatesRemaining - 1)
        engineeringAttempts = 0
        phase = candidatesRemaining > 0 ? .subset : .evolution
    }
}
