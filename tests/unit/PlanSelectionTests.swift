import XCTest
import Foundation
import ResearchContracts
import ResearchKernel

final class PlanSelectionTests: XCTestCase {
    func testSelectionRequiresPersistedConfirmationAndSurvivesReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("norma-selection-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("workers/experiment-runner/worker.py")
        let service = try ResearchService(root: root, worker: worker)
        let id = try await service.createResearch(ResearchContract(title: "selection", question: "q", metric: "m"))
        var state = try await service.prepareSmoke(ResearchCommand(id: id, revision: 0))
        do { _ = try await service.selectLocal(ResearchCommand(id: id, revision: state.revision)); XCTFail("Unconfirmed target selection") } catch {}
        do { _ = try await service.preflight(ResearchCommand(id: id, revision: state.revision)); XCTFail("Unconfirmed preflight") } catch {}
        state = try await service.confirmPlan(ResearchCommand(id: id, revision: state.revision))
        state = try await service.selectLocal(ResearchCommand(id: id, revision: state.revision))
        let reopened = try ResearchService(root: root, worker: worker)
        let recovered = try await reopened.snapshot(id)
        XCTAssertEqual(recovered.confirmedPlanHash, state.plan?.hash)
        XCTAssertEqual(recovered.selectedTargetID, "local")
        XCTAssertEqual(recovered.modelCalls, 0)
        state = try await service.prepareSmoke(ResearchCommand(id: id, revision: state.revision))
        XCTAssertNil(state.confirmedPlanHash)
        XCTAssertNil(state.selectedTargetID)
        XCTAssertNil(state.preflight)
    }
}
