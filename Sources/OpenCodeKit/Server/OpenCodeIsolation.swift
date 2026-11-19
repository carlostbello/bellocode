import Darwin
import Foundation

/// BelloCode's isolated opencode directories under one data root (`~/Library/Application Support/BelloCode/opencode`
/// in the app). The server, the `bellocode-opencode` command-line wrapper and Settings ▸ opencode all derive their
/// paths here, so they always agree. The user's own `~/.config/opencode` and `~/.local/share/opencode` are never used.
/// docs/features/opencode-config.md.
public struct OpenCodeDirectories: Sendable, Hashable {
    public var dataRoot: URL
    /// The child's HOME; `<dataRoot>/home` unless overridden.
    public var home: URL

    public init(dataRoot: URL, home: URL? = nil) {
        self.dataRoot = dataRoot.standardizedFileURL
        self.home = home ?? dataRoot.standardizedFileURL.appending(path: "home", directoryHint: .isDirectory)
    }

    /// `XDG_CONFIG_HOME`.
    public var config: URL { dataRoot.appending(path: "config", directoryHint: .isDirectory) }
    /// `XDG_DATA_HOME` (opencode's database, logs, snapshots).
    public var data: URL { dataRoot.appending(path: "data", directoryHint: .isDirectory) }
    public var state: URL { dataRoot.appending(path: "state", directoryHint: .isDirectory) }
    public var cache: URL { dataRoot.appending(path: "cache", directoryHint: .isDirectory) }

    /// opencode's global configuration folder: `opencode.json`, `AGENTS.md`, `agents/`, `commands/`, `skills/`,
    /// `plugins/` (all measured to load on 2.3.2).
    public var globalConfigFolder: URL { config.appending(path: "opencode", directoryHint: .isDirectory) }

    /// Private run-time files (the CLI connection file). Created 0700.
    public var runDirectory: URL { dataRoot.appending(path: "run", directoryHint: .isDirectory) }
    /// The running server's address and per-launch password for `bellocode-opencode` (`CLIConnectionFile`).
    public var connectionFile: URL { runDirectory.appending(path: "server.json") }
    /// Which projects' repository opencode configuration BelloCode's plugin loads (`ProjectTrustFile`).
    public var trustFile: URL { dataRoot.appending(path: "bellocode-trust.json") }

    /// The variables that point opencode at these directories, shared by the server and the CLI wrapper. Model
    /// catalogue fetches and auto-update stay off (pinned binary); Claude Code files are not read.
    public func isolationEnvironment() -> [String: String] {
        [
            "HOME": home.path,
            "XDG_CONFIG_HOME": config.path,
            "XDG_DATA_HOME": data.path,
            "XDG_STATE_HOME": state.path,
            "XDG_CACHE_HOME": cache.path,
            "OPENCODE_DISABLE_AUTOUPDATE": "1",
            "OPENCODE_DISABLE_MODELS_FETCH": "1",
            "OPENCODE_DISABLE_CLAUDE_CODE": "1",
        ]
    }

    /// Variables from the caller's environment that would point opencode somewhere else (another config folder, a
    /// database, extra config layers) or make the binary a JavaScript runtime. Never passed through.
    public static let redirectingVariables: Set<String> = [
        "HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "OPENCODE_CONFIG_DIR", "OPENCODE_CONFIG",
        "OPENCODE_CONFIG_CONTENT", "OPENCODE_CLI_CONFIG_CONTENT", "OPENCODE_DB", "OPENCODE_TEST_HOME", "OPENCODE_PASSWORD",
        "OPENCODE_SERVER_PASSWORD", "OPENCODE_DISABLE_PROJECT_CONFIG", "OPENCODE_CONFIG_PROJECT_DISABLE", "OPENCODE_FLAGS",
        "OPENCODE_MODELS_PATH", "OPENCODE_MODELS_URL",
    ]
}

/// How repository opencode configuration (`opencode.json`, `.opencode/`, `.agents/skills`, `AGENTS.md`) is handled.
/// opencode reads its project-config switch once per server process, so this is a server-wide choice.
public enum RepositoryConfigPolicy: String, Sendable, Hashable, Codable, CaseIterable {
    /// The default: opencode's own project config is off (`OPENCODE_DISABLE_PROJECT_CONFIG=1`). BelloCode's plugin
    /// adds every repository's `AGENTS.md` text to its sessions, and for projects the person trusts it also loads the
    /// repository's agents, commands and skills (text only). Repository `opencode.json` and plugins never load.
    case bellocode
    /// opencode loads every repository's `opencode.json`, `.opencode/` (plugins included) and `AGENTS.md` natively,
    /// for every project this server opens. Plugins and config run inside opencode on the Mac.
    case native
}

/// The private file through which `bellocode-opencode` reaches the running server: its URL, pid, version and
/// per-launch password. Written by the supervisor once the server is verified, removed when it exits. The password is
/// never on a command line; the file is created 0600 in a 0700 folder owned by the user, and a reader refuses anything
/// looser or owned by someone else.
public struct CLIConnectionFile: Codable, Sendable, Hashable {
    public var url: URL
    public var pid: Int32
    public var version: String
    public var password: String

    public init(url: URL, pid: Int32, version: String, password: String) {
        self.url = url
        self.pid = pid
        self.version = version
        self.password = password
    }

    public enum ReadError: Error, Sendable, Equatable, CustomStringConvertible {
        case missing
        case insecure(String)
        case unreadable(String)
        /// The server named in the file is not running (left behind by a crash).
        case stale(pid: Int32)

        public var description: String {
            switch self {
            case .missing: "BelloCode's opencode server is not running"
            case .insecure(let why): "refusing the connection file: \(why)"
            case .unreadable(let why): "cannot read the connection file: \(why)"
            case .stale(let pid): "BelloCode's opencode server (pid \(pid)) is no longer running"
            }
        }
    }

    /// Writes atomically with mode 0600 (the folder 0700).
    public func write(to file: URL) throws {
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // An existing folder keeps its mode: tighten it.
        chmod(folder.path, 0o700)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        let temporary = folder.appending(path: ".server.\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: temporary.path]) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, rename(temporary.path, file.path) == 0 else {
            unlink(temporary.path)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
    }

    /// Reads and checks the file: owned by the current user, not readable or writable by group or others (nor its
    /// folder), and naming a live process.
    public static func read(from file: URL, checkProcess: Bool = true) throws(ReadError) -> CLIConnectionFile {
        var info = stat()
        guard lstat(file.path, &info) == 0 else { throw .missing }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw .insecure("not a regular file") }
        guard info.st_uid == getuid() else { throw .insecure("owned by another user") }
        guard (info.st_mode & 0o077) == 0 else { throw .insecure("readable by other users (mode \(String(info.st_mode & 0o777, radix: 8)))") }
        var folder = stat()
        let folderPath = file.deletingLastPathComponent().path
        guard stat(folderPath, &folder) == 0, folder.st_uid == getuid(), (folder.st_mode & 0o022) == 0 else {
            throw .insecure("its folder is writable by other users")
        }
        let data: Data
        do { data = try Data(contentsOf: file) } catch { throw .unreadable(error.localizedDescription) }
        guard let value = try? JSONDecoder().decode(CLIConnectionFile.self, from: data) else { throw .unreadable("unexpected contents") }
        if checkProcess, kill(value.pid, 0) != 0, errno == ESRCH { throw .stale(pid: value.pid) }
        return value
    }

    /// Removes the file if it still describes `pid` (a newer server's file is left alone).
    public static func remove(at file: URL, ifPID pid: Int32) {
        guard let current = try? read(from: file, checkProcess: false), current.pid == pid else { return }
        unlink(file.path)
    }
}

/// The projects whose repository opencode configuration BelloCode's plugin loads in `.bellocode` mode
/// (`<data>/bellocode-trust.json`, rewritten by the app; no secrets). The plugin reads it at each location's setup
/// and when the app asks it to reload.
public struct ProjectTrustFile: Codable, Sendable, Hashable {
    public var version: Int
    /// Absolute project directories, sorted.
    public var trusted: [String]

    public init(trusted: [String]) {
        version = 1
        self.trusted = Array(Set(trusted)).sorted()
    }

    public func write(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    public static func read(from file: URL) -> ProjectTrustFile {
        guard let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(ProjectTrustFile.self, from: data) else {
            return ProjectTrustFile(trusted: [])
        }
        return value
    }

    /// Whether `directory` is one of the trusted projects or inside one (worktrees of a project are separate projects).
    public func isTrusted(_ directory: String) -> Bool {
        let path = (directory as NSString).standardizingPath
        return trusted.contains { root in
            let root = (root as NSString).standardizingPath
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }
}
