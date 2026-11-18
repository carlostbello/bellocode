import Foundation

/// Local (stdio) MCP servers under container execution (docs/features/containers.md, "MCP servers"). opencode spawns a
/// local server's `command` on the Mac, so BelloCode never hands it one that runs there:
///
/// - **Project servers** (Project Settings ▸ Environment ▸ MCP servers) are added per location at runtime
///   (`PUT /api/experimental/mcp/{name}?location[directory]=…`, scoped to that location only, checked on 2.3.0) with the
///   command rewritten to `bellocode-exec --stdio --project <project> -- <command…>`: the program runs in that project's
///   workspace container and only its stdin/stdout cross over.
/// - **Servers configured for all projects** (a `mcp.servers` entry in BelloCode's isolated opencode configuration
///   files) are refused: they have no project, so no container, mounts or image to run in. Their entry is replaced in
///   `OPENCODE_CONFIG_CONTENT` (which replaces a server's entry whole and wins over the files, checked on 2.3.0) by
///   `bellocode-exec --stdio --refuse <name>`, which prints why and runs nothing; opencode shows that text as the
///   server's failure.
public enum MCPRouting {
    /// `bellocode-exec --stdio --project <project> -- <argv…>`.
    public static func routedCommand(helper: String, project: String, argv: [String]) -> [String] {
        [helper, "--stdio", "--project", project, "--"] + argv
    }

    public static func refusedCommand(helper: String, name: String) -> [String] {
        [helper, "--stdio", "--refuse", name]
    }

    /// How a local server's command will run.
    public enum Route: Sendable, Equatable {
        /// In the project's container through the helper.
        case container(project: String?)
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

    /// Overrides for every local server in BelloCode's isolated global configuration: each becomes the helper's
    /// refusal (keeping `disabled`). `problems` names files that exist but could not be read (their servers cannot be
    /// overridden; the isolation self-check then reports them from opencode's own loaded configuration).
    public static func globalOverrides(configDirectory: URL, helper: String) -> (servers: [String: JSONValue], problems: [String]) {
        var servers: [String: JSONValue] = [:]
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
            for (server, entry) in entries where entry["type"]?.stringValue == "local" {
                var replacement: [String: JSONValue] = [
                    "type": .string("local"),
                    "command": .array(refusedCommand(helper: helper, name: server).map(JSONValue.string)),
                ]
                if let disabled = entry["disabled"] { replacement["disabled"] = disabled }
                servers[server] = .object(replacement)
            }
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
