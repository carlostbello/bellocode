import Foundation

// MARK: - Persistent PTYs (experimental.persistentPty.*)

extension OpenCodeClient {
    /// `POST /api/experimental/session/{id}/terminal` (experimental.persistentPty.create). The PTY belongs to the
    /// session, so the agent can read it (`readTerminal`).
    public func createTerminal(sessionID: String, _ body: PTYCreateRequest) async throws -> PTYInfo {
        let request = try makeRequest(.post, ["api", "experimental", "session", sessionID, "terminal"], body: body)
        return try await send("experimental.persistentPty.create", request, as: DataEnvelope<PTYInfo>.self).data
    }

    /// `GET /api/experimental/session/{id}/terminal` (experimental.persistentPty.list). Exited PTYs are not listed.
    public func terminals(sessionID: String) async throws -> [PTYInfo] {
        let request = try makeRequest(.get, ["api", "experimental", "session", sessionID, "terminal"])
        return try await send("experimental.persistentPty.list", request, as: DataEnvelope<[PTYInfo]>.self).data
    }

    /// `GET /api/experimental/persistent-pty/{id}` (experimental.persistentPty.get). 404 `PtyNotFoundError` once the
    /// PTY exited or was removed.
    public func terminal(_ ptyID: String) async throws -> PTYInfo {
        let request = try makeRequest(.get, ["api", "experimental", "persistent-pty", ptyID])
        return try await send("experimental.persistentPty.get", request, as: DataEnvelope<PTYInfo>.self).data
    }

    /// `PUT /api/experimental/persistent-pty/{id}` (experimental.persistentPty.update): resize and/or retitle.
    @discardableResult
    public func updateTerminal(_ ptyID: String, _ body: PTYUpdateRequest) async throws -> PTYInfo {
        let request = try makeRequest(.put, ["api", "experimental", "persistent-pty", ptyID], body: body)
        return try await send("experimental.persistentPty.update", request, as: DataEnvelope<PTYInfo>.self).data
    }

    /// `DELETE /api/experimental/persistent-pty/{id}` (experimental.persistentPty.remove): kills the process.
    public func deleteTerminal(_ ptyID: String) async throws {
        try await sendIgnoringBody(
            "experimental.persistentPty.remove", makeRequest(.delete, ["api", "experimental", "persistent-pty", ptyID]))
    }

    /// `GET /api/experimental/persistent-pty/{id}/snapshot` (experimental.persistentPty.snapshot).
    public func terminalSnapshot(_ ptyID: String) async throws -> PTYSnapshot {
        let request = try makeRequest(.get, ["api", "experimental", "persistent-pty", ptyID, "snapshot"])
        return try await send("experimental.persistentPty.snapshot", request, as: DataEnvelope<PTYSnapshot>.self).data
    }

    /// `GET /api/experimental/session/{id}/terminal/read` (experimental.persistentPty.read): the session's current
    /// terminal as the agent sees it; `lines` is the number of bottom screen rows. nil when the session has none.
    public func readTerminal(sessionID: String, lines: Int? = nil) async throws -> PTYReadResult? {
        let query = lines.map { [("lines", String($0))] } ?? []
        let request = try makeRequest(.get, ["api", "experimental", "session", sessionID, "terminal", "read"], query: query)
        return try await send("experimental.persistentPty.read", request, as: DataEnvelope<PTYReadResult?>.self).data
    }

    /// The WebSocket request for `GET /api/experimental/persistent-pty/{id}/connect` (experimental.persistentPty.connect)
    /// with input protocol 1 (binary input frames) and Basic auth. `cursor` is a byte offset: the server replays from
    /// `max(cursor, head)`.
    public func terminalConnectRequest(
        _ ptyID: String, cursor: Int, attachmentID: String, role: PTYRole = .controller, takeover: Bool = false
    ) throws -> URLRequest {
        var request = try makeRequest(
            .get, ["api", "experimental", "persistent-pty", ptyID, "connect"],
            query: [
                ("cursor", String(max(0, cursor))), ("attachment_id", attachmentID), ("role", role.rawValue),
                ("takeover", takeover ? "true" : "false"), ("input_protocol", "1"),
            ])
        if var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) {
            components.scheme = components.scheme == "https" ? "wss" : "ws"
            request.url = components.url
        }
        request.timeoutInterval = 30
        return request
    }
}
