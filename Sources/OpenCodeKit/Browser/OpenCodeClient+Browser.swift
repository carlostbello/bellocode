import Foundation

/// Why a plugin RPC call failed. Never carries request content.
public enum BrowserRPCError: Error, Sendable, Equatable, CustomStringConvertible {
    /// `RpcError` (HTTP 400) from the plugin: `type` is `unavailable` for every refusal the browser plugin makes
    /// (attachment gone, request no longer pending, session not found or in another location, permissions not granted).
    case rpc(type: String, message: String)
    /// The request was rejected before the plugin ran: `InvalidRequestError` (input does not match the plugin's schema,
    /// which is how a contract version mismatch shows), `LocationNotFoundError`, or an `RpcInternalError`.
    case rejected(status: Int, tag: String, message: String)
    /// No answer: connection refused or lost (server restarting).
    case transport(String)
    case cancelled

    public var isUnavailable: Bool {
        if case .rpc(let type, _) = self { type == "unavailable" } else { false }
    }

    public var description: String {
        switch self {
        case .rpc(let type, _): "rpc error \(type)"
        case .rejected(let status, let tag, _): "rejected \(status) \(tag)"
        case .transport(let reason): "transport: \(reason)"
        case .cancelled: "cancelled"
        }
    }
}

/// A transport for plugin RPC: its own URLSession, so long-lived `attach` calls (one per attached thread) never take
/// connections from the shared pool the rest of the app uses, and no idle timeout ends them.
public struct BrowserRPCTransport: HTTPTransport {
    public let session: URLSession

    public static let shared = BrowserRPCTransport()

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpMaximumConnectionsPerHost = 32
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenCodeError.invalidResponse }
        return (data, http)
    }
}

// MARK: - Plugin RPC (rpc.call)

extension OpenCodeClient {
    /// `POST /api/rpc/{rpcID}/{method}?location[directory]=…` with `{input}`; returns `output` (null for void methods).
    ///
    /// - Parameter longLived: for `attach`, which stays pending for the attachment's lifetime: no idle timeout.
    public func pluginRPC(
        _ rpcID: String, _ method: String, input: JSONValue, directory: String, longLived: Bool = false
    ) async throws(BrowserRPCError) -> JSONValue {
        let operation = "rpc.\(rpcID).\(method)"
        let request: URLRequest
        do {
            request = try makeRequest(
                .post, ["api", "rpc", rpcID, method], directory: directory, body: ["input": input] as JSONValue,
                timeout: longLived ? .seconds(24 * 3600) : nil)
        } catch {
            throw .rejected(status: 0, tag: "EncodingError", message: "could not encode the request")
        }
        let signpost = Instrumentation.http.beginInterval("rpc", "\(operation, privacy: .public)")
        defer { Instrumentation.http.endInterval("rpc", signpost) }
        let carrier: any HTTPTransport = transport is URLSessionTransport ? BrowserRPCTransport.shared : transport
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await carrier.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw .cancelled }
            throw .transport("network error \(error.code.rawValue)")
        } catch is CancellationError {
            throw .cancelled
        } catch {
            if Task.isCancelled { throw .cancelled }
            throw .transport("\(type(of: error))")
        }
        if Task.isCancelled { throw .cancelled }
        let body = data.isEmpty ? JSONValue.null : ((try? JSONValue.parse(data)) ?? .null)
        guard (200..<300).contains(response.statusCode) else {
            let tag = body["_tag"]?.stringValue ?? "HTTP\(response.statusCode)"
            let message = body["message"]?.stringValue ?? ""
            if tag == "RpcError" { throw .rpc(type: body["type"]?.stringValue ?? "unknown", message: message) }
            throw .rejected(status: response.statusCode, tag: tag, message: message)
        }
        return body["output"] ?? .null
    }

    /// One `experimental.browser` method.
    public func browserRPC(
        _ method: String, _ input: JSONValue, directory: String, longLived: Bool = false
    ) async throws(BrowserRPCError) -> JSONValue {
        try await pluginRPC(BrowserContract.rpcID, method, input: input, directory: directory, longLived: longLived)
    }
}

// MARK: - Session instruction entries (experimental.session.instructions.entry.*)

/// `InstructionEntry.Info`: durable context attached to a session. The server renders each entry into the agent's
/// instructions as `<context key="…">value</context>` and announces changes at the next step boundary.
public struct InstructionEntry: Sendable, Equatable, Decodable {
    public var key: String
    public var value: JSONValue
}

extension OpenCodeClient {
    /// `GET /api/experimental/session/{id}/instructions/entries`.
    public func instructionEntries(sessionID: String) async throws -> [InstructionEntry] {
        let request = try makeRequest(.get, ["api", "experimental", "session", sessionID, "instructions", "entries"])
        return try await send("experimental.session.instructions.entry.list", request, as: DataEnvelope<[InstructionEntry]>.self).data
    }

    /// `PUT /api/experimental/session/{id}/instructions/entries/{key}` with `{value}`. Keys match `^[a-z0-9][a-z0-9._-]*$`.
    public func putInstructionEntry(sessionID: String, key: String, value: JSONValue) async throws {
        let request = try makeRequest(
            .put, ["api", "experimental", "session", sessionID, "instructions", "entries", key], body: ["value": value] as JSONValue)
        try await sendIgnoringBody("experimental.session.instructions.entry.put", request)
    }

    /// `DELETE /api/experimental/session/{id}/instructions/entries/{key}`.
    public func deleteInstructionEntry(sessionID: String, key: String) async throws {
        let request = try makeRequest(.delete, ["api", "experimental", "session", sessionID, "instructions", "entries", key])
        try await sendIgnoringBody("experimental.session.instructions.entry.remove", request)
    }
}
