import XCTest
import ResearchContracts
@testable import ResearchKernel

final class WorkflowTests: XCTestCase {
    func testKnownProblemMayReportEqualResultsWithoutClaimingContribution() throws {
        var state = WorkflowState(profile: ResearchProfile(seedCount: 2, initialCandidateCount: 1))
        state.phase = .ablation
        XCTAssertThrowsError(try state.apply(.knownProblemComparison(verified: true)))
        state.knownProblem = true
        try state.apply(.knownProblemComparison(verified: true))
        XCTAssertEqual(state.phase, .writing)
        XCTAssertFalse(state.priorAttributionPassed)
    }
    func testTextualReviewReturnsToWritingWithoutSpendingExperimentalBudget() throws {
        var state = WorkflowState(profile: ResearchProfile(seedCount: 2, initialCandidateCount: 1))
        state.phase = .peerReview
        try state.apply(.peer(score: 6, empiricalObjections: false))
        XCTAssertEqual(state.phase, .writing)
        XCTAssertEqual(state.peerRounds, 1)
    }
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
    func testAuditReportRevisionIsBoundedAndRevokesAcceptance() throws {
        var state = WorkflowState(profile: ResearchProfile(seedCount: 2, initialCandidateCount: 1))
        state.phase = .integrity; state.metaAccepted = true
        XCTAssertThrowsError(try state.apply(.integrityReportRevision(evidenceIntact: false)))
        try state.apply(.integrityReportRevision(evidenceIntact: true))
        XCTAssertEqual(state.phase, .writing); XCTAssertFalse(state.metaAccepted)
        XCTAssertEqual(state.reportRevisions, 1)
        state.phase = .integrity
        XCTAssertThrowsError(try state.apply(.integrityReportRevision(evidenceIntact: true)))
        try state.apply(.integrity([Check("I1", .pass, ""), Check("I2", .pass, ""), Check("I3", .unknown, ""), Check("I4", .fail, "")]))
        XCTAssertEqual(state.outcome, .integrityFailed)
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
