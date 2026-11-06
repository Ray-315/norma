import Foundation
import Security
import ResearchContracts
import CodexBridge

public actor Accounts {
    public let root: URL
    private var bridges: [String: JSONLTransport] = [:]
    private var starting: [String: Task<JSONLTransport, Error>] = [:]
    public init(root: URL) { self.root = root }
    public static func codexExecutable() throws -> String {
        let paths = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let path = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else { throw NormaError.unavailable("Codex CLI not found") }
        return path
    }
    public func bridge(_ profile: String) async throws -> JSONLTransport {
        guard ["chatgpt", "api"].contains(profile) else { throw NormaError.invalid("Unknown account profile") }
        if let bridge = bridges[profile], await bridge.isRunning { return bridge }
        bridges.removeValue(forKey: profile)
        if let startup = starting[profile] { return try await startup.value }
        let home = root.appendingPathComponent("codex-profiles").appendingPathComponent(profile)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let startup = Task<JSONLTransport, Error> {
            let bridge = JSONLTransport()
            let file = home.appendingPathComponent("auth.json")
            if FileManager.default.fileExists(atPath: file.path) {
                // Codex owns the migration: auto loads its legacy file and a proactive
                // refresh persists the refreshed credential through its native keyring.
                try await bridge.start(executable: Self.codexExecutable(), home: home, credentialsMode: "auto")
                _ = try await bridge.request("account/read", params: .object(["refreshToken": .bool(true)]))
                await bridge.stop()
                guard !FileManager.default.fileExists(atPath: file.path) else {
                    throw NormaError.unavailable("Codex credential migration to Keychain requires attention; legacy login remains preserved")
                }
            }
            let secured = JSONLTransport()
            try await secured.start(executable: Self.codexExecutable(), home: home, credentialsMode: "keyring")
            return secured
        }
        starting[profile] = startup
        do {
            let bridge = try await startup.value; bridges[profile] = bridge; starting.removeValue(forKey: profile); return bridge
        } catch { starting.removeValue(forKey: profile); throw error }
    }
    public func status(_ profile: String = "chatgpt") async throws -> AccountStatus {
        let result = try await bridge(profile).request("account/read", params: .object(["refreshToken": .bool(false)]))
        let type = result["account"]["type"].string
        return AccountStatus(profile: profile, authenticated: result["account"] != .null, authType: type)
    }
    public func loginURL() async throws -> String {
        let result = try await bridge("chatgpt").request("account/login/start", params: .object(["type": .string("chatgpt")]))
        guard let url = result["authUrl"].string else { throw NormaError.unavailable("Login URL not returned") }
        return url
    }
    public func loginAPI(key: String) async throws {
        guard !key.isEmpty else { throw NormaError.invalid("Empty API key") }
        _ = try await bridge("api").request("account/login/start", params: .object(["type": .string("apiKey"), "apiKey": .string(key)]))
    }
    public func models(_ profile: String = "chatgpt") async throws -> [ModelDescriptor] {
        let bridge = try await bridge(profile)
        var cursor: JSONValue = .null, result: [ModelDescriptor] = []
        repeat {
            let response = try await bridge.request("model/list", params: .object(["cursor": cursor, "limit": .number(100)]))
            result += response["data"].array.compactMap { value in
                guard let id = value["id"].string else { return nil }
                return ModelDescriptor(id: id, name: value["displayName"].string ?? id,
                    reasoning: value["supportedReasoningEfforts"].array.compactMap { $0["reasoningEffort"].string })
            }
            cursor = response["nextCursor"]
        } while cursor != .null
        return result
    }
}
public enum Keychain {
    public static func save(_ value: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.norma.credentials", kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query; insert[kSecValueData as String] = value
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw NormaError.unavailable("Keychain save failed") }
        } else if status != errSecSuccess { throw NormaError.unavailable("Keychain update failed") }
    }
}
