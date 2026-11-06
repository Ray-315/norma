import Foundation

public struct ArchiveFile: Codable, Sendable {
    public var path: String
    public var hash: String
    public var bytes: Int
    public init(path: String, hash: String, bytes: Int) { self.path = path; self.hash = hash; self.bytes = bytes }
}
public struct ArchiveManifest: Codable, Sendable {
    public var version = 1
    public var createdAt = Date()
    public var kind: String
    public var files: [ArchiveFile]
    public init(kind: String, files: [ArchiveFile]) { self.kind = kind; self.files = files }
}
