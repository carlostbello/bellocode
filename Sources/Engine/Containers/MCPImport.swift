import BelloCore
import ContainerKit
import Foundation
import OpenCodeKit

/// Import of MCP servers from the configuration files of tools the person already uses (Settings ▸ MCP Servers ▸
/// Import…; docs/features/containers.md "Import"). Strictly read-only, and only when the person asks: each file is read
/// with `FileManager.contents`, never written, watched or kept. `docker run` stdio servers become image servers, URL
/// servers remote ones; everything else is listed with the reason it cannot be converted. Nothing is saved or enabled
/// until the person reviews the list and adds what they chose.
public enum MCPImport {
    public enum Format: String, Sendable, CaseIterable, Hashable {
        /// `opencode.json(c)` / `config.json`: `mcp.servers.<name>` (2.x) or `mcp.<name>` (1.x).
        case opencode
        /// `claude_desktop_config.json`: `mcpServers.<name>` with `command`/`args`/`env`.
        case claudeDesktop
        /// `~/.claude.json`: `mcpServers.<name>` with `type` stdio/http/sse.
        case claudeCode
        /// `~/.cursor/mcp.json`: `mcpServers.<name>`.
        case cursor
        /// VS Code `mcp.json`: `servers.<name>` with `type`, `${input:…}` placeholders.
        case vscode
    }

    public struct Source: Sendable, Equatable, Identifiable, Hashable {
        public var title: String
        public var url: URL
        public var format: Format
        public var id: String { url.path }
        public init(title: String, url: URL, format: Format) {
            self.title = title
            self.url = url
            self.format = format
        }
        /// The path with `~` for the home folder (for the review list).
        public var displayPath: String {
            let home = NSHomeDirectory()
            return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        }
    }

    /// The places these tools keep their user-level MCP configuration on macOS.
    public static func standardSources(home: URL = URL(filePath: NSHomeDirectory())) -> [Source] {
        let support = home.appending(path: "Library/Application Support")
        return [
            Source(title: "opencode", url: home.appending(path: ".config/opencode/opencode.json"), format: .opencode),
            Source(title: "opencode", url: home.appending(path: ".config/opencode/opencode.jsonc"), format: .opencode),
            Source(title: "opencode", url: home.appending(path: ".config/opencode/config.json"), format: .opencode),
            Source(title: "Claude Desktop", url: support.appending(path: "Claude/claude_desktop_config.json"), format: .claudeDesktop),
            Source(title: "Claude Code", url: home.appending(path: ".claude.json"), format: .claudeCode),
            Source(title: "Cursor", url: home.appending(path: ".cursor/mcp.json"), format: .cursor),
            Source(title: "VS Code", url: support.appending(path: "Code/User/mcp.json"), format: .vscode),
        ]
    }

    /// One server found, converted or not.
    public struct Candidate: Sendable, Identifiable {
        public var id: String
        public var source: String
        public var name: String
        /// The converted server (nil: cannot be converted, see `refusal`).
        public var server: GlobalMCPServer?
        /// Secret values found in the file, by Keychain account (moved to the Keychain only if the person adds it).
        public var secrets: [String: SecretValue]
        /// Mounts from `-v` (never applied unless the person includes them after review).
        public var mounts: [UserMount]
        public var notes: [String]
        public var refusal: String?

        public var isConvertible: Bool { server != nil }
    }

    /// Reads one file (read-only). A missing file yields nothing; an unreadable one a single refusal row.
    public static func read(_ source: Source, existingNames: Set<String> = []) -> [Candidate] {
        guard let data = FileManager.default.contents(atPath: source.url.path) else { return [] }
        return parse(data, format: source.format, source: "\(source.title) (\(source.displayPath))", existingNames: existingNames)
    }

    /// Every standard source that exists, read on demand.
    public static func readAll(home: URL = URL(filePath: NSHomeDirectory()), existingNames: Set<String> = []) -> [Candidate] {
        var names = existingNames
        var all: [Candidate] = []
        for source in standardSources(home: home) {
            let found = read(source, existingNames: names)
            names.formUnion(found.compactMap { $0.server?.name })
            all += found
        }
        return all
    }

    public static func parse(_ data: Data, format: Format, source: String, existingNames: Set<String> = []) -> [Candidate] {
        let text = String(decoding: data, as: UTF8.self)
        guard let root = try? JSONValue.parse(Data((format == .opencode || format == .vscode ? JSONC.strip(text) : text).utf8)) else {
            return [Candidate(id: source, source: source, name: "(file)", server: nil, secrets: [:], mounts: [], notes: [],
                              refusal: "The file is not valid JSON, so nothing could be read from it.")]
        }
        var entries: [(String, JSONValue)] = []
        switch format {
        case .opencode:
            if case .object(let servers)? = root["mcp"]?["servers"] {
                entries = servers.sorted { $0.key < $1.key }
            } else if case .object(let servers)? = root["mcp"] {
                entries = servers.filter { $0.value["type"] != nil }.sorted { $0.key < $1.key }
            }
        case .claudeDesktop, .claudeCode, .cursor:
            if case .object(let servers)? = root["mcpServers"] { entries = servers.sorted { $0.key < $1.key } }
        case .vscode:
            if case .object(let servers)? = root["servers"] { entries = servers.sorted { $0.key < $1.key } }
            else if case .object(let servers)? = root["mcp"]?["servers"] { entries = servers.sorted { $0.key < $1.key } }
        }
        var taken = existingNames
        return entries.map { name, entry in
            var candidate = convert(name: name, entry: entry, format: format, source: source, taken: taken)
            if let server = candidate.server { taken.insert(server.name) }
            candidate.id = "\(source)/\(name)"
            return candidate
        }
    }

    /// A value that is a reference rather than the secret itself (`${input:token}`, `${env:TOKEN}`, `{env:X}`).
    static func isPlaceholder(_ value: String) -> Bool {
        value.contains("${") || (value.hasPrefix("{env:") && value.hasSuffix("}")) || value.hasPrefix("{file:")
    }

    static func sanitize(_ name: String, taken: Set<String>) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var clean = String(String.UnicodeScalarView(name.unicodeScalars.map { allowed.contains($0) ? $0 : "-" })).prefix(44).description
        if clean.isEmpty { clean = "server" }
        var candidate = clean
        var counter = 2
        while taken.contains(candidate) {
            candidate = "\(clean)-\(counter)"
            counter += 1
        }
        return candidate
    }

    static func convert(name: String, entry: JSONValue, format: Format, source: String, taken: Set<String>) -> Candidate {
        var candidate = Candidate(id: name, source: source, name: name, server: nil, secrets: [:], mounts: [], notes: [], refusal: nil)
        let type = entry["type"]?.stringValue
        if entry["disabled"]?.boolValue == true || entry["enabled"]?.boolValue == false { candidate.notes.append("Turned off in \(source).") }
        let url = entry["url"]?.stringValue ?? entry["serverUrl"]?.stringValue
        var argv: [String] = []
        if case .array(let items)? = entry["command"] {
            argv = items.compactMap(\.stringValue)
        } else if let command = entry["command"]?.stringValue {
            argv = [command]
            if case .array(let items)? = entry["args"] { argv += items.compactMap(\.stringValue) }
        }
        var env: [String: String] = [:]
        for key in ["environment", "env"] {
            if case .object(let values)? = entry[key] { env.merge(values.compactMapValues(\.stringValue)) { a, _ in a } }
        }
        if let url, type != "local", type != "stdio" {
            var headers: [MCPKeyValue] = []
            var secrets: [String: SecretValue] = [:]
            let id = GlobalMCPServer.makeID()
            if case .object(let values)? = entry["headers"] {
                for (header, value) in values.sorted(by: { $0.key < $1.key }) {
                    let text = value.stringValue ?? ""
                    let secret = MCPKeyValue.looksSecret(header) || header.lowercased() == "authorization" || isPlaceholder(text)
                    headers.append(MCPKeyValue(name: header, value: secret ? nil : text, secret: secret))
                    if secret, !text.isEmpty, !isPlaceholder(text) {
                        secrets[GlobalMCPSecrets.account(server: id, header: header)] = SecretValue(text)
                    } else if secret {
                        candidate.notes.append("Enter the value of the header \(header) (the file refers to it as \(text.isEmpty ? "empty" : text)).")
                    }
                }
            }
            if let oauth = entry["oauth"], oauth.boolValue != false {
                candidate.notes.append("OAuth settings are not imported: opencode signs in when the server asks for it.")
            }
            var server = GlobalMCPServer(id: id, name: sanitize(name, taken: taken), kind: .remote,
                                         remote: RemoteMCPSetting(url: url, headers: headers), source: source)
            server.enabled = true
            if let problem = server.remote?.validationErrors(server: server.name).first {
                candidate.refusal = problem
                return candidate
            }
            candidate.server = server
            candidate.secrets = secrets
            return candidate
        }
        guard !argv.isEmpty else {
            candidate.refusal = "It names neither a command nor a URL."
            return candidate
        }
        let program = (argv[0] as NSString).lastPathComponent
        if ["docker", "podman", "nerdctl"].contains(program), argv.count > 1, argv[1] == "compose" {
            candidate.refusal = "It starts a compose project. Add the compose file as a compose-stack server instead."
            return candidate
        }
        guard DockerRunCommand.isDockerRun(argv) else {
            candidate.refusal = "It runs \(program) on this Mac, and BelloCode never runs MCP servers on the Mac. Use a container image of the server, or add it to a project (it then runs in that project's container)."
            return candidate
        }
        let run: DockerRunCommand
        do {
            run = try DockerRunCommand.parse(argv)
        } catch {
            candidate.refusal = "Its docker run options cannot be converted: \(error.description)."
            return candidate
        }
        let id = GlobalMCPServer.makeID()
        var variables: [MCPKeyValue] = []
        var secrets: [String: SecretValue] = [:]
        func add(_ variable: String, value: String?) {
            let secret = MCPKeyValue.looksSecret(variable) || (value.map(isPlaceholder) ?? false)
            variables.append(MCPKeyValue(name: variable, value: secret ? nil : (value ?? ""), secret: secret))
            if secret, let value, !value.isEmpty, !isPlaceholder(value) {
                secrets[GlobalMCPSecrets.account(server: id, variable: variable)] = SecretValue(value)
            } else if secret {
                candidate.notes.append("Enter the value of \(variable)\(value.map { " (the file refers to it as \($0))" } ?? "").")
            } else if value == nil {
                candidate.notes.append("\(variable) has no value in the file; set it after import.")
            }
        }
        for (variable, value) in run.environment.sorted(by: { $0.key < $1.key }) { add(variable, value: value) }
        for variable in run.passthrough { add(variable, value: env[variable]) }
        candidate.mounts = run.mounts.map { UserMount(path: ($0.source as NSString).expandingTildeInPath, readOnly: $0.readOnly) }
        for mount in run.mounts {
            candidate.notes.append("Mounts \(mount.source) at \(mount.target) (\(mount.readOnly ? "read-only" : "read and write")): not included unless you choose it. BelloCode mounts folders at the same path.")
        }
        candidate.notes += run.notes
        let setting = ImageMCPSetting(image: run.image, entrypoint: run.entrypoint, args: run.args, environment: variables,
                                      network: run.network == "none" ? .none : .bridge)
        candidate.server = GlobalMCPServer(id: id, name: sanitize(name, taken: taken), kind: .image, image: setting, source: source)
        candidate.secrets = secrets
        return candidate
    }
}
