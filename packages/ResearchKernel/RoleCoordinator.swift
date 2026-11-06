import Foundation
import ResearchContracts
import ResearchStore
import ExperimentManager
import AgentRuntime
import AuthCoordinator

/// All production role invocations go through durable admission and budget reservation.
/// The GUI and model transport cannot independently spend a topic's invocation budget.
public actor RoleCoordinator {
    private let store: ResearchDatabase
    private let accounts: Accounts
    private let scheduler: FairScheduler
    private let root: URL
    private var runtimes: [UUID: RoleRuntime] = [:]
    public init(store: ResearchDatabase, accounts: Accounts, scheduler: FairScheduler, root: URL) {
        self.store = store; self.accounts = accounts; self.scheduler = scheduler; self.root = root
    }
    public func execute(researchID: UUID, role: Role, prompt: String) async throws -> AgentResult {
        var state = try await store.snapshot(researchID)
        guard let auth = state.authorization else { throw NormaError.forbidden("Research authorization required") }
        try ExecutionGate.validateModel(state, model: auth.model)
        let account = try await accounts.status(auth.profileID)
        guard account.authenticated else { throw NormaError.unavailable("Account authentication required") }
        let models = try await accounts.models(auth.profileID)
        guard let selected = models.first(where: { $0.id == auth.model }), selected.reasoning.contains(auth.reasoning) else {
            throw NormaError.unavailable("Authorized model or reasoning effort is unavailable")
        }
        let task = UUID()
        try await scheduler.acquire(topic: researchID, task: task)
        do {
            try Task.checkCancellation()
            try await scheduler.beginModel(topic: researchID, task: task)
            state = try await store.snapshot(researchID)
            guard state.authorization?.id == auth.id else { throw NormaError.forbidden("Authorization changed while queued") }
            try ExecutionGate.validateModel(state, model: auth.model)
            let nextUsedCalls = (state.authorization?.usedModelCalls ?? state.modelCalls) + 1
            state.authorization?.usedModelCalls = nextUsedCalls
            state.modelCalls += 1
            _ = try await store.update(state, expected: state.revision, kind: "model.reserved", detail: role.rawValue + " / " + task.uuidString,
                invocation: AgentCheckpoint(id: task, researchID: researchID, role: role, model: auth.model, state: .queued))
            let workspace = root.appendingPathComponent(researchID.uuidString).appendingPathComponent(role.rawValue)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var invocation = AgentInvocation(researchID: researchID, role: role, model: auth.model, reasoning: auth.reasoning,
                prompt: prompt, workspace: workspace.path, profile: auth.profileID)
            invocation.id = task
            let database = store
            let runtime = RoleRuntime(bridge: try await accounts.bridge(auth.profileID), checkpoint: { try await database.checkpoint($0) })
            runtimes[invocation.id] = runtime
            do {
                let result = try await runtime.execute(invocation)
                if var record = try await store.invocations().first(where: { $0.id == task }) {
                    record.state = .succeeded; record.result = result; try await store.checkpoint(record)
                }
                runtimes.removeValue(forKey: invocation.id)
                state = try await store.snapshot(researchID)
                _ = try await store.update(state, expected: state.revision, kind: "model.completed",
                    detail: role.rawValue + " / thread " + result.threadID)
                await scheduler.release(topic: researchID, task: task)
                try? await scheduler.unregister(researchID)
                return result
            } catch {
                runtimes.removeValue(forKey: invocation.id)
                throw error
            }
        } catch {
            if var record = try? await store.invocations().first(where: { $0.id == task }) {
                if record.state != .succeeded { record.state = .unknown; try? await store.checkpoint(record) }
            }
            await scheduler.release(topic: researchID, task: task)
            try? await scheduler.unregister(researchID)
            throw error
        }
    }
    public func interrupt(_ invocationID: UUID) async throws { try await runtimes[invocationID]?.interrupt(invocationID) }
}
