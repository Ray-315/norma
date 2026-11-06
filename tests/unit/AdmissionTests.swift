import XCTest
import Foundation
@testable import ResearchKernel

private actor Counts {
    var active: [UUID: Int] = [:]
    var maximum = 0
    var perTopicMaximum = 0
    var completed = 0
    func enter(_ topic: UUID) {
        active[topic, default: 0] += 1
        maximum = max(maximum, active.values.reduce(0, +))
        perTopicMaximum = max(perTopicMaximum, active[topic, default: 0])
    }
    func leave(_ topic: UUID) { active[topic, default: 0] -= 1; completed += 1 }
    func values() -> (Int, Int, Int) { (maximum, perTopicMaximum, completed) }
}
final class AdmissionTests: XCTestCase {
    func testQueuedTasksRespectFourByTwoLimit() async throws {
        let scheduler = FairScheduler(), counts = Counts()
        let topics = (0..<4).map { _ in UUID() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for topic in topics {
                for _ in 0..<3 {
                    group.addTask {
                        let task = UUID()
                        try await scheduler.acquire(topic: topic, task: task)
                        try await scheduler.beginModel(topic: topic, task: task)
                        await counts.enter(topic)
                        try await Task.sleep(for: .milliseconds(10))
                        await counts.leave(topic)
                        await scheduler.release(topic: topic, task: task)
                    }
                }
            }
            try await group.waitForAll()
        }
        let result = await counts.values()
        XCTAssertLessThanOrEqual(result.0, 8)
        XCTAssertLessThanOrEqual(result.1, 2)
        XCTAssertEqual(result.2, 12)
    }
    func testCancelledWaiterDoesNotConsumeCapacity() async throws {
        let scheduler = FairScheduler(), topic = UUID(), id = UUID()
        await scheduler.setMemoryPressure(true)
        let waiting = Task { try await scheduler.acquire(topic: topic, task: id) }
        try await Task.sleep(for: .milliseconds(10))
        waiting.cancel()
        do { try await waiting.value; XCTFail("Cancelled waiter admitted") } catch {}
        await scheduler.setMemoryPressure(false)
        let first = UUID(), second = UUID()
        try await scheduler.acquire(topic: topic, task: first)
        try await scheduler.acquire(topic: topic, task: second)
        await scheduler.release(topic: topic, task: first)
        await scheduler.release(topic: topic, task: second)
        try await scheduler.unregister(topic)
    }
}
