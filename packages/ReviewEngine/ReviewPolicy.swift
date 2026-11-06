import ResearchContracts
public enum MetaDecision: Sendable, Equatable { case accepted, refine, finishPriorBest }
public enum ReviewPolicy {
    public static func meta(accepted: Bool, refinementAttempted: Bool, improved: Bool, remaining: Int) -> MetaDecision {
        if accepted { return .accepted }
        if refinementAttempted && !improved { return .finishPriorBest }
        return remaining > 0 ? .refine : .finishPriorBest
    }
    public static func strictImprovement(old: Double, new: Double, higherIsBetter: Bool,
                                         sameProtocol: Bool, constraintsPassed: Bool, evidencePassed: Bool) -> Bool {
        guard old.isFinite, new.isFinite, sameProtocol, constraintsPassed, evidencePassed else { return false }
        return higherIsBetter ? new > old : new < old
    }
    public static func candidate(engineer: Bool, retries: Int, maximum: Int) -> CandidateStatus {
        engineer && retries < maximum ? .inconclusive : .bad
    }
}
