import BelloCore
import Foundation

/// How a managed secret may be used (docs/features/secrets.md). The mode is the claim BelloCode makes about it.
public enum SecretUseMode: String, Codable, Sendable, CaseIterable, Hashable {
    /// Only BelloCode uses the value, for a named built-in operation (GitLab API, git credentials, the brokered HTTP
    /// tool). The agent gets a handle; results are scanned before the agent sees them.
    case brokered
    /// The agent and its programs get an opaque placeholder (`bcsec_…`); BelloCode's egress proxy swaps the real value
    /// in only for the secret's bound destinations and scans what comes back.
    case placeholder
    /// The agent receives the value itself (labelled "The agent can see this value"; confirmed the first time).
    case visible

    public var title: String {
        switch self {
        case .brokered: "Brokered"
        case .placeholder: "Placeholder"
        case .visible: "Visible"
        }
    }

    /// Whether BelloCode claims the agent cannot see the value in this mode.
    public var hiddenFromAgent: Bool { self != .visible }

    public var summary: String {
        switch self {
        case .brokered: "Only BelloCode uses it, for a named operation. The agent gets a handle."
        case .placeholder: "The agent's programs get a placeholder; BelloCode's proxy swaps the value in for bound destinations only."
        case .visible: "The agent receives the value itself."
        }
    }
}

/// Which threads may use a secret.
public enum SecretScope: Codable, Sendable, Hashable {
    /// Every project.
    case global
    /// One project (its root folder).
    case project(String)
    /// Projects inside the developer's configured code roots.
    case codeRoots

    public func admits(projectDirectory: String, codeRoots: [String]) -> Bool {
        switch self {
        case .global: true
        case .project(let root): Self.inside(projectDirectory, root)
        case .codeRoots: codeRoots.contains { Self.inside(projectDirectory, $0) }
        }
    }

    public var title: String {
        switch self {
        case .global: "All projects"
        case .project(let root): (root as NSString).lastPathComponent
        case .codeRoots: "Code roots"
        }
    }

    static func inside(_ path: String, _ root: String) -> Bool {
        let root = root.hasSuffix("/") && root.count > 1 ? String(root.dropLast()) : root
        return path == root || path.hasPrefix(root + "/")
    }
}

/// Where in a request the placeholder may appear (and so where the value is substituted).
public struct SecretLocation: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Hashable {
        /// A header whose whole value is `prefix + placeholder` (`Authorization: Bearer …`, `X-Api-Key: …`).
        case header
        /// A query parameter whose decoded value is exactly the placeholder.
        case query
        /// A JSON body (`application/json`) string field, by top-level key or dotted path, exactly the placeholder.
        case jsonField
        /// A form body (`application/x-www-form-urlencoded`) field exactly the placeholder.
        case formField
        /// `Authorization: Basic base64(user:placeholder)`: the password part.
        case basicAuthPassword
    }

    public var kind: Kind
    /// Header, parameter or field name (dotted path for JSON). Ignored for `basicAuthPassword`.
    public var name: String
    /// Header only: text before the placeholder, e.g. `Bearer `.
    public var prefix: String

    public init(_ kind: Kind, name: String = "", prefix: String = "") {
        self.kind = kind
        self.name = name
        self.prefix = prefix
    }

    public static func header(_ name: String, prefix: String = "") -> SecretLocation { .init(.header, name: name, prefix: prefix) }
    public static func query(_ name: String) -> SecretLocation { .init(.query, name: name) }
    public static func jsonField(_ name: String) -> SecretLocation { .init(.jsonField, name: name) }
    public static func formField(_ name: String) -> SecretLocation { .init(.formField, name: name) }
    public static let basicAuthPassword = SecretLocation(.basicAuthPassword)

    public var description: String {
        switch kind {
        case .header: "header \(name)" + (prefix.isEmpty ? "" : " (\(prefix.trimmingCharacters(in: .whitespaces)) …)")
        case .query: "query parameter \(name)"
        case .jsonField: "JSON field \(name)"
        case .formField: "form field \(name)"
        case .basicAuthPassword: "Basic auth password"
        }
    }
}

/// One destination a placeholder secret is bound to. The value is substituted only for a request whose scheme, host
/// and port match exactly, whose method and path are allowed, and whose placeholder sits in an allowed location.
public struct SecretBinding: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// `https` (default) or `http` (refused unless the host is loopback in tests: values never cross plain HTTP).
    public var scheme: String
    /// Exact host name, lower case. No wildcards: a wildcard binds hosts the agent may control.
    public var host: String
    public var port: Int
    /// Allowed methods (upper case); empty: any.
    public var methods: [String]
    /// Allowed path prefixes, each starting with `/` and matched on segment boundaries; empty: any path.
    public var pathPrefixes: [String]
    public var locations: [SecretLocation]
    public var expires: Date?
    /// The most substitutions allowed; nil: unlimited.
    public var maxUses: Int?

    public init(id: String = UUID().uuidString.lowercased(), scheme: String = "https", host: String, port: Int? = nil,
                methods: [String] = [], pathPrefixes: [String] = [], locations: [SecretLocation], expires: Date? = nil,
                maxUses: Int? = nil) {
        self.id = id
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.port = port ?? (scheme.lowercased() == "http" ? 80 : 443)
        self.methods = methods.map { $0.uppercased() }
        self.pathPrefixes = pathPrefixes
        self.locations = locations
        self.expires = expires
        self.maxUses = maxUses
    }

    /// `https://api.example.com` (port shown when not the default).
    public var origin: String {
        let defaultPort = scheme == "https" ? 443 : 80
        return "\(scheme)://\(host)" + (port == defaultPort ? "" : ":\(port)")
    }

    public func matchesOrigin(scheme: String, host: String, port: Int) -> Bool {
        self.scheme == scheme.lowercased() && self.host == Self.canonicalHost(host) && self.port == port
    }

    public func allows(method: String) -> Bool { methods.isEmpty || methods.contains(method.uppercased()) }

    /// `path` must already be normalised (`RequestPath.normalized`).
    public func allows(path: String) -> Bool {
        guard !pathPrefixes.isEmpty else { return true }
        return pathPrefixes.contains { prefix in
            if prefix == "/" { return true }
            let trimmed = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
            return path == trimmed || path.hasPrefix(trimmed + "/")
        }
    }

    /// Lower case, no trailing dot.
    public static func canonicalHost(_ host: String) -> String {
        var value = host.lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    /// Problems that make the binding unusable (shown in the editor).
    public func validationProblems() -> [String] {
        var problems: [String] = []
        if !["https", "http"].contains(scheme) { problems.append("Scheme must be https.") }
        if scheme == "http" { problems.append("Plain http would send the value unencrypted; use https.") }
        if host.isEmpty || host.contains("*") || host.contains("/") || host.contains(" ") {
            problems.append("Host must be one exact name (no wildcards).")
        }
        if !(1...65_535).contains(port) { problems.append("Port must be 1–65535.") }
        if locations.isEmpty { problems.append("Name at least one place the value may appear (a header, a parameter or a field).") }
        for location in locations where location.kind != .basicAuthPassword && location.name.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("Name the \(location.kind.rawValue).")
        }
        for prefix in pathPrefixes where !prefix.hasPrefix("/") { problems.append("Path prefixes start with /.") }
        return problems
    }
}

/// A secret the manager knows (never its value; the value is in the Keychain under `account`).
public struct ManagedSecret: Codable, Sendable, Hashable, Identifiable {
    public var id: String { account }
    /// Keychain account (`bcs_…`), stable across rotation.
    public var account: String
    /// The handle agents use (`{{secret:NAME}}`, environment variable for placeholders). Letters, digits and `_`.
    public var name: String
    public var label: String
    public var mode: SecretUseMode
    public var scope: SecretScope
    /// Placeholder mode, and the brokered HTTP tool: where the value may go.
    public var bindings: [SecretBinding]
    /// Brokered mode: the named operation (`http`, or a built-in such as `gitlab-api`).
    public var operation: String?
    public var created: Date
    public var rotated: Date?
    /// Visible mode: the person confirmed "the agent can see this value".
    public var visibleConfirmed: Bool
    /// Substitutions or brokered uses so far, per binding id.
    public var uses: [String: Int]
    /// Revoked secrets keep their audit but no use succeeds.
    public var revoked: Bool

    public init(account: String, name: String, label: String, mode: SecretUseMode, scope: SecretScope = .global,
                bindings: [SecretBinding] = [], operation: String? = nil, created: Date = Date(), rotated: Date? = nil,
                visibleConfirmed: Bool = false, uses: [String: Int] = [:], revoked: Bool = false) {
        self.account = account
        self.name = name
        self.label = label
        self.mode = mode
        self.scope = scope
        self.bindings = bindings
        self.operation = operation
        self.created = created
        self.rotated = rotated
        self.visibleConfirmed = visibleConfirmed
        self.uses = uses
        self.revoked = revoked
    }

    /// A usable handle from a label: `GitHub token` → `GITHUB_TOKEN`.
    public static func handle(from label: String) -> String {
        var out = ""
        var lastUnderscore = false
        for scalar in label.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                out.unicodeScalars.append(scalar)
                lastUnderscore = false
            } else if !lastUnderscore, !out.isEmpty {
                out.append("_")
                lastUnderscore = true
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        if out.isEmpty || out.first!.isNumber { out = "SECRET_" + out }
        return String(out.uppercased().prefix(48))
    }

    public static func isValidHandle(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !name.isEmpty, name.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")
        return name.unicodeScalars.allSatisfy(allowed.contains) && !CharacterSet.decimalDigits.contains(first)
            && !name.hasPrefix("BELLOCODE_") && !name.hasPrefix("BUN_")
            && !["PATH", "HOME", "SHELL", "USER", "TERM", "PWD", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY"]
                .contains(name.uppercased())
    }
}

/// The per-thread placeholder of a placeholder-mode secret. Not secret itself: a capability that works only through
/// BelloCode's proxy, for the secret's bindings.
public struct PlaceholderGrant: Codable, Sendable, Hashable, Identifiable {
    public var id: String { placeholder }
    public var placeholder: String
    public var account: String
    public var sessionID: String
    /// The project the thread belongs to (the proxy refuses it through another project's gateway).
    public var projectDirectory: String
    public var created: Date

    public init(placeholder: String, account: String, sessionID: String, projectDirectory: String, created: Date = Date()) {
        self.placeholder = placeholder
        self.account = account
        self.sessionID = sessionID
        self.projectDirectory = projectDirectory
        self.created = created
    }
}

/// One audited use or refusal (never a value; a placeholder is never stored either, only the secret).
public struct SecretAuditEntry: Codable, Sendable, Hashable, Identifiable {
    public enum Outcome: String, Codable, Sendable, Hashable {
        case substituted, brokered, refused, responseRedacted, responseBlocked, revealed, rotated, revoked, created
    }

    public var id: String
    public var account: String
    public var at: Date
    /// Origin and path (no query: queries can carry data).
    public var destination: String
    public var method: String
    public var sessionID: String?
    public var outcome: Outcome
    /// Short reason code or explanation (fixed text, never request content).
    public var detail: String
    public var status: Int?

    public init(id: String = UUID().uuidString.lowercased(), account: String, at: Date = Date(), destination: String, method: String = "",
                sessionID: String? = nil, outcome: Outcome, detail: String = "", status: Int? = nil) {
        self.id = id
        self.account = account
        self.at = at
        self.destination = destination
        self.method = method
        self.sessionID = sessionID
        self.outcome = outcome
        self.detail = detail
        self.status = status
    }
}

/// The exact guarantee the product states for hidden secrets (research 08 §4), shown in the info popover and the
/// feature note. One source of truth.
public enum SecretClaims {
    public static let hiddenHeadline = "The agent cannot see this value"
    public static let visibleHeadline = "The agent can see this value"
    public static let commandHeadline = "The command can reveal this value"

    public static let hiddenGuarantee = """
        BelloCode never supplies this value to the model or to any process the agent controls. It stays in your \
        Keychain; BelloCode itself sends it only to the secret's bound destinations, over TLS, and checks what comes \
        back before the agent sees it.
        """

    public static let hiddenLimits = """
        This holds provided BelloCode, macOS and the container VM, your Keychain and the bound destination are \
        trusted, and the destination's responses do not encode the value in a way BelloCode's scanner cannot detect \
        (it finds the value as is, base64, hex, URL- and JSON-encoded, after gzip, deflate or brotli). A destination \
        that transforms the value otherwise, a compromised Mac or proxy, and copies made before you saved it here are \
        outside this guarantee.
        """

    public static let visibleExplanation = """
        The agent receives the value itself. It can print, store or send it anywhere its commands can reach. Use \
        this only for values you would paste into the chat.
        """

    public static let commandExplanation = """
        A command given this value receives it and can print, encode, save or send it; its output goes back to the \
        agent. Approve only commands you trust with the value.
        """
}
