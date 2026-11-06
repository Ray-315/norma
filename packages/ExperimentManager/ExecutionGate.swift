import Foundation
import ResearchContracts

public enum ExecutionGate {
    public static func validate(plan: ExperimentPlan, authorization: ResearchAuthorization?,
                                preflight: TargetPreflightReport?, currentFingerprint: String,
                                reservedRuns: Int, now: Date = Date()) throws {
        guard plan.frozen, !plan.hash.isEmpty else { throw NormaError.forbidden("Plan is not frozen") }
        guard let auth = authorization, !auth.revoked, auth.expiresAt > now else { throw NormaError.forbidden("Missing, expired or revoked research authorization") }
        guard auth.researchID == plan.researchID, auth.contractVersion == plan.contractVersion else { throw NormaError.forbidden("Contract scope mismatch") }
        guard plan.runtimeSeconds > 0, plan.runtimeSeconds <= auth.maxRuntimeSeconds else { throw NormaError.forbidden("Runtime exceeds scope") }
        guard reservedRuns >= 0, reservedRuns < auth.maxRuns else { throw NormaError.budgetExhausted }
        guard let report = preflight, report.passed, report.validUntil > now, report.planHash == plan.hash,
              report.targetID == auth.target.id else { throw NormaError.forbidden("Invalid preflight or selected target") }
        guard currentFingerprint == report.environmentFingerprint, currentFingerprint == auth.environmentFingerprint else { throw NormaError.forbidden("Environment drift") }
    }
    public static func validateModel(_ state: ResearchSnapshot, model: String, now: Date = Date()) throws {
        guard let auth = state.authorization, !auth.revoked, auth.expiresAt > now,
              auth.researchID == state.id, auth.contractVersion == state.contract.version, auth.model == model,
              state.operation != .cancelled, state.operation != .cancelPending, state.operation != .paused,
              state.phase != .finished else { throw NormaError.forbidden("Model is outside approved scope") }
        guard (auth.usedModelCalls ?? state.modelCalls) < auth.maxModelCalls else { throw NormaError.budgetExhausted }
    }
}
