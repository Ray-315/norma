import Foundation
import ResearchContracts

public actor FairScheduler {
    private var topics: [UUID] = []
    private var queue: [UUID: [UUID]] = [:]
    private var active: [UUID: Set<UUID>] = [:]
    private var modelCalls: Set<UUID> = []
    private var cursor = 0
    private var memoryPressure = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    public init() {}
    public func register(_ topic: UUID) throws {
        if topics.contains(topic) { return }
        guard topics.count < 4 else { throw NormaError.forbidden("Four active topics maximum") }
        topics.append(topic); queue[topic] = []; active[topic] = []
    }
    public func enqueue(topic: UUID, task: UUID) throws {
        guard topics.contains(topic) else { throw NormaError.invalid("Unregistered topic") }
        if queue[topic]?.contains(task) == true || active[topic]?.contains(task) == true { return }
        queue[topic, default: []].append(task)
    }
    public func next() -> (UUID, UUID)? {
        guard !memoryPressure, !topics.isEmpty else { return nil }
        for _ in topics.indices {
            let topic = topics[cursor % topics.count]; cursor = (cursor + 1) % topics.count
            guard active[topic, default: []].count < 2, let task = queue[topic]?.first else { continue }
            queue[topic]?.removeFirst(); active[topic, default: []].insert(task)
            return (topic, task)
        }
        return nil
    }
    public func beginModel(topic: UUID, task: UUID) throws {
        guard active[topic]?.contains(task) == true, !modelCalls.contains(task), modelCalls.count < 8 else { throw NormaError.forbidden("Model concurrency limit") }
        modelCalls.insert(task)
    }
    public func endModel(_ task: UUID) { modelCalls.remove(task) }
    public func release(topic: UUID, task: UUID) {
        active[topic]?.remove(task); modelCalls.remove(task); drainWaiters()
    }
    public func acquire(topic: UUID, task: UUID) async throws {
        try Task.checkCancellation()
        try register(topic)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard waiters[task] == nil else { continuation.resume(throwing: NormaError.invalid("Duplicate task")); return }
                waiters[task] = continuation
                do { try enqueue(topic: topic, task: task); drainWaiters() }
                catch { waiters.removeValue(forKey: task)?.resume(throwing: error) }
            }
        } onCancel: { Task { await self.cancelWaiting(topic: topic, task: task) } }
    }
    private func cancelWaiting(topic: UUID, task: UUID) {
        queue[topic]?.removeAll { $0 == task }
        waiters.removeValue(forKey: task)?.resume(throwing: NormaError.cancelled)
        drainWaiters()
    }
    private func drainWaiters() {
        guard !waiters.isEmpty else { return }
        while let admitted = next() {
            if let waiter = waiters.removeValue(forKey: admitted.1) { waiter.resume() }
            else {
                active[admitted.0]?.remove(admitted.1)
                queue[admitted.0, default: []].insert(admitted.1, at: 0)
                return
            }
            if waiters.isEmpty { return }
        }
    }
    public func unregister(_ topic: UUID) throws {
        guard active[topic, default: []].isEmpty, queue[topic, default: []].isEmpty else { throw NormaError.forbidden("Topic still running or queued") }
        topics.removeAll { $0 == topic }; queue.removeValue(forKey: topic); active.removeValue(forKey: topic)
        cursor = topics.isEmpty ? 0 : cursor % topics.count
    }
    public func setMemoryPressure(_ pressured: Bool) { memoryPressure = pressured; if !pressured { drainWaiters() } }
}
