import Foundation
import ResearchContracts

public struct ReferenceReceipt: Codable, Sendable {
    public var doi: String; public var title: String; public var sourceURL: String
    public var retrievedAt: Date; public var responseHash: String
    public var existence: CheckStatus
    public var claimSupport: CheckStatus
}
public protocol ReferenceFetching: Sendable { func fetch(_ url: URL) async throws -> Data }
public struct CrossrefTransport: ReferenceFetching {
    public init() {}
    public func fetch(_ url: URL) async throws -> Data {
        guard url.scheme == "https", url.host == "api.crossref.org" else { throw NormaError.forbidden("Unapproved reference endpoint") }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NORMA/0.1", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url?.host == "api.crossref.org" else { throw NormaError.unavailable("Reference lookup failed") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_000_000 else { throw NormaError.invalid("Reference response exceeds limit") }
            data.append(byte)
        }
        return data
    }
}
public struct ReferenceVerifier: Sendable {
    private let transport: any ReferenceFetching
    public init(transport: any ReferenceFetching = CrossrefTransport()) { self.transport = transport }
    public func verify(doi: String, expectedTitle: String) async throws -> ReferenceReceipt {
        guard doi.hasPrefix("10."), doi.contains("/"), doi.count <= 512,
              !doi.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw NormaError.invalid("Invalid DOI") }
        let url = URL(string: "https://api.crossref.org/works/")!.appendingPathComponent(doi)
        let data = try await transport.fetch(url)
        let response = try Codec.decode(JSONValue.self, from: data)
        let message = response["message"]
        guard let returnedDOI = message["DOI"].string, let title = message["title"].array.first?.string else { throw NormaError.invalid("Incomplete reference metadata") }
        func normalized(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let exists = returnedDOI.lowercased() == doi.lowercased() && normalized(title) == normalized(expectedTitle)
        // Metadata existence never proves that a source supports a manuscript claim.
        return ReferenceReceipt(doi: returnedDOI, title: title, sourceURL: url.absoluteString,
            retrievedAt: Date(), responseHash: Codec.hash(data), existence: exists ? .pass : .fail, claimSupport: .unknown)
    }
}
