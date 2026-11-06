import Foundation
import ResearchContracts

public struct DiscoveredEnvironment: Codable, Sendable, Identifiable {
    public var id: String; public var kind: String; public var name: String; public var executable: String
    public var status: CheckStatus; public var detail: String
}
public actor EnvironmentCatalog {
    public init() {}
    /// Only explicitly supplied roots are examined. No recursive home-directory scan.
    public func discover(roots: [URL]) async -> [DiscoveredEnvironment] {
        var found: [DiscoveredEnvironment] = []
        for path in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] where FileManager.default.isExecutableFile(atPath: path) {
            found.append(await inspectPython(path, kind: "system"))
        }
        for supplied in roots {
            let root = supplied.resolvingSymlinksInPath()
            for relative in [".venv/bin/python", "venv/bin/python", "bin/python"] {
                let executable = root.appendingPathComponent(relative).resolvingSymlinksInPath()
                // Interpreter symlinks may point to a trusted installation; project files never execute.
                guard FileManager.default.isExecutableFile(atPath: executable.path),
                      root.appendingPathComponent(relative).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("pyvenv.cfg").path.hasPrefix(root.path + "/") else { continue }
                found.append(await inspectPython(executable.path, kind: "venv"))
            }
        }
        for prefix in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let conda = prefix + "/conda"
            if FileManager.default.isExecutableFile(atPath: conda) {
                do {
                    let result = try await BoundedProcess.run(conda, arguments: ["env", "list", "--json"], timeout: 10)
                    let value = try Codec.decode(JSONValue.self, from: result.data)
                    for environment in value["envs"].array {
                        guard let path = environment.string else { continue }
                        let executable = URL(fileURLWithPath: path).appendingPathComponent("bin/python").path
                        found.append(await inspectPython(executable, kind: "conda"))
                    }
                } catch {
                    found.append(DiscoveredEnvironment(id: conda, kind: "conda", name: "Conda", executable: conda, status: .unknown, detail: "Discovery unavailable"))
                }
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }
    }
    private func inspectPython(_ executable: String, kind: String) async -> DiscoveredEnvironment {
        do {
            let output = try await BoundedProcess.run(executable, arguments: ["-I", "-S", "-c", "import sys,platform,json; print(json.dumps({'version':platform.python_version(),'architecture':platform.machine(),'platform':platform.system()}))"], timeout: 5)
            guard output.code == 0 else { throw NormaError.unavailable("Python probe failed") }
            let value = try Codec.decode(JSONValue.self, from: output.data)
            let detail = [value["version"].string, value["architecture"].string, value["platform"].string].compactMap { $0 }.joined(separator: " · ")
            return DiscoveredEnvironment(id: executable, kind: kind, name: URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                executable: executable, status: .pass, detail: detail)
        } catch { return DiscoveredEnvironment(id: executable, kind: kind, name: kind, executable: executable, status: .unknown, detail: "Interpreter unavailable") }
    }
}

public enum SSHCommand {
    public static func arguments(node: ComputeNode, workerPath: String) throws -> [String] {
        guard node.kind != .local, let host = node.host, let user = node.user, let port = node.port,
              (1...65535).contains(port), !host.isEmpty, !host.hasPrefix("-"),
              host.allSatisfy({ $0.isLetter || $0.isNumber || ".:-".contains($0) }),
              !user.isEmpty, user.allSatisfy({ $0.isLetter || $0.isNumber || "_-".contains($0) }),
              node.workDirectory.hasPrefix("/"), node.python.hasPrefix("/"), workerPath.hasPrefix(node.workDirectory + "/"),
              node.hostFingerprint != nil else { throw NormaError.forbidden("Incomplete or unsafe SSH target configuration") }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "-p", String(port),
                "--", user + "@" + host, "exec " + quote(node.python) + " -I " + quote(workerPath)]
    }
    public static func disconnectedStatus() -> OperationState { .unknown }
}
