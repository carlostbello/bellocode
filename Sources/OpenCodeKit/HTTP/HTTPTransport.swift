import Foundation

/// The request/response seam under `OpenCodeClient`. The default is `URLSessionTransport`; tests inject fakes.
/// Streaming (`/api/event`) does not go through this protocol; see `EventStreamConnector`.
public protocol HTTPTransport: Sendable {
    /// Performs a request and returns the whole body. Must honour task cancellation.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession`-backed transport with an ephemeral configuration: no cookies, no cache, no credential storage.
public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = URLSessionTransport.makeSession()) {
        self.session = session
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenCodeError.invalidResponse }
        return (data, http)
    }
}
