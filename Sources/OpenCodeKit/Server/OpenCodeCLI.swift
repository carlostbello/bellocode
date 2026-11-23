import Foundation

/// How `bellocode-opencode` (Contents/Helpers) runs the bundled opencode CLI against BelloCode's isolated data
/// (docs/features/opencode-config.md, "Command-line tool"). A pure plan, so it is tested without running anything.
///
/// opencode 2.3.2's client commands connect to the per-user background service by default and start one when none is
/// registered: against BelloCode's data that would be a second server on the same database. So the wrapper never lets
/// a command pick a server itself:
/// - BelloCode running (`ServerAvailability.running`: a valid `CLIConnectionFile` and the password from the app's
///   `CLIPasswordBroker`): `--server <url>` is inserted and the per-launch password is passed in `OPENCODE_PASSWORD`
///   (environment only, never the command line). Credential writes (`auth login`, …) go through the running server,
///   the database's one writer.
/// - BelloCode not running (`.offline`: this process holds the data root's `OpenCodeDataLock`, which it keeps across
///   `execve`): management commands get `--standalone` (a private server that exits with the command, the only writer
///   while it holds the lock). Commands that run an agent, MCP servers or arbitrary API calls are refused: a standalone
///   server has no container shell, so they would execute on the Mac.
/// - Neither (`.busy`: the lock is held but no server is published: BelloCode starting or stopping, or another
///   private server): refused, never a second server on the same data (A13).
/// - File-only commands (`mcp add`, `plugin add|remove`, `debug paths`) run directly. `service`, `serve`, `upgrade`,
///   `uninstall`, `pair` and `acp` are refused (they start or replace servers, or modify the bundled binary).
public enum OpenCodeCLI {
    /// What a command needs.
    public enum Kind: Sendable, Equatable {
        /// Runs without a server (file edits, help).
        case direct
        /// A client command. `standalone` is whether a private server is acceptable when BelloCode is not running.
        case client(standalone: Bool)
        case refused(String)
    }

    public struct Invocation: Sendable, Equatable {
        public var executable: URL
        public var arguments: [String]
        public var environment: [String: String]
        /// One line for stderr before running (nil when nothing needs saying).
        public var notice: String?
    }

    public struct Refusal: Error, Sendable, Equatable, CustomStringConvertible {
        public var message: String
        public var description: String { message }
        public init(message: String) { self.message = message }
    }

    /// Whether BelloCode's server can be used, found by `discover` (only when a command needs a server).
    public enum ServerAvailability: Sendable, Equatable {
        case running(url: URL, password: String)
        /// No server, and this process holds the data lock: a private standalone server is the only writer.
        case offline
        /// The lock is held by someone else and no server is published (BelloCode starting or stopping, or another
        /// `bellocode-opencode` with its own private server).
        case busy
    }

    static let busyMessage = "BelloCode's opencode server is starting or stopping, or another bellocode-opencode command is using its data. Try again in a moment."

    /// Flags taking a value that may appear before the subcommand.
    static let valueFlags: Set<String> = ["--log-level", "--server", "--session", "-s", "--prompt", "--completions"]

    /// The subcommand path (`["auth", "login"]`), its end index in `arguments`, and whether help/version was asked for.
    static func commandPath(_ arguments: [String]) -> (path: [String], end: Int, help: Bool) {
        var path: [String] = []
        var index = 0
        var help = false
        var end = 0
        let groups: Set<String> = ["auth", "mcp", "plugin", "debug", "session", "service"]
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { break }
            // Help anywhere; the version only as the whole command (`opencode -v`), never next to a subcommand, where
            // the flag could mean something else and the command would run without BelloCode's routing (N06).
            if ["--help", "-h"].contains(argument) || argument.hasPrefix("--completions") { help = true }
            if ["--version", "-v"].contains(argument), arguments.count == 1 { help = true }
            if argument.hasPrefix("-") {
                if valueFlags.contains(argument) { index += 1 }
                index += 1
                continue
            }
            if path.isEmpty || (path.count == 1 && groups.contains(path[0])) {
                path.append(argument)
                end = index + 1
                index += 1
                continue
            }
            break
        }
        return (path, end, help)
    }

    public static func kind(of path: [String]) -> Kind {
        guard let first = path.first else { return .client(standalone: false) }  // the interactive interface
        let second = path.count > 1 ? path[1] : nil
        switch first {
        case "service", "serve":
            return .refused("`opencode \(first)` starts its own server on BelloCode's data; BelloCode supervises its server itself. Quit BelloCode to stop it.")
        case "upgrade", "update", "uninstall":
            return .refused("BelloCode bundles a pinned opencode; it is updated with BelloCode, not with `opencode \(first)`.")
        case "pair":
            return .refused("`opencode pair` would expose BelloCode's server to a browser or another app; it is not supported.")
        case "acp":
            return .refused("`opencode acp` starts its own server; it is not supported with BelloCode's data.")
        case "api", "run", "mini", "reload":
            return .client(standalone: false)
        case "models", "stats":
            return .client(standalone: true)
        case "auth":
            return .client(standalone: true)
        case "session":
            return .client(standalone: true)
        case "mcp":
            switch second {
            case "add": return .direct
            // Listing connects the configured MCP servers: only BelloCode's server routes them into containers.
            default: return .client(standalone: false)
            }
        case "plugin":
            switch second {
            case "add", "remove": return .direct
            default: return .client(standalone: true)
            }
        case "debug":
            switch second {
            case "paths", nil: return .direct
            case "heap-dump": return .client(standalone: false)
            default: return .client(standalone: true)
            }
        default:
            // A directory argument: the interactive interface in that folder.
            return .client(standalone: false)
        }
    }

    /// Plans one run. `server` is asked only when the command needs BelloCode's server (`discover` in the wrapper).
    public static func plan(
        arguments: [String], callerEnvironment: [String: String], directories: OpenCodeDirectories, opencode: URL,
        helpersDirectory: URL?, server: () -> Result<ServerAvailability, Refusal>
    ) -> Result<Invocation, Refusal> {
        let (path, end, help) = commandPath(arguments)
        var environment = callerEnvironment.filter { key, _ in
            !OpenCodeDirectories.redirectingVariables.contains(key) && !ServerConfiguration.forbiddenEnvironmentPrefixes.contains { key.hasPrefix($0) }
        }
        environment.merge(directories.isolationEnvironment()) { _, isolated in isolated }
        // A private standalone server started from a repository must not load that repository's plugins or config on
        // the Mac (the same default as BelloCode's server).
        environment["OPENCODE_DISABLE_PROJECT_CONFIG"] = "1"
        environment["OPENCODE_CLIENT"] = "bellocode-cli"
        if let helpers = helpersDirectory?.path {
            let rest = callerEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            environment["PATH"] = rest.isEmpty ? helpers : "\(helpers):\(rest)"
        }
        func invocation(_ args: [String], notice: String? = nil) -> Result<Invocation, Refusal> {
            .success(Invocation(executable: opencode, arguments: args, environment: environment, notice: notice))
        }
        let kind = kind(of: path)
        if case .refused(let message) = kind { return .failure(Refusal(message: message)) }
        if help { return invocation(arguments) }
        switch kind {
        case .refused(let message):
            return .failure(Refusal(message: message))
        case .direct:
            return invocation(arguments)
        case .client(let standaloneAllowed):
            let flags = arguments.prefix { $0 != "--" }
            let explicitServer = flags.contains { $0 == "--server" || $0.hasPrefix("--server=") }
            // `--standalone=true` and friends count too (N06).
            let explicitStandalone = flags.contains { $0 == "--standalone" || $0.hasPrefix("--standalone=") }
            if explicitServer {
                // Someone else's server: never send BelloCode's password to it. Their own OPENCODE_PASSWORD is kept.
                if let password = callerEnvironment["OPENCODE_PASSWORD"] { environment["OPENCODE_PASSWORD"] = password }
                return invocation(arguments)
            }
            let availability: ServerAvailability
            switch server() {
            case .success(let value): availability = value
            case .failure(let refusal): return .failure(refusal)
            }
            switch availability {
            case .running(let url, let password):
                if explicitStandalone {
                    return .failure(Refusal(message: "BelloCode is running: --standalone would open a second server on its database. Leave out --standalone to use BelloCode's server."))
                }
                environment["OPENCODE_PASSWORD"] = password
                var args = arguments
                args.insert(contentsOf: ["--server", url.absoluteString], at: end)
                return invocation(args)
            case .busy:
                return .failure(Refusal(message: busyMessage))
            case .offline:
                guard standaloneAllowed else {
                    let name = path.isEmpty ? "the interactive interface" : "`opencode \(path.joined(separator: " "))`"
                    return .failure(Refusal(message: "\(name) needs BelloCode's server (its agents and MCP servers run in containers). Open BelloCode, then run it again."))
                }
                var args = arguments
                if !explicitStandalone { args.insert("--standalone", at: end) }
                return invocation(args, notice: "BelloCode is not running: using a private opencode server on BelloCode's data for this command.")
            }
        }
    }

    /// Finds BelloCode's server for one command. Takes the data lock first: holding it means no BelloCode server
    /// exists or is starting (`.offline`, and the returned lock must be kept across `execve`). Otherwise the server
    /// must be published and the app must hand over its address and password, the address matching the connection
    /// file's; a lock without a server is `.busy`.
    public static func discover(_ directories: OpenCodeDirectories) -> (Result<ServerAvailability, Refusal>, OpenCodeDataLock?) {
        let lock: OpenCodeDataLock?
        do {
            lock = try OpenCodeDataLock.tryAcquire(directories)
        } catch {
            return (.failure(Refusal(message: error.description)), nil)
        }
        if let lock { return (.success(.offline), lock) }
        let file: CLIConnectionFile
        do {
            file = try CLIConnectionFile.read(from: directories.connectionFile)
        } catch {
            switch error {
            case .missing, .stale: return (.success(.busy), nil)
            default: return (.failure(Refusal(message: error.description)), nil)
            }
        }
        let served: (url: URL, password: String)
        do {
            served = try CLIPasswordClient.server(directories: directories, pid: file.pid)
        } catch {
            return (.failure(Refusal(message: error.description)), nil)
        }
        // The password goes only to the address the app vouches for; a connection file naming another one was changed
        // by someone else and is not followed (AF02).
        guard served.url == file.url else {
            return (.failure(Refusal(message: "BelloCode's connection file (\(directories.connectionFile.path)) names a different address from its running server, so the password is not sent. Restart BelloCode.")), nil)
        }
        return (.success(.running(url: served.url, password: served.password)), nil)
    }

    /// The opencode binary to run: the one bundled beside this helper. `BELLOCODE_OPENCODE_BINARY` (development and
    /// tests) is honoured in debug builds only, never in a release build that would hand it the live password (A24, N06).
    public static func opencodeExecutable(environment: [String: String], helpersDirectory: URL) -> URL {
        #if DEBUG
        if let override = environment["BELLOCODE_OPENCODE_BINARY"], !override.isEmpty { return URL(fileURLWithPath: override) }
        #endif
        return helpersDirectory.appending(path: "opencode")
    }

    /// The data root the app uses (`~/Library/Application Support/BelloCode/opencode`); `BELLOCODE_OPENCODE_DATA_ROOT`
    /// overrides it in debug builds only (development and tests; N06).
    public static func defaultDataRoot(environment: [String: String]) -> URL {
        #if DEBUG
        if let override = environment["BELLOCODE_OPENCODE_DATA_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return support.appending(path: "BelloCode/opencode", directoryHint: .isDirectory)
    }
}
