import Foundation
import Security
import ResearchContracts
import ResearchKernel

final class ConnectionHandler: NSObject, ResearchXPCProtocol, @unchecked Sendable {
    let service: ResearchService
    init(service: ResearchService) { self.service = service }
    func request(_ data: Data, reply: @escaping (Data) -> Void) {
        let callback = Callback(reply)
        guard data.count <= 2_000_000, let request = try? Codec.decode(IPCRequest.self, from: data) else {
            callback.invoke(Data()); return
        }
        Task { let response = await service.handle(request); callback.invoke((try? Codec.encode(response)) ?? Data()) }
    }
}
final class Callback: @unchecked Sendable {
    let block: (Data) -> Void
    init(_ block: @escaping (Data) -> Void) { self.block = block }
    func invoke(_ data: Data) { block(data) }
}
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let handler: ConnectionHandler
    init(service: ResearchService) { handler = ConnectionHandler(service: service) }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid(), trusted(pid: connection.processIdentifier) else { return false }
        connection.exportedInterface = NSXPCInterface(with: ResearchXPCProtocol.self)
        connection.exportedObject = handler; connection.resume(); return true
    }
    private func trusted(pid: pid_t) -> Bool {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { return false }
        var own: SecStaticCode?, peer: SecCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &own) == errSecSuccess, let own,
              SecCodeCopyDesignatedRequirement(own, [], &requirement) == errSecSuccess,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &peer) == errSecSuccess,
              let peer, let requirement else { return false }
        return SecCodeCheckValidity(peer, [], requirement) == errSecSuccess
    }
}

let root = ProcessInfo.processInfo.environment["NORMA_DATA_ROOT"].map { URL(fileURLWithPath: $0) } ??
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NORMA")
let override = ProcessInfo.processInfo.environment["NORMA_WORKER"]
let worker = override.map { URL(fileURLWithPath: $0) } ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/worker.py")
do {
    let service = try ResearchService(root: root, worker: worker)
    if ProcessInfo.processInfo.arguments.contains("--local-smoke") {
        Task {
            do {
                let contract = ResearchContract(title: "Known solved: least-squares line", question: "Do five points on y=2x+1 recover the analytic line?", metric: "MSE")
                let id = try await service.createResearch(contract)
                var state = try await service.prepareSmoke(ResearchCommand(id: id, revision: 0))
                state = try await service.confirmPlan(ResearchCommand(id: id, revision: state.revision))
                state = try await service.selectLocal(ResearchCommand(id: id, revision: state.revision))
                state = try await service.preflight(ResearchCommand(id: id, revision: state.revision))
                guard let report = state.preflight, report.passed else { throw NormaError.unavailable("Smoke preflight failed") }
                let auth = ResearchAuthorization(researchID: id, contractVersion: 1, target: await service.compute.node(),
                    fingerprint: report.environmentFingerprint, expiresAt: Date().addingTimeInterval(300),
                    maxModelCalls: 0, maxRuns: 2, maxRuntimeSeconds: 30)
                state = try await service.authorize(AuthorizeCommand(revision: state.revision, authorization: auth))
                try await service.startSmoke(ResearchCommand(id: id, revision: state.revision))
                for _ in 0..<120 {
                    try await Task.sleep(for: .milliseconds(250))
                    state = try await service.snapshot(id)
                    if state.operation != .running { break }
                }
                let data = try Codec.encode(state)
                try data.write(to: root.appendingPathComponent("smoke-report.json"), options: .atomic)
                print("Smoke: " + state.operation.rawValue + "; model calls: " + String(state.modelCalls))
                guard state.outcome == .smokeVerified, state.runs.count == 2, state.integrity.first?.status == .pass else {
                    throw NormaError.unavailable(state.lastError ?? "Smoke incomplete")
                }
                exit(0)
            } catch { print("Smoke failed: " + error.localizedDescription); exit(1) }
        }
        RunLoop.current.run()
        exit(1)
    }
    let delegate = ListenerDelegate(service: service)
    let listener = NSXPCListener(machServiceName: "app.norma.research")
    listener.delegate = delegate
    Task { try? await service.recover() }
    listener.resume()
    RunLoop.current.run()
    withExtendedLifetime(delegate) {}
} catch {
    fputs("NORMA service initialization failed\n", stderr)
    exit(1)
}
