import XCTest
import ResearchContracts
@testable import ResearchKernel

final class WorkflowTests: XCTestCase {
    func testSeedGenerationUsesAuthorizationBudgetNotLimitationAttemptCap() throws {
        var state = WorkflowState(profile: ResearchProfile(seedCount: 2, initialCandidateCount: 1))
        state.phase = .seeds
        for _ in 0..<17 { try state.apply(.seeds(verifiedCount: 1)) }
        XCTAssertEqual(state.phase, .seeds)
        XCTAssertNil(state.outcome)
        try state.apply(.budgetExhausted)
        XCTAssertEqual(state.outcome, .budgetExhausted)
    }
    func testZeroSuccessfulCandidateTerminatesWithoutWriting() throws {
        var profile = ResearchProfile(seedCount: 2, initialCandidateCount: 1)
        profile.ideaRounds = 1
        var state = WorkflowState(profile: profile)
        try state.apply(.contractAuthorized)
        try state.apply(.limitations(verified: true))
        try state.apply(.seeds(verifiedCount: 1))
        XCTAssertEqual(state.phase, .seeds)
        try state.apply(.seeds(verifiedCount: 2))
        XCTAssertThrowsError(try state.apply(.baseline(reproduced: false)))
        try state.apply(.baseline(reproduced: true))
        try state.apply(.subset(verdict: .bad, evidence: true))
        try state.apply(.nextRound(hasUntriedSeed: true, evolvedFromCompleteHistory: true))
        XCTAssertEqual(state.outcome, .noCandidate)
        XCTAssertThrowsError(try state.apply(.manuscript(evidenceComplete: true)))
    }
    func testI2RejectsOtherwiseGoodFullSet() throws {
        var state = WorkflowState(profile: ResearchProfile(seedCount: 1, initialCandidateCount: 1))
        state.phase = .fullSet; state.candidatesRemaining = 1
        try state.apply(.fullSet(verdict: .good, evidence: true, compliant: false))
        XCTAssertEqual(state.successes, 0)
        XCTAssertEqual(state.phase, .evolution)
    }
    func testMetaNonImprovementRetainsBestAndDoesNotAccept() throws {
        var state = WorkflowState(profile: ResearchProfile(seedCount: 1, initialCandidateCount: 1))
        let best = UUID()
        state.best = best; state.phase = .metaReview
        try state.apply(.meta(accepted: false))
        XCTAssertEqual(state.phase, .refinement)
        try state.apply(.comparison(improved: false, sameProtocol: true, evidence: true))
        XCTAssertEqual(state.best, best); XCTAssertEqual(state.outcome, .priorBest)
        XCTAssertFalse(state.metaAccepted)
    }
    func testNewRoundIncludesSeedAndEvolvedAndRequiresFailureHistory() throws {
        var state = WorkflowState(profile: ResearchProfile(seedCount: 3, initialCandidateCount: 1))
        state.phase = .evolution
        XCTAssertThrowsError(try state.apply(.nextRound(hasUntriedSeed: true, evolvedFromCompleteHistory: false)))
        state.round = 0
        try state.apply(.nextRound(hasUntriedSeed: true, evolvedFromCompleteHistory: true))
        XCTAssertEqual(state.candidatesRemaining, 2)
        try state.apply(.subset(verdict: .bad, evidence: true))
        XCTAssertEqual(state.phase, .subset)
        try state.apply(.subset(verdict: .bad, evidence: true))
        XCTAssertEqual(state.phase, .evolution)
    }
}
