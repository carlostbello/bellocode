import Foundation

/// Local (stdio) MCP servers under container execution (docs/features/containers.md, "MCP servers"). opencode spawns a
/// local server's `command` on the Mac, so BelloCode never hands it one that runs there:
///
/// - **Project servers** (Project Settings ▸ Environment ▸ MCP servers) are added per location at runtime
///   (`PUT /api/experimental/mcp/{name}?location[directory]=…`, scoped to that location only, checked on 2.3.0) with the
///   command rewritten to `bellocode-exec --stdio --project <project> -- <command…>`: the program runs in that project's
///   workspace container and only its stdin/stdout cross over.
/// - **Global image servers** (Settings ▸ MCP Servers, kind "Container image") are registered per location as
///   `bellocode-exec --stdio --mcp <id> --project <dir>`: the image runs in its own container, no project folder mounted.
/// - **Servers configured for all projects** (a `mcp.servers` entry in BelloCode's isolated opencode configuration
///   files): an entry whose command is `docker run … IMAGE …` (no mounts, nothing refused by `DockerRunCommand`) runs
///   that image the same way (`--mcp cfg-<name>`); any other command is refused: it has no container, mounts or image
///   to run in. Each entry is replaced in `OPENCODE_CONFIG_CONTENT` (which replaces a server's entry whole and wins over
///   the files, checked on 2.3.0); a refusal is `bellocode-exec --stdio --refuse <name>`, which prints why and runs
///   nothing; opencode shows that text as the server's failure.
public enum MCPRouting {
    /// `bellocode-exec --stdio --project <project> -- <argv…>`.
    public static func routedCommand(helper: String, project: String, argv: [String]) -> [String] {
        [helper, "--stdio", "--project", project, "--"] + argv
    }

    public static func refusedCommand(helper: String, name: String) -> [String] {
        [helper, "--stdio", "--refuse", name]
    }

    /// `bellocode-exec --stdio --mcp <id> [--project <dir>]`: a global image-based server.
    public static func imageCommand(helper: String, id: String, project: String?) -> [String] {
        [helper, "--stdio", "--mcp", id] + (project.map { ["--project", $0] } ?? [])
    }

    /// The id under which a `docker run` entry of the isolated configuration files is run (`cfg-<name>`).
    public static func configServerID(_ name: String) -> String { "cfg-" + name }

    /// The local-server config for a global image server at one location. `secrets` (Keychain values) travel in the
    /// registration only: opencode passes them to the helper's environment; they are never in a file.
    public static func imageServerConfig(helper: String, id: String, project: String, secrets: [String: String]) -> JSONValue {
        var config: [String: JSONValue] = [
            "type": .string("local"),
            "command": .array(imageCommand(helper: helper, id: id, project: project).map(JSONValue.string)),
            "cwd": .string(project),
            // Pulled images start in well under a second; a fresh per-connection container needs a little longer.
            "timeout": .object(["startup": .number(60_000)]),
        ]
        if !secrets.isEmpty { config["environment"] = .object(secrets.mapValues(JSONValue.string)) }
        return .object(config)
    }

    /// The config for a remote server: URL and headers (secret values included, read from the Keychain just before);
    /// with headers, opencode's OAuth discovery is off (the headers authenticate).
    public static func remoteServerConfig(url: String, headers: [String: String]) -> JSONValue {
        var config: [String: JSONValue] = ["type": .string("remote"), "url": .string(url)]
        if !headers.isEmpty {
            config["headers"] = .object(headers.mapValues(JSONValue.string))
            config["oauth"] = .bool(false)
        }
        return .object(config)
    }
    /// How a local server's command will run.
    public enum Route: Sendable, Equatable {
        /// In the project's container through the helper.
        case container(project: String?)
        /// In its own container from an image (a global image server), no project folder mounted.
        case image(id: String)
        /// Refused by the helper (configured for all projects).
        case refused
        /// On the Mac: an escape.
        case host(String)
    }

    public static func route(of command: [String], helper: String) -> Route {
        guard command.first == helper, command.count >= 2, command[1] == "--stdio" else {
            return .host(command.first ?? "(no command)")
        }
        if command.count >= 3, command[2] == "--refuse" { return .refused }
        if command.count >= 4, command[2] == "--mcp" { return .image(id: command[3]) }
        if command.count >= 4, command[2] == "--project" { return .container(project: command[3]) }
        return .container(project: nil)
    }

    /// The local-server config BelloCode sends for a project server: the routed command, the server's environment
    /// (non-secret values; forwarded into the exec), and the project as working directory.
    public static func projectServerConfig(helper: String, project: String, argv: [String], environment: [String: String],
                                           timeoutMilliseconds: Int? = nil) -> JSONValue {
        var config: [String: JSONValue] = [
            "type": .string("local"),
            "command": .array(routedCommand(helper: helper, project: project, argv: argv).map(JSONValue.string)),
            "cwd": .string(project),
        ]
        if !environment.isEmpty { config["environment"] = .object(environment.mapValues(JSONValue.string)) }
        if let timeoutMilliseconds { config["timeout"] = .object(["startup": .number(Double(timeoutMilliseconds))]) }
        return .object(config)
    }

    /// The configuration files opencode reads from its (BelloCode-isolated) global configuration directory.
    public static let globalFileNames = ["config.json", "opencode.json", "opencode.jsonc"]

    /// One local server of BelloCode's isolated global configuration files.
    public struct GlobalLocalServer: Sendable, Equatable {
        public var name: String
        public var command: [String]
        public var environment: [String: String]
        public var disabled: JSONValue?
        /// The image to run when the command is a convertible `docker run` without mounts; nil when refused.
        public var image: DockerRunCommand?
        /// Why it is refused (nil when `image` is set).
        public var refusal: String?
    }

    /// The local servers in BelloCode's isolated global configuration files (later files win, as in opencode), each
    /// classified: a `docker run` without mounts or refused options runs its image; anything else is refused.
    /// `problems` names files that exist but could not be read.
    public static func globalLocalServers(configDirectory: URL) -> (servers: [String: GlobalLocalServer], problems: [String]) {
        var servers: [String: GlobalLocalServer] = [:]
        var problems: [String] = []
        let folder = configDirectory.appending(path: "opencode", directoryHint: .isDirectory)
        for name in globalFileNames {
            let url = folder.appending(path: name)
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            guard let value = try? JSONValue.parse(Data(JSONC.strip(String(decoding: data, as: UTF8.self)).utf8)) else {
                problems.append(url.path)
                continue
            }
            guard case .object(let entries)? = value["mcp"]?["servers"] else { continue }
            for (server, entry) in entries {
                guard entry["type"]?.stringValue == "local" else {
                    servers[server] = nil
                    continue
                }
                let command: [String] = if case .array(let items)? = entry["command"] { items.compactMap(\.stringValue) } else { [] }
                var environment: [String: String] = [:]
                if case .object(let values)? = entry["environment"] { environment = values.compactMapValues(\.stringValue) }
                var local = GlobalLocalServer(name: server, command: command, environment: environment, disabled: entry["disabled"])
                do {
                    let run = try DockerRunCommand.parse(command)
                    if run.mounts.isEmpty { local.image = run } else { local.refusal = "it mounts folders from this Mac; add it in Settings ▸ MCP Servers to review them" }
                } catch {
                    local.refusal = DockerRunCommand.isDockerRun(command) ? error.description : "its command runs a program, not an image"
                }
                servers[server] = local
            }
        }
        return (servers, problems)
    }

    /// Overrides for every local server in BelloCode's isolated global configuration: a convertible `docker run` becomes
    /// `bellocode-exec --stdio --mcp cfg-<name>` (keeping its `environment` for `-e NAME` values), anything else the
    /// helper's refusal (keeping `disabled`). `problems` names files that exist but could not be read (their servers
    /// cannot be overridden; the isolation self-check then reports them from opencode's own loaded configuration).
    public static func globalOverrides(configDirectory: URL, helper: String) -> (servers: [String: JSONValue], problems: [String]) {
        let (locals, problems) = globalLocalServers(configDirectory: configDirectory)
        var servers: [String: JSONValue] = [:]
        for (server, local) in locals {
            var replacement: [String: JSONValue] = ["type": .string("local")]
            if local.image != nil {
                replacement["command"] = .array(imageCommand(helper: helper, id: configServerID(server), project: nil).map(JSONValue.string))
                if !local.environment.isEmpty { replacement["environment"] = .object(local.environment.mapValues(JSONValue.string)) }
            } else {
                replacement["command"] = .array(refusedCommand(helper: helper, name: server).map(JSONValue.string))
            }
            if let disabled = local.disabled { replacement["disabled"] = disabled }
            servers[server] = .object(replacement)
        }
        return (servers, problems)
    }
}

/// JSON with comments (opencode accepts `opencode.jsonc`): removes `//` and `/* */` comments and trailing commas outside
/// strings, so the result parses as JSON.
public enum JSONC {
    public static func strip(_ text: String) -> String {
        var output: [Character] = []
        var characters = Array(text)
        characters.append("\n")
        var index = 0
        var inString = false
        while index < characters.count - 1 {
            let character = characters[index]
            if inString {
                output.append(character)
                if character == "\\" {
                    output.append(characters[index + 1])
                    index += 2
                    continue
                }
                if character == "\"" { inString = false }
                index += 1
                continue
            }
            if character == "\"" {
                inString = true
                output.append(character)
                index += 1
                continue
            }
            if character == "/", characters[index + 1] == "/" {
                while index < characters.count - 1, characters[index] != "\n" { index += 1 }
                continue
            }
            if character == "/", characters[index + 1] == "*" {
                index += 2
                while index < characters.count - 1, !(characters[index] == "*" && characters[index + 1] == "/") { index += 1 }
                index += 2
                continue
            }
            if character == "]" || character == "}" {
                // Drop a trailing comma before the closing bracket.
                var back = output.count - 1
                while back >= 0, output[back].isWhitespace { back -= 1 }
                if back >= 0, output[back] == "," { output.remove(at: back) }
            }
            output.append(character)
            index += 1
        }
        return String(output)
    }
}
