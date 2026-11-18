import ContainerKit
import Foundation

/// An MCP server configured for every project (Settings ▸ MCP Servers; docs/features/containers.md "Global MCP
/// servers"). Three kinds, none of which runs anything on the Mac:
///
/// - **remote**: a streamable-HTTP or SSE endpoint (`url`) with optional headers. This is also how a company MCP
///   gateway plugs in: one entry with the gateway's URL and its auth header.
/// - **image**: a stdio server from a container image, the equivalent of `docker run -i --rm IMAGE ARGS`, run by
///   `bellocode-exec --stdio --mcp <id>` in its own BelloCode-managed container with no project folder mounted.
/// - **stack**: a compose file started as a BelloCode-managed stack on its own network; its MCP endpoint (service,
///   port, path) is forwarded to the Mac's loopback and registered as a remote server.
///
/// Secret header and variable values are never part of this value (the store holds it as an app preference): they
/// live in the Keychain (`GlobalMCPSecrets`) and are read only when the server is registered with opencode.
public struct GlobalMCPServer: Codable, Sendable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Hashable {
        case remote, image, stack

        public var title: String {
            switch self {
            case .remote: "Remote endpoint"
            case .image: "Container image"
            case .stack: "Compose stack"
            }
        }
    }

    /// Stable identity (names Keychain items, containers and the stack): lowercase letters, digits and `-`.
    public var id: String
    /// The name opencode knows it by (tools appear as `<name>_<tool>`).
    public var name: String
    public var enabled: Bool
    public var kind: Kind
    public var remote: RemoteMCPSetting?
    public var image: ImageMCPSetting?
    public var stack: StackMCPSetting?
    /// Where an imported server came from ("Cursor (~/.cursor/mcp.json)"), for the pane.
    public var source: String?

    public init(id: String = GlobalMCPServer.makeID(), name: String, enabled: Bool = true, kind: Kind, remote: RemoteMCPSetting? = nil,
                image: ImageMCPSetting? = nil, stack: StackMCPSetting? = nil, source: String? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.kind = kind
        self.remote = remote
        self.image = image
        self.stack = stack
        self.source = source
    }

    public static func remote(_ name: String, url: String, headers: [MCPKeyValue] = []) -> GlobalMCPServer {
        GlobalMCPServer(name: name, kind: .remote, remote: RemoteMCPSetting(url: url, headers: headers))
    }

    public static func image(_ name: String, _ setting: ImageMCPSetting) -> GlobalMCPServer {
        GlobalMCPServer(name: name, kind: .image, image: setting)
    }

    public static func stack(_ name: String, _ setting: StackMCPSetting) -> GlobalMCPServer {
        GlobalMCPServer(name: name, kind: .stack, stack: setting)
    }

    public static func makeID() -> String { String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(10)) }

    /// Every entry whose value is kept in the Keychain (header or variable name → account).
    public var secretEntries: [(field: MCPKeyValue, account: String)] {
        switch kind {
        case .remote: (remote?.headers ?? []).filter(\.secret).map { ($0, GlobalMCPSecrets.account(server: id, header: $0.name)) }
        case .image: (image?.environment ?? []).filter(\.secret).map { ($0, GlobalMCPSecrets.account(server: id, variable: $0.name)) }
        case .stack: []
        }
    }

    /// Problems with the setting, phrased for the pane; empty when valid.
    public func validationErrors() -> [String] {
        var errors: [String] = []
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if name.isEmpty || name.unicodeScalars.contains(where: { !allowed.contains($0) }) || name.count > 48 {
            errors.append("MCP server name “\(name)”: use letters, digits, - and _ (at most 48).")
        }
        switch kind {
        case .remote:
            guard let remote else { return errors + ["“\(name)” has no endpoint."] }
            errors += remote.validationErrors(server: name)
        case .image:
            guard let image else { return errors + ["“\(name)” has no image."] }
            errors += image.validationErrors(server: name)
        case .stack:
            guard let stack else { return errors + ["“\(name)” has no compose file."] }
            errors += stack.validationErrors(server: name)
        }
        return errors
    }

    /// One line describing where it runs (rows in the pane).
    public var summary: String {
        switch kind {
        case .remote: remote?.url ?? ""
        case .image: ([image?.image ?? ""] + (image?.args ?? [])).joined(separator: " ")
        case .stack: stack.map { ($0.composeFile.map { ($0 as NSString).abbreviatingWithTildeInPath + " · " } ?? "") + "\($0.service):\($0.port)\($0.path)" } ?? ""
        }
    }
}

/// A header or variable. A secret one has no `value` here: it is in the Keychain.
public struct MCPKeyValue: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var name: String
    /// The value when not secret; always nil for secrets (the store never holds one).
    public var value: String?
    public var secret: Bool
    public var id: String { name }

    public init(name: String, value: String? = nil, secret: Bool = false) {
        self.name = name
        self.value = secret ? nil : value
        self.secret = secret
    }

    /// Names that usually carry credentials; import and the editor mark these secret by default.
    public static func looksSecret(_ name: String) -> Bool {
        let upper = name.uppercased()
        if ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "APIKEY", "CREDENTIAL", "COOKIE"].contains(where: { upper.contains($0) }) { return true }
        let words = Set(upper.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return !words.isDisjoint(with: ["KEY", "PAT", "AUTH", "AUTHORIZATION", "SESSION", "PASS", "PWD"])
    }
}

/// A remote MCP endpoint (streamable HTTP; opencode falls back to SSE). TLS is verified by opencode against the
/// system's and the enterprise bundle's roots (`NODE_EXTRA_CA_CERTS`, Corporate network).
public struct RemoteMCPSetting: Codable, Sendable, Equatable, Hashable {
    public var url: String
    public var headers: [MCPKeyValue]

    public init(url: String, headers: [MCPKeyValue] = []) {
        self.url = url
        self.headers = headers
    }

    public func validationErrors(server: String) -> [String] {
        var errors: [String] = []
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), parsed.host() != nil else {
            return ["“\(server)”: the endpoint must be an http(s) URL."]
        }
        if scheme != "https" && scheme != "http" { errors.append("“\(server)”: the endpoint must be an http(s) URL.") }
        if scheme == "http", !Self.isLoopback(parsed.host() ?? "") {
            errors.append("“\(server)”: plain http is allowed only for this Mac (127.0.0.1, localhost); use https.")
        }
        for header in headers where header.name.isEmpty || header.name.contains(where: { $0 == ":" || $0.isWhitespace }) {
            errors.append("“\(server)”: “\(header.name)” is not a valid header name.")
        }
        return errors
    }

    static func isLoopback(_ host: String) -> Bool { host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]" }
}

/// A stdio MCP server run from an image (`docker run -i --rm IMAGE ARGS`). No project folder is mounted; explicit
/// mounts are listed with their access and are off by default.
public struct ImageMCPSetting: Codable, Sendable, Equatable, Hashable {
    public var image: String
    /// `--entrypoint` (nil: the image's).
    public var entrypoint: [String]?
    /// Arguments after the image (replace the image's CMD, as with `docker run`).
    public var args: [String]
    public var environment: [MCPKeyValue]
    public var mounts: [UserMount]
    public var network: ImageMCPSpec.Network
    /// One container for every project (exec per connection; the image needs /bin/sh). Off: a container per project
    /// connection, removed when the connection ends.
    public var shared: Bool
    /// A shared container stops after this many minutes without a connection (0 = never).
    public var idleStopMinutes: Int

    public init(image: String, entrypoint: [String]? = nil, args: [String] = [], environment: [MCPKeyValue] = [], mounts: [UserMount] = [],
                network: ImageMCPSpec.Network = .bridge, shared: Bool = false, idleStopMinutes: Int = 15) {
        self.image = image
        self.entrypoint = entrypoint
        self.args = args
        self.environment = environment
        self.mounts = mounts
        self.network = network
        self.shared = shared
        self.idleStopMinutes = idleStopMinutes
    }

    public func validationErrors(server: String) -> [String] {
        var errors: [String] = []
        if image.isEmpty || image.contains(where: \.isWhitespace) { errors.append("“\(server)”: the image reference is empty or has spaces.") }
        for variable in environment {
            let name = variable.name
            if name.isEmpty || name.contains("=") || name.first?.isNumber == true { errors.append("“\(server)”: “\(name)” is not a valid variable name.") }
            if name.hasPrefix("BUN_") || name.hasPrefix("BELLOCODE_") { errors.append("“\(server)”: \(name) cannot be set.") }
        }
        for mount in mounts where !RancherFileSharing.isShared(mount.path) {
            errors.append("“\(server)”: \(mount.path) is not shared with Rancher Desktop.")
        }
        return errors
    }
}

/// A compose stack exposing an MCP endpoint, run by Rancher Desktop's `docker compose` (full compose spec): an existing
/// compose file on this Mac (`composeFile`, its folder is the project directory, so builds and `env_file` work) or one
/// written here (`composeYAML`). Features that reach past the containers (privileged, capabilities, devices, host
/// namespaces, bind mounts) run only with `allowElevated`; the container engine's socket never does.
public struct StackMCPSetting: Codable, Sendable, Equatable, Hashable {
    public var composeYAML: String
    /// An existing compose file (absolute path); when set, `composeYAML` is not used.
    public var composeFile: String?
    /// The service, container port and path of the MCP endpoint (`mcp`, 8080, `/mcp`).
    public var service: String
    public var port: Int
    public var path: String
    /// The loopback port last used on the Mac (kept so opencode's URL stays the same across launches).
    public var hostPort: Int?
    /// Stop the stack after this many minutes without a connection (0 = never).
    public var idleStopMinutes: Int
    /// Run as written: allow the elevated features the file asks for (listed in the pane).
    public var allowElevated: Bool

    public init(composeYAML: String = "", composeFile: String? = nil, service: String, port: Int, path: String = "/mcp", hostPort: Int? = nil,
                idleStopMinutes: Int = 30, allowElevated: Bool = false) {
        self.composeYAML = composeYAML
        self.composeFile = composeFile
        self.service = service
        self.port = port
        self.path = path
        self.hostPort = hostPort
        self.idleStopMinutes = idleStopMinutes
        self.allowElevated = allowElevated
    }

    enum CodingKeys: String, CodingKey { case composeYAML, composeFile, service, port, path, hostPort, idleStopMinutes, allowElevated }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        composeYAML = try c.decodeIfPresent(String.self, forKey: .composeYAML) ?? ""
        composeFile = try c.decodeIfPresent(String.self, forKey: .composeFile)
        service = try c.decode(String.self, forKey: .service)
        port = try c.decode(Int.self, forKey: .port)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? "/mcp"
        hostPort = try c.decodeIfPresent(Int.self, forKey: .hostPort)
        idleStopMinutes = try c.decodeIfPresent(Int.self, forKey: .idleStopMinutes) ?? 30
        allowElevated = try c.decodeIfPresent(Bool.self, forKey: .allowElevated) ?? false
    }

    /// Checks that need no runtime; the file itself is checked by `docker compose config` when the stack is prepared.
    public func validationErrors(server: String) -> [String] {
        var errors: [String] = []
        if !(1...65535).contains(port) { errors.append("“\(server)”: the endpoint port must be 1–65535.") }
        if !path.hasPrefix("/") { errors.append("“\(server)”: the endpoint path must start with /.") }
        if service.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("“\(server)”: name the endpoint's service.") }
        if let composeFile {
            if !composeFile.hasPrefix("/") || !FileManager.default.fileExists(atPath: composeFile) {
                errors.append("“\(server)”: the compose file \(composeFile) does not exist.")
            }
        } else if composeYAML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("“\(server)”: choose a compose file or write one.")
        }
        return errors
    }
}

/// Keychain accounts of global MCP secrets (service `app.bellocode.mcp`).
public enum GlobalMCPSecrets {
    public static let service = "app.bellocode.mcp"
    public static func account(server: String, header: String) -> String { "\(server)/header/\(header)" }
    public static func account(server: String, variable: String) -> String { "\(server)/env/\(variable)" }
}

/// The app-wide list (Settings ▸ MCP Servers), stored as an app preference (no migration).
public struct GlobalMCPList: Codable, Sendable, Equatable {
    public var servers: [GlobalMCPServer]
    public init(servers: [GlobalMCPServer] = []) { self.servers = servers }
    public static let preferenceKey = "mcp.global"
}
