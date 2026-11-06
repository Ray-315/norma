import Foundation
public struct ExperimentRun: Codable, Sendable, Identifiable {
    public var id = UUID(); public var kind: ExperimentKind; public var state: OperationState = .queued
    public var planHash: String; public var codeHash: String; public var dataHash: String; public var protocolHash: String
    public var environmentFingerprint: String; public var targetID: String
    public var environment: EnvironmentSnapshot?
    public var metrics: [String: Double] = [:]; public var startedAt = Date(); public var finishedAt: Date?
    public var artifactPath: String?; public var artifactHash: String?; public var log = ""
    public init(kind: ExperimentKind, plan: ExperimentPlan, environment: EnvironmentSnapshot) {
        self.kind = kind; planHash = plan.hash; codeHash = plan.codeHash; dataHash = plan.datasetHash
        protocolHash = plan.protocolHash; environmentFingerprint = environment.fingerprint; targetID = environment.nodeID
        self.environment = environment
    }
}
public struct AuditEvent: Codable, Sendable, Identifiable {
    public var id = UUID(); public var sequence: Int64 = 0; public var researchID: UUID; public var date = Date()
    public var kind: String; public var detail: String
    public init(researchID: UUID, kind: String, detail: String) { self.researchID = researchID; self.kind = kind; self.detail = detail }
}
public struct ReviewRecord: Codable, Sendable, Identifiable {
    public var id = UUID(); public var role: Role; public var text: String; public var score: Double?; public var evidenceIDs: [UUID]
}
public struct ResearchSnapshot: Codable, Sendable, Identifiable {
    public var id: UUID { contract.id }; public var contract: ResearchContract; public var revision = 0
    public var phase: ResearchPhase = .created; public var operation: OperationState = .ready; public var outcome: ResearchOutcome?
    public var hypotheses: [Hypothesis] = []; public var runs: [ExperimentRun] = []; public var reviews: [ReviewRecord] = []
    public var integrity: [Check] = []; public var authorization: ResearchAuthorization?; public var plan: ExperimentPlan?
    public var preflight: TargetPreflightReport?; public var events: [AuditEvent] = []; public var eventSequence: Int64 = 0
    public var confirmedPlanHash: String?
    public var selectedTargetID: String?
    public var modelCalls = 0; public var reservedRuns = 0; public var metaAccepted = false; public var exportConfirmed = false
    public var manuscript = ""; public var lastError: String?
    public var exportReady: Bool {
        phase == .finished && operation == .succeeded && outcome == .verified && metaAccepted && exportConfirmed &&
        integrity.count == 4 && Set(integrity.map(\.id)) == Set(["I1", "I2", "I3", "I4"]) && integrity.allSatisfy { $0.status == .pass }
    }
    public init(contract: ResearchContract) { self.contract = contract }
}
public struct ModelDescriptor: Codable, Sendable, Identifiable {
    public var id: String; public var name: String; public var reasoning: [String]
    public init(id: String, name: String, reasoning: [String]) { self.id = id; self.name = name; self.reasoning = reasoning }
}
public struct AccountStatus: Codable, Sendable {
    public var profile: String; public var authenticated: Bool; public var authType: String?; public var message: String
    public init(profile: String, authenticated: Bool, authType: String? = nil, message: String = "") {
        self.profile = profile; self.authenticated = authenticated; self.authType = authType; self.message = message
    }
}
public struct AgentInvocation: Codable, Sendable, Identifiable {
    public var id = UUID(); public var researchID: UUID; public var role: Role; public var model: String; public var reasoning: String
    public var prompt: String; public var workspace: String; public var profile: String
    public init(researchID: UUID, role: Role, model: String, reasoning: String, prompt: String, workspace: String, profile: String) {
        self.researchID = researchID; self.role = role; self.model = model; self.reasoning = reasoning
        self.prompt = prompt; self.workspace = workspace; self.profile = profile
    }
}
public struct AgentResult: Codable, Sendable {
    public var invocationID: UUID; public var threadID: String; public var text: String
    public init(invocationID: UUID, threadID: String, text: String) { self.invocationID = invocationID; self.threadID = threadID; self.text = text }
}
public struct AgentCheckpoint: Codable, Sendable, Identifiable {
    public var id: UUID; public var researchID: UUID; public var role: Role; public var model: String
    public var threadID: String?; public var turnID: String?; public var state: OperationState
    public var result: AgentResult?
    public init(id: UUID, researchID: UUID, role: Role, model: String, threadID: String? = nil, turnID: String? = nil, state: OperationState) {
        self.id = id; self.researchID = researchID; self.role = role; self.model = model
        self.threadID = threadID; self.turnID = turnID; self.state = state
    }
}
public protocol AgentExecuting: Sendable {
    func execute(_ invocation: AgentInvocation) async throws -> AgentResult
    func interrupt(_ invocationID: UUID) async throws
}
public protocol ResearchOrchestrating: Sendable {
    func createResearch(_ contract: ResearchContract) async throws -> UUID
    func snapshot(_ id: UUID) async throws -> ResearchSnapshot
    func pause(_ id: UUID, expectedRevision: Int) async throws
    func resume(_ id: UUID, expectedRevision: Int) async throws
    func cancel(_ id: UUID, expectedRevision: Int) async throws
}
