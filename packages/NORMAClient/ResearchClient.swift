import Foundation
import ResearchContracts

public protocol ResearchClientProtocol: Sendable {
    func send(_ request: IPCRequest) async throws -> IPCResponse
}
public final class XPCResearchClient: ResearchClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    public init() {}
    private func connected() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let connection { return connection }
        let c = NSXPCConnection(machServiceName: "app.norma.research")
        c.remoteObjectInterface = NSXPCInterface(with: ResearchXPCProtocol.self)
        c.invalidationHandler = { [weak self] in self?.invalidate() }
        c.interruptionHandler = { [weak self] in self?.invalidate() }
        c.resume(); connection = c; return c
    }
    private func invalidate() { lock.lock(); connection = nil; lock.unlock() }
    public func send(_ request: IPCRequest) async throws -> IPCResponse {
        let data = try Codec.encode(request), c = connected()
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            let once = ReplyOnce(continuation)
            guard let proxy = c.remoteObjectProxyWithErrorHandler({ once.finish(.failure($0)) }) as? ResearchXPCProtocol else {
                once.finish(.failure(NormaError.unavailable("Research service unavailable"))); return
            }
            proxy.request(data) { once.finish(.success($0)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 45) { once.finish(.failure(NormaError.unavailable("Research service timed out"))) }
        }
        let response = try Codec.decode(IPCResponse.self, from: reply)
        guard response.id == request.id, response.version == 1 else { throw NormaError.invalid("IPC response mismatch") }
        return response
    }
}
private final class ReplyOnce: @unchecked Sendable {
    private let lock = NSLock(); private var continuation: CheckedContinuation<Data, Error>?
    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Data, Error>) {
        lock.lock(); let value = continuation; continuation = nil; lock.unlock(); value?.resume(with: result)
    }
}
public extension ResearchClientProtocol {
    func call<Input: Encodable, Output: Decodable>(_ method: String, _ input: Input, as type: Output.Type) async throws -> Output {
        let response = try await send(IPCRequest(method: method, value: input))
        if let error = response.error { throw error }
        guard let data = response.payload else { throw NormaError.invalid("Missing service response") }
        return try Codec.decode(type, from: data)
    }
}
public actor MockResearchClient: ResearchClientProtocol {
    private var snapshots: [ResearchSnapshot]
    public init() {
        var state = ResearchSnapshot(contract: ResearchContract(title: "演示 · 最小二乘拟合", question: "验证直线拟合是否符合已知答案", metric: "MSE"))
        state.hypotheses = [Hypothesis(title: "用解析方法拟合直线", mechanism: "使用正规方程求解")]
        snapshots = [state]
    }
    public func send(_ request: IPCRequest) async throws -> IPCResponse {
        if request.method == "research.list" { return IPCResponse(id: request.id, payload: try Codec.encode(snapshots)) }
        return IPCResponse(id: request.id, error: .unavailable("Demo provider: operation is not connected"))
    }
}
