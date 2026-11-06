import Foundation
import CryptoKit
import ResearchContracts

public struct ProcessOutput: Sendable { public var code: Int32; public var data: Data }
public enum BoundedProcess {
    public static func run(_ executable: String, arguments: [String], input: Data? = nil, timeout: TimeInterval = 30) async throws -> ProcessOutput {
        let task = Task.detached {
            let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
            let stdin = Pipe(), stdout = Pipe()
            p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
            p.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "LANG": "en_US.UTF-8"]
            let collector = OutputCollector()
            try p.run()
            try stdout.fileHandleForWriting.close()
            let reading = DispatchGroup(); reading.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { reading.leave() }
                while let bytes = try? stdout.fileHandleForReading.read(upToCount: 8192), !bytes.isEmpty { collector.append(bytes) }
            }
            if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
            try stdin.fileHandleForWriting.close()
            let end = Date().addingTimeInterval(timeout)
            while p.isRunning {
                if Task.isCancelled || Date() > end {
                    p.terminate()
                    for _ in 0..<20 where p.isRunning { usleep(50_000) }
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                    p.waitUntilExit(); throw NormaError.cancelled
                }
                usleep(20_000)
            }
            p.waitUntilExit()
            guard waitForOutput(reading) else { throw NormaError.unavailable("Process output stream did not close") }
            guard !collector.overflowed else { throw NormaError.invalid("Process output limit exceeded") }
            return ProcessOutput(code: p.terminationStatus, data: collector.data)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static func waitForOutput(_ group: DispatchGroup) -> Bool { group.wait(timeout: .now() + 2) == .success }
}
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock(); private var bytes = Data(); private var overflow = false
    func append(_ value: Data) { lock.lock(); defer { lock.unlock() }; if bytes.count + value.count > 4 * 1024 * 1024 { overflow = true } else { bytes.append(value) } }
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
}
public actor LocalCompute {
    public let root: URL; public let worker: URL
    public init(root: URL, worker: URL) throws {
        self.root = root; self.worker = worker
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keyURL = root.appendingPathComponent(".worker-key")
        if !FileManager.default.fileExists(atPath: keyURL.path) {
            var key = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, key.count, &key) == errSecSuccess else { throw NormaError.unavailable("Secure random unavailable") }
            try Data(key).write(to: keyURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        }
    }
    public func node() -> ComputeNode { ComputeNode(id: "local", name: Host.current().localizedName ?? "Mac", kind: .local, workDirectory: root.path, python: "/usr/bin/python3") }
    public func discover() async throws -> EnvironmentSnapshot {
        let output = try await BoundedProcess.run("/usr/bin/python3", arguments: ["-I", "-B", worker.path], input: Codec.encode(JSONValue.object(["operation": .string("health")])))
        guard output.code == 0 else { throw NormaError.unavailable("Python environment probe failed") }
        let result = try Codec.decode(JSONValue.self, from: output.data)
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        guard let python = result["python"].string, let packages = result["packagesFingerprint"].string else { throw NormaError.invalid("Incomplete environment snapshot") }
        let binaryHash = Codec.hash(try Data(contentsOf: URL(fileURLWithPath: python).resolvingSymlinksInPath()))
        let snapshot = EnvironmentSnapshot(nodeID: "local", python: result["python"].string ?? "/usr/bin/python3",
            version: result["pythonVersion"].string ?? "", architecture: result["architecture"].string ?? "",
            platform: result["platform"].string ?? "", freeBytes: (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0,
            dependencyFingerprint: Codec.hash(Data((binaryHash + packages).utf8)))
        guard snapshot.fingerprint == result["fingerprint"].string else { throw NormaError.invalid("Environment fingerprint disagreement") }
        return snapshot
    }
    public func workerHash() throws -> String { Codec.hash(try Data(contentsOf: worker)) }
    public func fit(runID: UUID, environment: EnvironmentSnapshot, independent: Bool, expiresAt: Date) async throws -> JSONValue {
        let manifest: JSONValue = .object([
            "runID": .string(runID.uuidString), "targetID": .string("local"), "expiresAt": .number(expiresAt.timeIntervalSince1970 * 1000),
            "runtimeSeconds": .number(30), "workerHash": .string(try workerHash()),
            "environmentFingerprint": .string(environment.fingerprint), "batch": .number(1), "seed": .number(0), "steps": .number(0),
            "independent": .bool(independent), "points": .array((0..<5).map { .array([.number(Double($0)), .number(Double(2 * $0 + 1))]) })
        ])
        let data = try Codec.encode(manifest)
        let key = SymmetricKey(data: try Data(contentsOf: root.appendingPathComponent(".worker-key")))
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: key).map { String(format: "%02x", $0) }.joined()
        let request: JSONValue = .object(["operation": .string("submit"), "root": .string(root.path), "manifest": .string(data.base64EncodedString()), "signature": .string(signature)])
        let directory = root.appendingPathComponent("manifests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let receipt = directory.appendingPathComponent(runID.uuidString + ".json")
        guard !FileManager.default.fileExists(atPath: receipt.path) else { throw NormaError.forbidden("Run already admitted; reconcile instead of resubmitting") }
        try Codec.encode(request).write(to: receipt, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        return try await send(request)
    }
    public func recover(_ runID: UUID) async throws -> JSONValue {
        let path = root.appendingPathComponent("manifests/" + runID.uuidString + ".json")
        guard case .object(var request) = try Codec.decode(JSONValue.self, from: Data(contentsOf: path)),
              request["root"]?.string == root.path else { throw NormaError.invalid("Missing persisted worker manifest") }
        request["operation"] = .string("fetch")
        return try await send(.object(request))
    }
    private func send(_ request: JSONValue) async throws -> JSONValue {
        let output = try await BoundedProcess.run("/usr/bin/python3", arguments: ["-I", worker.path], input: Codec.encode(request), timeout: 30)
        let value = try Codec.decode(JSONValue.self, from: output.data)
        guard output.code == 0 else { throw NormaError.unavailable(value["error"].string ?? "Worker failed") }
        return value
    }
}
import Security
