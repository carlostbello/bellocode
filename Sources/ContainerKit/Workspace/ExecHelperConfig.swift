import Foundation

/// What `bellocode-exec` reads at start (path in `BELLOCODE_EXEC_CONFIG`). Written atomically by the app whenever a
/// project's environment changes; read on every command, so a fix (Rancher started, image chosen) applies to the next
/// command without restarting anything. Holds no secrets (non-secret environment values only).
public struct ExecHelperConfig: Codable, Sendable, Equatable {
    public static let currentVersion = 2

    /// Why commands in a workspace cannot run now, and the fix the user sees in the app.
    public struct Blocked: Codable, Sendable, Equatable {
        public var message: String
        /// The button in the app's banner ("Start Rancher Desktop", "Choose an image", "Sign in to the registry").
        public var fix: String?
        public init(message: String, fix: String? = nil) {
            self.message = message
            self.fix = fix
        }
    }

    public struct Workspace: Codable, Sendable, Equatable {
        /// Host paths commands may run in, visible in the container at the same path (project root first, then its
        /// worktree folders).
        public var roots: [String]
        /// The container's name (`WorkspaceSpec.containerName`).
        public var container: String
        public var user: String?
        /// Shell inside the container, e.g. `/bin/sh`.
        public var shell: String
        /// Set when the app knows commands cannot run (no image, pull failed, runtime down): the helper reports it.
        public var blocked: Blocked?
        /// The full setting, so the helper can create or start the container on first use (it never pulls).
        public var spec: WorkspaceSpec?
        /// What the image offers, for the agent's guidance (the plugin reads it); nil until the container first ran.
        public var image: String?
        public var inventory: ContainerProbes.ToolInventory?
        /// `spec.mountIdentity()` when the app last ensured the container; a different value now means a mounted folder
        /// was replaced, and the helper recreates the container before running the command.
        public var mountIdentity: String?

        public init(roots: [String], container: String, user: String? = nil, shell: String = "/bin/sh", blocked: Blocked? = nil,
                    spec: WorkspaceSpec? = nil, mountIdentity: String? = nil, image: String? = nil,
                    inventory: ContainerProbes.ToolInventory? = nil) {
            self.mountIdentity = mountIdentity
            self.image = image
            self.inventory = inventory
            self.roots = roots
            self.container = container
            self.user = user
            self.shell = shell
            self.blocked = blocked
            self.spec = spec
        }

        public func contains(_ path: String) -> Bool {
            roots.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }

        /// The longest root containing `path` (0 if none).
        func matchLength(_ path: String) -> Int {
            roots.filter { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }.map(\.count).max() ?? 0
        }
    }

    public var version: Int
    public var socket: String
    public var workspaces: [Workspace]
    /// When the whole runtime is unusable (not running, containerd), every command reports this.
    public var runtimeBlocked: Blocked?

    public init(socket: String, workspaces: [Workspace], runtimeBlocked: Blocked? = nil) {
        version = Self.currentVersion
        self.socket = socket
        self.workspaces = workspaces
        self.runtimeBlocked = runtimeBlocked
    }

    enum CodingKeys: String, CodingKey { case version, socket, workspaces, runtimeBlocked }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        socket = try c.decode(String.self, forKey: .socket)
        workspaces = try c.decode([Workspace].self, forKey: .workspaces)
        runtimeBlocked = try c.decodeIfPresent(Blocked.self, forKey: .runtimeBlocked)
    }

    /// The workspace for a working directory: the one with the longest matching root.
    public func workspace(for directory: String) -> Workspace? {
        let path = (directory as NSString).standardizingPath
        return workspaces.filter { $0.contains(path) }.max { $0.matchLength(path) < $1.matchLength(path) }
    }

    /// Writes the file atomically with mode 0600 (no partial file is ever read by a running helper).
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Host variables that describe the Mac, not the container, or that belong to opencode or BelloCode. Everything
    /// else in the command's environment (TERM, LANG, session variables set through opencode) is passed to the exec.
    public static let hostOnlyNames: Set<String> = [
        "PATH", "HOME", "TMPDIR", "SHELL", "USER", "LOGNAME", "PWD", "OLDPWD", "SHLVL", "_", "SSH_AUTH_SOCK",
        "COMMAND_MODE", "MallocNanoZone", "LaunchInstanceID", "SECURITYSESSIONID", "XPC_FLAGS", "XPC_SERVICE_NAME",
        "BELLOCODE_EXEC_CONFIG", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "OPENCODE_CLIENT",
    ]
    public static let hostOnlyPrefixes = ["XDG_", "__CF", "DYLD_", "OPENCODE_PASSWORD", "OPENCODE_SERVER", "OPENCODE_DISABLE",
                                          "OPENCODE_CONFIG", "OPENCODE_PTY", "OPENCODE_EXPERIMENTAL", "BUN_", "Apple_",
                                          "LC_TERMINAL", "BELLOCODE_",
                                          // Host git policy (hooks off for host git) must not leak into the container's git.
                                          "GIT_CONFIG_"]

    public static func forwardedEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { name, _ in
            !hostOnlyNames.contains(name) && !hostOnlyPrefixes.contains { name.hasPrefix($0) }
        }
    }
}
