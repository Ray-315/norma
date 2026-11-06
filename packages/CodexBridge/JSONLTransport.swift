import Foundation
import ResearchContracts

public actor JSONLTransport {
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var serial = 0
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var subscribers: [UUID: AsyncStream<JSONValue>.Continuation] = [:]
    public var isRunning: Bool { process?.isRunning == true }
    public init() {}
    public func start(executable: String, home: URL, credentialsMode: String = "keyring") async throws {
        if process?.isRunning == true { return }
        let p = Process(); p.executableURL = URL(fileURLWithPath: executable)
        guard ["keyring", "auto"].contains(credentialsMode) else { throw NormaError.invalid("Invalid credential storage mode") }
        p.arguments = ["-c", "cli_auth_credentials_store=\"" + credentialsMode + "\"",
                       "-c", "features.shell_snapshot=false", "-c", "features.shell_tool=false",
                       "-c", "features.unified_exec=false", "app-server", "--listen", "stdio://"]
        let inherited = ProcessInfo.processInfo.environment
        var env = Dictionary(uniqueKeysWithValues: ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "SHELL"].compactMap { key in inherited[key].map { (key, $0) } })
        env["CODEX_HOME"] = home.path; p.environment = env; p.currentDirectoryURL = home
        let out = Pipe(), stdin = Pipe()
        p.standardOutput = out; p.standardInput = stdin; p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            Task { await self?.receive(bytes) }
        }
        p.terminationHandler = { [weak self] _ in Task { await self?.failed() } }
        try p.run(); process = p; input = stdin.fileHandleForWriting
        do {
            _ = try await request("initialize", params: .object([
                "clientInfo": .object(["name": .string("norma"), "version": .string("0.1.0")]),
                "capabilities": .object(["experimentalApi": .bool(false)])
            ]))
            try send(.object(["method": .string("initialized")]))
        } catch { stop(); throw error }
    }
    public func notifications() -> AsyncStream<JSONValue> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(2048)) { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        }
    }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
    public func request(_ method: String, params: JSONValue, timeout: UInt64 = 30) async throws -> JSONValue {
        guard process?.isRunning == true else { throw NormaError.unavailable("Codex App Server unavailable") }
        serial += 1; let id = String(serial)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try send(.object(["id": .string(id), "method": .string(method), "params": params])) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error); return }
            Task { try? await Task.sleep(for: .seconds(timeout)); self.expire(id) }
        }
    }
    private func expire(_ id: String) { pending.removeValue(forKey: id)?.resume(throwing: NormaError.unavailable("Codex request timed out")) }
    private func send(_ value: JSONValue) throws {
        var data = try Codec.encode(value); data.append(10)
        guard let input else { throw NormaError.unavailable("Codex stdin closed") }
        try input.write(contentsOf: data)
    }
    private func receive(_ data: Data) {
        guard !data.isEmpty else { failed(); return }
        buffer.append(data)
        guard buffer.count <= 16 * 1024 * 1024 else { stop(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let message = try? Codec.decode(JSONValue.self, from: line) else { stop(); return }
            if let method = message["method"].string {
                if message["id"] != .null {
                    // A model never grants itself tool permissions. Unsupported approvals fail closed.
                    let result: JSONValue = method.contains("requestApproval") ? .object(["decision": .string("decline")]) : .null
                    try? send(.object(["id": message["id"], "result": result]))
                }
                for subscriber in subscribers.values { subscriber.yield(message) }
            } else if let id = message["id"].string, let waiter = pending.removeValue(forKey: id) {
                if message["error"] != .null { waiter.resume(throwing: NormaError.unavailable(message["error"]["message"].string ?? "Codex RPC error")) }
                else { waiter.resume(returning: message["result"]) }
            }
        }
    }
    private func failed() {
        let waiters = pending.values; pending.removeAll()
        for waiter in waiters { waiter.resume(throwing: NormaError.unavailable("Codex connection closed")) }
        for subscriber in subscribers.values { subscriber.finish() }; subscribers.removeAll()
    }
    public func stop() {
        process?.terminate(); input = nil; buffer.removeAll(); failed(); process = nil
    }
}
