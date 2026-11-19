import Foundation

/// How `bellocode-opencode` (Contents/Helpers) runs the bundled opencode CLI against BelloCode's isolated data
/// (docs/features/opencode-config.md, "Command-line tool"). A pure plan, so it is tested without running anything.
///
/// opencode 2.3.2's client commands connect to the per-user background service by default and start one when none is
/// registered: against BelloCode's data that would be a second server on the same database. So the wrapper never lets
/// a command pick a server itself:
/// - BelloCode running (a valid `CLIConnectionFile`): `--server <url>` is inserted and the per-launch password is
///   passed in `OPENCODE_PASSWORD` (environment only, never the command line). Credential writes (`auth login`, …) go
///   through the running server, the database's one writer.
/// - BelloCode not running: management commands get `--standalone` (a private server that exits with the command;
///   BelloCode is not running, so it is the only writer). Commands that run an agent, MCP servers or arbitrary API
///   calls are refused: a standalone server has no container shell, so they would execute on the Mac.
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
    }

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
            if ["--help", "-h", "--version", "-v"].contains(argument) || argument.hasPrefix("--completions") { help = true }
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

    /// Plans one run. `connection` is the running server's file (nil when BelloCode is not running).
    public static func plan(
        arguments: [String], callerEnvironment: [String: String], directories: OpenCodeDirectories, opencode: URL,
        helpersDirectory: URL?, connection: CLIConnectionFile?
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
        if help { return invocation(arguments) }
        let kind = kind(of: path)
        switch kind {
        case .refused(let message):
            return .failure(Refusal(message: message))
        case .direct:
            return invocation(arguments)
        case .client(let standaloneAllowed):
            let flags = arguments.prefix { $0 != "--" }
            let explicitServer = flags.contains { $0 == "--server" || $0.hasPrefix("--server=") }
            let explicitStandalone = flags.contains("--standalone")
            if explicitServer {
                // Someone else's server: never send BelloCode's password to it. Their own OPENCODE_PASSWORD is kept.
                if let password = callerEnvironment["OPENCODE_PASSWORD"] { environment["OPENCODE_PASSWORD"] = password }
                return invocation(arguments)
            }
            if let connection {
                if explicitStandalone {
                    return .failure(Refusal(message: "BelloCode is running: --standalone would open a second server on its database. Leave out --standalone to use BelloCode's server."))
                }
                environment["OPENCODE_PASSWORD"] = connection.password
                var args = arguments
                args.insert(contentsOf: ["--server", connection.url.absoluteString], at: end)
                return invocation(args)
            }
            guard standaloneAllowed else {
                let name = path.isEmpty ? "the interactive interface" : "`opencode \(path.joined(separator: " "))`"
                return .failure(Refusal(message: "\(name) needs BelloCode's server (its agents and MCP servers run in containers). Open BelloCode, then run it again."))
            }
            var args = arguments
            if !explicitStandalone { args.insert("--standalone", at: end) }
            return invocation(args, notice: "BelloCode is not running: using a private opencode server on BelloCode's data for this command.")
        }
    }

    /// The data root the app uses (`~/Library/Application Support/BelloCode/opencode`); `BELLOCODE_OPENCODE_DATA_ROOT`
    /// overrides it (development and tests).
    public static func defaultDataRoot(environment: [String: String]) -> URL {
        if let override = environment["BELLOCODE_OPENCODE_DATA_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return support.appending(path: "BelloCode/opencode", directoryHint: .isDirectory)
    }
}
