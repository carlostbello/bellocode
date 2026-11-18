import Foundation

/// What `bellocode-exec` reads at start (path in `BELLOCODE_EXEC_CONFIG`). Written atomically by the app whenever a
/// project's environment changes; read on every command, so a fix (Rancher started, image chosen) applies to the next
/// command without restarting anything. Holds no secrets (non-secret environment values only).
public struct ExecHelperConfig: Codable, Sendable, Equatable {
    public static let currentVersion = 3

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
        /// The project's services (names): `bellocode-exec --service NAME` opens a shell in one of them.
        public var services: [String]?

        public init(roots: [String], container: String, user: String? = nil, shell: String = "/bin/sh", blocked: Blocked? = nil,
                    spec: WorkspaceSpec? = nil, mountIdentity: String? = nil, image: String? = nil,
                    inventory: ContainerProbes.ToolInventory? = nil, services: [String]? = nil) {
            self.services = services
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
    /// The app launch that wrote this file and its write generation (S4): the helper runs a command only when they
    /// match the app's `Requirement` (same launch, generation at least the required one).
    public var epoch: String?
    public var generation: Int?
    /// Global image-based MCP servers (`bellocode-exec --stdio --mcp <id>`), by id. Secret variable names only.
    public var mcpServers: [ImageMCPSpec]?
    /// Where the helper keeps the last part of each image server's error output (`<id>.log`, bounded).
    public var mcpLogDirectory: String?

    public init(socket: String, workspaces: [Workspace], runtimeBlocked: Blocked? = nil, epoch: String? = nil, generation: Int? = nil,
                mcpServers: [ImageMCPSpec]? = nil, mcpLogDirectory: String? = nil) {
        version = Self.currentVersion
        self.socket = socket
        self.workspaces = workspaces
        self.runtimeBlocked = runtimeBlocked
        self.epoch = epoch
        self.generation = generation
        self.mcpServers = mcpServers
        self.mcpLogDirectory = mcpLogDirectory
    }

    enum CodingKeys: String, CodingKey { case version, socket, workspaces, runtimeBlocked, epoch, generation, mcpServers, mcpLogDirectory }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        socket = try c.decode(String.self, forKey: .socket)
        workspaces = try c.decode([Workspace].self, forKey: .workspaces)
        runtimeBlocked = try c.decodeIfPresent(Blocked.self, forKey: .runtimeBlocked)
        epoch = try c.decodeIfPresent(String.self, forKey: .epoch)
        generation = try c.decodeIfPresent(Int.self, forKey: .generation)
        mcpServers = try c.decodeIfPresent([ImageMCPSpec].self, forKey: .mcpServers)
        mcpLogDirectory = try c.decodeIfPresent(String.self, forKey: .mcpLogDirectory)
    }

    /// What the app requires of the installed configuration (S4 in docs/reviews/deep-review-1.md): written *before*
    /// each configuration with that configuration's generation, so a configuration write that failed, was overtaken or
    /// is left from an earlier launch never authorises a command. Kept next to the configuration
    /// (`bellocode-exec.required`).
    public struct Requirement: Codable, Sendable, Equatable {
        public var epoch: String
        public var generation: Int

        public init(epoch: String, generation: Int) {
            self.epoch = epoch
            self.generation = generation
        }

        public static func url(forConfig config: URL) -> URL {
            config.deletingPathExtension().appendingPathExtension("required")
        }

        public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    }

    /// The message the helper reports instead of running, or nil when this configuration may authorise commands.
    public func refusal(requirement: Requirement?) -> String? {
        let pending = "BelloCode has not finished saving the current command policy for this launch (or could not save it), so nothing ran under an older one. Retry in a moment; if this persists, open Settings ▸ Containers."
        guard let requirement, let epoch, let generation else { return pending }
        guard epoch == requirement.epoch, generation >= requirement.generation else { return pending }
        return nil
    }

    /// The configuration's encoded form (sorted keys), as written to disk.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    /// Writes `data` atomically with mode 0600, creating the folder (0700) if needed.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The workspace for a working directory: the one with the longest matching root.
    public func workspace(for directory: String) -> Workspace? {
        let path = (directory as NSString).standardizingPath
        return workspaces.filter { $0.contains(path) }.max { $0.matchLength(path) < $1.matchLength(path) }
    }

    /// The workspace for a working directory and that directory as it is mounted in the container. The process's
    /// current directory is a resolved path (`/private/var/…`, `/private/tmp/…`) while roots are kept as the user
    /// opened them (`/var/…`): when the plain lookup fails, each root's resolved form is matched and the directory is
    /// translated back to the mounted spelling.
    public func resolve(directory: String) -> (workspace: Workspace, directory: String)? {
        let path = (directory as NSString).standardizingPath
        if let workspace = workspace(for: path) { return (workspace, path) }
        let resolved = (path as NSString).resolvingSymlinksInPath
        var best: (workspace: Workspace, directory: String, length: Int)?
        for workspace in workspaces {
            for root in workspace.roots {
                let real = (root as NSString).resolvingSymlinksInPath
                guard resolved == real || resolved.hasPrefix(real.hasSuffix("/") ? real : real + "/") else { continue }
                let translated = root + resolved.dropFirst(real.count)
                if real.count > (best?.length ?? -1) { best = (workspace, translated, real.count) }
            }
        }
        return best.map { ($0.workspace, $0.directory) }
    }

    /// Writes the file atomically with mode 0600 (no partial file is ever read by a running helper).
    public func write(to url: URL) throws {
        try Self.writeAtomically(try encoded(), to: url)
    }

    /// Host variables that describe the Mac, not the container, or that belong to opencode or BelloCode. Everything
    /// else in the command's environment (TERM, LANG, session variables set through opencode) is passed to the exec.
    public static let hostOnlyNames: Set<String> = [
        "PATH", "HOME", "TMPDIR", "SHELL", "USER", "LOGNAME", "PWD", "OLDPWD", "SHLVL", "_", "SSH_AUTH_SOCK",
        "COMMAND_MODE", "MallocNanoZone", "LaunchInstanceID", "SECURITYSESSIONID", "XPC_FLAGS", "XPC_SERVICE_NAME",
        "BELLOCODE_EXEC_CONFIG", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "OPENCODE_CLIENT",
        // The Mac's certificate and proxy settings (opencode's): containers get their own at creation (CorporateNetwork),
        // which a host path or a Mac-loopback proxy here would override.
        "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE", "PIP_CERT", "GIT_SSL_CAINFO", "CURL_CA_BUNDLE",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "no_proxy", "all_proxy",
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
