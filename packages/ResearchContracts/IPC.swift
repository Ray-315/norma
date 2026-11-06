import Foundation
public enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .null: try c.encodeNil(); case .bool(let v): try c.encode(v); case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v); case .array(let v): try c.encode(v); case .object(let v): try c.encode(v) }
    }
    public subscript(_ key: String) -> JSONValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    public var bool: Bool { if case .bool(let v) = self { return v }; return false }
}
public struct IPCRequest: Codable, Sendable {
    public var version = 1; public var id = UUID(); public var method: String; public var payload: Data
    public init<T: Encodable>(method: String, value: T) throws { self.method = method; payload = try Codec.encode(value) }
}
public struct IPCResponse: Codable, Sendable {
    public var version = 1; public var id: UUID; public var payload: Data?; public var error: NormaError?
    public init(id: UUID, payload: Data? = nil, error: NormaError? = nil) { self.id = id; self.payload = payload; self.error = error }
}
public struct ResearchCommand: Codable, Sendable {
    public var id: UUID; public var revision: Int
    public init(id: UUID, revision: Int) { self.id = id; self.revision = revision }
}
public struct AuthorizeCommand: Codable, Sendable {
    public var revision: Int; public var authorization: ResearchAuthorization
    public init(revision: Int, authorization: ResearchAuthorization) { self.revision = revision; self.authorization = authorization }
}
public struct Empty: Codable, Sendable { public init() {} }
public struct ReviseCommand: Codable, Sendable {
    public var contract: ResearchContract; public var revision: Int
    public init(contract: ResearchContract, revision: Int) { self.contract = contract; self.revision = revision }
}
@objc public protocol ResearchXPCProtocol {
    func request(_ data: Data, reply: @escaping (Data) -> Void)
}
