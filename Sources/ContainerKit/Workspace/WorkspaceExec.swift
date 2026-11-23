import Foundation

/// Where an exec into a workspace container goes and who it runs as: the container's ID (as inspected, so a container
/// re-created under the same name in between is not the one exec'd into) and its verified numeric `uid:gid`.
public struct WorkspaceExecTarget: Sendable, Equatable {
    public var containerID: String
    /// `uid:gid`, nonzero uid, numbers only.
    public var user: String

    public init(containerID: String, user: String) {
        self.containerID = containerID
        self.user = user
    }
}

/// Every command BelloCode runs in a workspace container (the helper's commands, terminals and relayed MCP servers,
/// probes, network diagnostics, port relays) goes through these, never through `ExecSession` with a user of its own.
///
/// AF10 follow-up: the workspace is created with the verified numeric `uid:gid`, but an exec given the configured
/// *name* (`node`) is resolved by Docker from the container's own `/etc/passwd` at each exec. A workspace user who can
/// rewrite that file (an image that leaves it writable) could map the name to uid 0 and every later command would run
/// as root. An exec therefore runs as the numbers the container was created with (its `Config.User`), and a container
/// whose configured user is not a nonzero numeric `uid:gid` gets no exec at all (fail closed).
extension WorkspaceManager {
    /// The container's ID and its verified `uid:gid`. Throws `ContainerError.notFound` when it does not exist and
    /// `WorkspaceError.unverifiedUser` when its configured user is not a nonzero numeric `uid:gid`.
    public func execTarget(container: String) async throws -> WorkspaceExecTarget {
        guard let inspect = try await client.inspectContainer(container) else { throw ContainerError.notFound(container) }
        guard let user = WorkspaceUser.verifiedExecUser(inspect.config.user) else {
            throw WorkspaceError.unverifiedUser(container: container, user: inspect.config.user ?? "")
        }
        return WorkspaceExecTarget(containerID: inspect.id, user: user)
    }

    /// Starts a process in the workspace container as its verified user (see `ExecSession.start`).
    public func start(container: String, argv: [String], workingDir: String?, environment: [String: String], tty: Bool,
                      size: (rows: Int, cols: Int)? = nil) async throws -> (session: ExecSession, target: WorkspaceExecTarget) {
        let target = try await execTarget(container: container)
        let session = try await start(target, argv: argv, workingDir: workingDir, environment: environment, tty: tty, size: size)
        return (session, target)
    }

    /// Starts a process in a container already resolved by `execTarget` (later execs of the same command, such as its
    /// kill, go to the same container as the same user).
    public func start(_ target: WorkspaceExecTarget, argv: [String], workingDir: String?, environment: [String: String], tty: Bool,
                      size: (rows: Int, cols: Int)? = nil) async throws -> ExecSession {
        try await ExecSession.start(client: client, container: target.containerID, argv: argv, workingDir: workingDir,
                                    environment: environment, user: target.user, tty: tty, size: size)
    }

    /// Runs a non-interactive command in the workspace container as its verified user (see `ExecSession.run`).
    public func run(container: String, argv: [String], workingDir: String? = nil, environment: [String: String] = [:], wrap: Bool = true,
                    limit: Int = 1 << 20, timeout: Duration = .seconds(120)) async throws -> ExecResult {
        try await run(try await execTarget(container: container), argv: argv, workingDir: workingDir, environment: environment, wrap: wrap,
                      limit: limit, timeout: timeout)
    }

    /// Runs a non-interactive command in a container already resolved by `execTarget`.
    public func run(_ target: WorkspaceExecTarget, argv: [String], workingDir: String? = nil, environment: [String: String] = [:],
                    wrap: Bool = true, limit: Int = 1 << 20, timeout: Duration = .seconds(120)) async throws -> ExecResult {
        try await ExecSession.run(client: client, container: target.containerID, argv: argv, workingDir: workingDir, environment: environment,
                                  user: target.user, wrap: wrap, limit: limit, timeout: timeout)
    }
}
