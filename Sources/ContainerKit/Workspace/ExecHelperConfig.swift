import Foundation

/// What `bellocode-exec` reads at start (path in `BELLOCODE_EXEC_CONFIG`). Written by the app; holds no secrets.
public struct ExecHelperConfig: Codable, Sendable, Equatable {
    public struct Workspace: Codable, Sendable, Equatable {
        /// Host paths visible in the container at the same path (project root first).
        public var roots: [String]
        public var container: String
        public var user: String?
        /// Shell inside the container, e.g. `/bin/bash`.
        public var shell: String

        public init(roots: [String], container: String, user: String? = nil, shell: String = "/bin/sh") {
            self.roots = roots
            self.container = container
            self.user = user
            self.shell = shell
        }

        public func contains(_ path: String) -> Bool {
            roots.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
    }

    public var socket: String
    public var workspaces: [Workspace]

    public init(socket: String, workspaces: [Workspace]) {
        self.socket = socket
        self.workspaces = workspaces
    }

    /// The workspace for a working directory: the one with the longest matching root.
    public func workspace(for directory: String) -> Workspace? {
        let path = (directory as NSString).standardizingPath
        return workspaces.filter { $0.contains(path) }
            .max { ($0.roots.filter { path.hasPrefix($0) }.map(\.count).max() ?? 0) < ($1.roots.filter { path.hasPrefix($0) }.map(\.count).max() ?? 0) }
    }

    /// Host variables that describe the Mac, not the container, or that belong to opencode or BelloCode. Everything
    /// else in the command's environment (TERM, LANG, session variables set through opencode) is passed to the exec.
    public static let hostOnlyNames: Set<String> = [
        "PATH", "HOME", "TMPDIR", "SHELL", "USER", "LOGNAME", "PWD", "OLDPWD", "SHLVL", "_", "SSH_AUTH_SOCK",
        "COMMAND_MODE", "MallocNanoZone", "LaunchInstanceID", "SECURITYSESSIONID", "XPC_FLAGS", "XPC_SERVICE_NAME",
        "BELLOCODE_EXEC_CONFIG", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "OPENCODE_CLIENT",
    ]
    public static let hostOnlyPrefixes = ["XDG_", "__CF", "DYLD_", "OPENCODE_PASSWORD", "OPENCODE_SERVER", "OPENCODE_DISABLE",
                                          "OPENCODE_CONFIG", "OPENCODE_PTY", "BUN_", "Apple_", "LC_TERMINAL",
                                          // Host git policy (hooks off for host git) must not leak into the container's git.
                                          "GIT_CONFIG_"]

    public static func forwardedEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { name, _ in
            !hostOnlyNames.contains(name) && !hostOnlyPrefixes.contains { name.hasPrefix($0) }
        }
    }
}
