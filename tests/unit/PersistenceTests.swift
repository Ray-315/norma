import XCTest
import ResearchContracts
import ResearchStore

final class PersistenceTests: XCTestCase {
    func testContractVersionCannotBeMutatedInPlace() async throws {
        let db = try ResearchDatabase(path: ":memory:")
        var state = try await db.create(ResearchContract(title: "before", question: "q", metric: "m"))
        state.contract.title = "after"
        do { _ = try await db.update(state, expected: 0, kind: "edit", detail: ""); XCTFail("Mutable contract") } catch {}
        let saved = try await db.snapshot(state.id)
        XCTAssertEqual(saved.contract.title, "before")
        XCTAssertEqual(saved.revision, 0)
    }
    func testReactivationCannotExceedFourActiveTopics() async throws {
        let db = try ResearchDatabase(path: ":memory:")
        var first = try await db.create(ResearchContract(title: "0", question: "q", metric: "m"))
        first.operation = .cancelled
        first = try await db.update(first, expected: 0, kind: "cancel", detail: "")
        for index in 1...4 { _ = try await db.create(ResearchContract(title: String(index), question: "q", metric: "m")) }
        first.operation = .ready
        do { _ = try await db.update(first, expected: 1, kind: "resume", detail: ""); XCTFail("Fifth active topic") } catch {}
        let saved = try await db.snapshot(first.id)
        XCTAssertEqual(saved.operation, .cancelled)
    }
    func testDuplicateIntegrityLabelsCannotPassExportGate() {
        var state = ResearchSnapshot(contract: ResearchContract(title: "test", question: "q", metric: "m"))
        state.phase = .finished; state.operation = .succeeded; state.outcome = .verified
        state.metaAccepted = true; state.exportConfirmed = true
        state.integrity = (0..<4).map { _ in Check("I1", .pass, "") }
        XCTAssertFalse(state.exportReady)
        state.integrity = (1...4).map { Check("I" + String($0), .pass, "") }
        XCTAssertTrue(state.exportReady)
        state.metaAccepted = false
        XCTAssertFalse(state.exportReady)
    }
}
