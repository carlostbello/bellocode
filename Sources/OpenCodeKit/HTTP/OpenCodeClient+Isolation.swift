import Foundation

// The calls BelloCode's isolation self-check needs (docs/features/containers.md), checked against
// Contracts/opencode-2.3.0/openapi.json: shell jobs (`/api/shell`), experimental schedules, configuration entries.

/// `Shell.Info` (a shell job): only the fields the self-check reads.
public struct ShellJob: Decodable, Sendable, Hashable {
    public var id: String
    public var status: String
    public var shell: String
    public var cwd: String
    public var exit: Double?
    public var isFinished: Bool { status != "running" }
}

public struct ShellJobOutput: Decodable, Sendable, Hashable {
    public var output: String
    public var cursor: Int
    public var truncated: Bool
}

/// `Schedule.Info`: only the fields the self-check reads.
public struct ScheduleInfo: Decodable, Sendable, Hashable {
    public var id: String
    public var status: String
    public var runCount: Int
    public var lastOutcome: String?
    public var lastOutput: String?
}

private struct Located<T: Decodable & Sendable>: Decodable, Sendable { var data: T }

extension OpenCodeClient {
    /// `POST /api/shell` (shell.create): starts a shell job in `cwd` with opencode's configured shell.
    public func createShellJob(command: String, cwd: String, timeout: Int? = nil) async throws -> ShellJob {
        struct Body: Encodable, Sendable { var command: String; var cwd: String; var timeout: Int? }
        let request = try makeRequest(.post, ["api", "shell"], directory: cwd, body: Body(command: command, cwd: cwd, timeout: timeout))
        return try await send("shell.create", request, as: Located<ShellJob>.self).data
    }

    /// `GET /api/shell/{id}` (shell.get).
    public func shellJob(_ id: String, directory: String) async throws -> ShellJob {
        let request = try makeRequest(.get, ["api", "shell", id], directory: directory)
        return try await send("shell.get", request, as: Located<ShellJob>.self).data
    }

    /// `GET /api/shell/{id}/output` (shell.output).
    /// `DELETE /api/shell/{id}` (shell.remove): stops a running job.
    public func deleteShellJob(_ id: String, directory: String) async throws {
        let request = try makeRequest(.delete, ["api", "shell", id], directory: directory)
        try await sendIgnoringBody("shell.remove", request)
    }

    public func shellJobOutput(_ id: String, directory: String) async throws -> ShellJobOutput {
        let request = try makeRequest(.get, ["api", "shell", id, "output"], directory: directory)
        return try await send("shell.output", request, as: Located<ShellJobOutput>.self).data
    }

    /// `DELETE /api/shell/{id}` (shell.remove): stops a running job.
    public func removeShellJob(_ id: String, directory: String) async throws {
        let request = try makeRequest(.delete, ["api", "shell", id], directory: directory)
        try await sendIgnoringBody("shell.remove", request)
    }

    /// `POST /api/experimental/schedule` with a shell condition that never wakes (`is` never matches), so the
    /// condition runs once when due and no prompt is ever sent.
    public func createProbeSchedule(sessionID: String, directory: String, run: String, after seconds: Int) async throws -> ScheduleInfo {
        let body: JSONValue = .object([
            "sessionID": .string(sessionID),
            "name": .string("BelloCode isolation check"),
            "when": .object(["in": .string("\(seconds) seconds")]),
            "if": .object(["run": .string(run), "is": .string("bellocode-never-matches")]),
            "ends": .object(["times": .number(1)]),
            "prompt": .string("BelloCode isolation check (never sent)"),
        ])
        let request = try makeRequest(.post, ["api", "experimental", "schedule"], directory: directory, body: body)
        return try await send("experimental.schedule.create", request, as: Located<ScheduleInfo>.self).data
    }

    public func schedule(_ id: String, directory: String) async throws -> ScheduleInfo {
        let request = try makeRequest(.get, ["api", "experimental", "schedule", id], directory: directory)
        return try await send("experimental.schedule.get", request, as: Located<ScheduleInfo>.self).data
    }

    public func deleteSchedule(_ id: String, directory: String) async throws {
        let request = try makeRequest(.delete, ["api", "experimental", "schedule", id], directory: directory)
        try await sendIgnoringBody("experimental.schedule.delete", request)
    }

    /// `GET /api/config` (config.get): the configuration entries as loaded (documents and directories), raw.
    public func configEntries(directory: String?) async throws -> [JSONValue] {
        let request = try makeRequest(.get, ["api", "config"], directory: directory)
        return try await send("config.get", request, as: [JSONValue].self)
    }
}

extension OpenCodeClient {
    /// `POST /api/pty` (pty.create, the older sessionless PTY API): with no `command`, opencode starts `$SHELL`.
    /// Returns the PTY's ID.
    public func createLegacyPTY(directory: String, command: String? = nil, args: [String], title: String) async throws -> String {
        struct Body: Encodable, Sendable { var command: String?; var args: [String]; var cwd: String; var title: String }
        struct PTY: Decodable, Sendable { var id: String }
        let request = try makeRequest(.post, ["api", "pty"], directory: directory,
                                      body: Body(command: command, args: args, cwd: directory, title: title))
        return try await send("pty.create", request, as: Located<PTY>.self).data.id
    }

    /// `DELETE /api/pty/{id}` (pty.remove).
    public func deleteLegacyPTY(_ id: String, directory: String) async throws {
        let request = try makeRequest(.delete, ["api", "pty", id], directory: directory)
        try await sendIgnoringBody("pty.remove", request)
    }
}

/// One MCP server of a location and its connection status (`GET /api/mcp`).
public struct MCPServerStatus: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    /// `connected`, `pending`, `disabled`, `failed` or `needs_auth`.
    public var status: String
    public var error: String?
    public var id: String { name }

    enum CodingKeys: String, CodingKey { case name, status }
    struct Status: Decodable { var status: String; var error: String? }

    public init(name: String, status: String, error: String? = nil) {
        self.name = name
        self.status = status
        self.error = error
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        let status = try c.decode(Status.self, forKey: .status)
        self.status = status.status
        error = status.error
    }
}

extension OpenCodeClient {
    /// `GET /api/mcp` (mcp.list): the location's MCP servers and their status.
    public func mcpServers(directory: String) async throws -> [MCPServerStatus] {
        let request = try makeRequest(.get, ["api", "mcp"], directory: directory)
        return try await send("mcp.list", request, as: LocatedList<MCPServerStatus>.self).data
    }

    /// `PUT /api/experimental/mcp/{server}` (experimental.mcp.add): adds or replaces a server for this location only and
    /// connects it. Container execution passes only routed commands (`MCPRouting.projectServerConfig`).
    public func addMCPServer(_ name: String, config: JSONValue, directory: String) async throws {
        struct Body: Encodable, Sendable { var config: JSONValue }
        let request = try makeRequest(.put, ["api", "experimental", "mcp", name], directory: directory, body: Body(config: config),
                                      timeout: .seconds(60))
        try await sendIgnoringBody("experimental.mcp.add", request)
    }

    /// `DELETE /api/experimental/mcp/{server}` (experimental.mcp.remove).
    public func removeMCPServer(_ name: String, directory: String) async throws {
        let request = try makeRequest(.delete, ["api", "experimental", "mcp", name], directory: directory)
        try await sendIgnoringBody("experimental.mcp.remove", request)
    }
}
