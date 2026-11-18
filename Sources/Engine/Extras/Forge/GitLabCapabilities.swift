import Foundation

// Version, edition and token detection for one GitLab instance (docs/features/gitlab.md, "Capability gating"). The
// enterprise's version and tier are unknown, so nothing assumes them: the version comes from `GET /version` when the
// token may read it, features are gated by minimum version where GitLab documents one, and otherwise probed (a 404 on
// an optional endpoint marks it unavailable). An older or unknown instance degrades feature by feature; it never fails
// as a whole.

/// A GitLab release ("16.11.2-ee").
public struct GitLabVersion: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// As GitLab reported it.
    public var raw: String

    public init(major: Int, minor: Int, patch: Int = 0, raw: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.raw = raw ?? "\(major).\(minor).\(patch)"
    }

    /// "16.11.2-ee", "17.5.0-pre", "15.0.0".
    public init?(_ text: String) {
        let core = text.split(whereSeparator: { $0 == "-" || $0 == "+" || $0 == " " }).first.map(String.init) ?? text
        let parts = core.split(separator: ".").map { Int($0) }
        guard parts.count >= 2, let major = parts[0], let minor = parts[1] else { return nil }
        self.init(major: major, minor: minor, patch: parts.count > 2 ? parts[2] ?? 0 : 0, raw: text)
    }

    public var description: String { "\(major).\(minor)" + (patch > 0 ? ".\(patch)" : "") }
    /// Releases compare by number; the raw text ("-ee", "-pre") does not make two equal releases different.
    public static func == (lhs: Self, rhs: Self) -> Bool { (lhs.major, lhs.minor, lhs.patch) == (rhs.major, rhs.minor, rhs.patch) }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch) }
}

/// Features BelloCode gates. Each names the first GitLab version that offers it (when GitLab documents one) and whether
/// an edition or licence matters.
public enum GitLabFeature: String, CaseIterable, Sendable, Codable {
    /// `GET /personal_access_tokens/self`: scopes and expiry of the token (15.5).
    case tokenIntrospection
    /// `detailed_merge_status` on merge requests (15.6; older instances have `merge_status`).
    case detailedMergeStatus
    /// `reviewers` on merge requests (13.8).
    case reviewers
    /// The `draft` field (14.0; older instances use `work_in_progress`).
    case draftField
    /// Required approval rules and Code Owners (`/approval_state`): Premium/Ultimate only. Free has optional approvals.
    case approvalRules
    /// Byte ranges on job logs (`Range: bytes=-N` answered 206): never documented, probed per instance.
    case jobLogRange
    /// Draft notes on merge requests (`M/draft_notes`, `bulk_publish`): a review sent as one. Probed (GitLab 2).
    case draftNotes
    /// Merge request dependencies (`M/blocks`): Premium/Ultimate. Probed; CE is unavailable.
    case mergeRequestDependencies
    /// Project approval settings (`/projects/:P/approvals`: reset on push, author approval): Premium/Ultimate.
    case approvalSettings
    /// Merge requests related to an issue (`issues/:iid/related_merge_requests`).
    case relatedMergeRequests

    public var minimum: GitLabVersion? {
        switch self {
        case .tokenIntrospection: GitLabVersion(major: 15, minor: 5)
        case .detailedMergeStatus: GitLabVersion(major: 15, minor: 6)
        case .reviewers: GitLabVersion(major: 13, minor: 8)
        case .draftField: GitLabVersion(major: 14, minor: 0)
        case .approvalRules, .jobLogRange, .draftNotes, .mergeRequestDependencies, .approvalSettings, .relatedMergeRequests: nil
        }
    }

    public var title: String {
        switch self {
        case .tokenIntrospection: "Token scopes and expiry"
        case .detailedMergeStatus: "Detailed merge status"
        case .reviewers: "Reviewers"
        case .draftField: "Draft field"
        case .approvalRules: "Required approval rules and Code Owners"
        case .jobLogRange: "Partial job log loading"
        case .draftNotes: "Draft review comments"
        case .mergeRequestDependencies: "Merge request dependencies"
        case .approvalSettings: "Project approval settings"
        case .relatedMergeRequests: "Related merge requests of issues"
        }
    }
}

public enum GitLabFeatureSupport: Hashable, Sendable {
    case available
    case unavailable(String)
    /// Not known yet: try it, and treat a 404 as unavailable.
    case unknown

    public var isAvailable: Bool { self == .available }
    public var mayTry: Bool { if case .unavailable = self { false } else { true } }
}

/// What BelloCode knows about one instance's capabilities. Persisted (`app_gitlab_instance`), refreshed at launch and
/// from Settings ▸ GitLab ▸ Test.
public struct GitLabCapabilities: Hashable, Sendable, Codable {
    /// nil: the version could not be read (older instance, or a token without access to `/version`).
    public var version: GitLabVersion?
    /// From `/version` (`-ee` suffix or `enterprise`); nil when unknown. Enterprise Edition does not mean a paid tier.
    public var enterprise: Bool?
    /// Per-feature probe results (a feature's raw value → whether the instance answered it).
    public var probed: [String: Bool]

    public init(version: GitLabVersion? = nil, enterprise: Bool? = nil, probed: [String: Bool] = [:]) {
        self.version = version
        self.enterprise = enterprise
        self.probed = probed
    }

    public func support(_ feature: GitLabFeature) -> GitLabFeatureSupport {
        if let result = probed[feature.rawValue] {
            return result ? .available : .unavailable("\(feature.title) is not offered by this instance.")
        }
        if let minimum = feature.minimum, let version {
            return version >= minimum ? .available : .unavailable("\(feature.title) needs GitLab \(minimum) (this instance runs \(version)).")
        }
        if feature == .approvalRules, enterprise == false {
            return .unavailable("Required approval rules need GitLab Premium; this instance is Community Edition (approvals are optional).")
        }
        if feature == .mergeRequestDependencies || feature == .approvalSettings, enterprise == false {
            return .unavailable("\(feature.title) need GitLab Premium; this instance is Community Edition.")
        }
        return .unknown
    }

    public mutating func record(_ feature: GitLabFeature, _ available: Bool) { probed[feature.rawValue] = available }

    /// "GitLab 16.11 (Enterprise Edition)", "GitLab version unknown".
    public var label: String {
        guard let version else { return "GitLab version unknown (capabilities are probed)" }
        return "GitLab \(version)" + (enterprise == true ? " (Enterprise Edition)" : enterprise == false ? " (Community Edition)" : "")
    }

    /// Parses `GET /version` (`{"version":"16.11.2-ee","revision":"…","enterprise":true}`).
    public static func parse(versionJSON object: [String: Any]) -> GitLabCapabilities {
        let raw = object["version"] as? String ?? ""
        let enterprise = object["enterprise"] as? Bool ?? (raw.isEmpty ? nil : raw.lowercased().contains("-ee"))
        return GitLabCapabilities(version: GitLabVersion(raw), enterprise: enterprise)
    }
}

/// The access token's metadata (`GET /personal_access_tokens/self`). Never the token itself.
public struct GitLabTokenInfo: Hashable, Sendable, Codable {
    public var name: String?
    /// nil: GitLab did not say (older version, a token type without introspection): unknown, not "none".
    public var scopes: [String]?
    /// The day the token stops working (GitLab expires it at 00:00 UTC of this day); nil: unknown or no expiry.
    public var expiresAt: Date?
    /// GitLab said explicitly that the token never expires.
    public var neverExpires: Bool
    public var active: Bool?

    public init(name: String? = nil, scopes: [String]? = nil, expiresAt: Date? = nil, neverExpires: Bool = false, active: Bool? = nil) {
        self.name = name
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.neverExpires = neverExpires
        self.active = active
    }

    public static func parse(_ object: [String: Any]) -> GitLabTokenInfo {
        var expires: Date?
        var never = false
        if let text = object["expires_at"] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            expires = formatter.date(from: String(text.prefix(10)))
        } else if object.keys.contains("expires_at") {
            never = true
        }
        return GitLabTokenInfo(
            name: object["name"] as? String, scopes: object["scopes"] as? [String], expiresAt: expires, neverExpires: never,
            active: (object["active"] as? Bool).map { $0 && (object["revoked"] as? Bool) != true })
    }

    /// Whether the token may make changes (`api` scope). nil: unknown (introspection unavailable).
    public var allowsWrites: Bool? { scopes.map { $0.contains("api") } }
    /// Whether the token may read merge requests and pipelines.
    public var allowsReads: Bool? { scopes.map { $0.contains("api") || $0.contains("read_api") } }

    public enum ExpiryWarning: Hashable, Sendable {
        case expired
        /// Days left, at the 30, 7 and 1 day thresholds.
        case soon(days: Int)

        public var text: String {
            switch self {
            case .expired: "The GitLab token has expired. Create a new one and choose Replace Token."
            case .soon(let days): days <= 1 ? "The GitLab token expires within a day." : "The GitLab token expires in \(days) days."
            }
        }

        /// 0 at 30 days, 1 at 7, 2 at 1 day or expired: a banner escalates with it.
        public var level: Int {
            switch self {
            case .expired: 2
            case .soon(let days): days <= 1 ? 2 : days <= 7 ? 1 : 0
            }
        }
    }

    /// A warning from 30 days before expiry; nil when far, unknown or non-expiring.
    public func expiryWarning(now: Date) -> ExpiryWarning? {
        if active == false { return .expired }
        guard let expiresAt else { return nil }
        let seconds = expiresAt.timeIntervalSince(now)
        if seconds <= 0 { return .expired }
        let days = Int((seconds / 86_400).rounded(.up))
        return days <= 30 ? .soon(days: days) : nil
    }

    /// "Scopes: api, read_api · expires 2026-12-01", "Scopes unknown (GitLab older than 15.5)".
    public var label: String {
        var parts: [String] = []
        if let scopes { parts.append("Scopes: " + (scopes.isEmpty ? "none" : scopes.sorted().joined(separator: ", "))) } else {
            parts.append("Scopes unknown")
        }
        if let expiresAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            parts.append("expires \(formatter.string(from: expiresAt))")
        } else if neverExpires {
            parts.append("no expiry date")
        } else {
            parts.append("expiry unknown")
        }
        return parts.joined(separator: " · ")
    }
}

/// What BelloCode last learned about an instance (persisted; never a secret).
public struct GitLabInstanceStatus: Hashable, Sendable, Codable {
    public var user: String?
    public var capabilities: GitLabCapabilities
    public var token: GitLabTokenInfo?
    public var checked: Date?

    public init(user: String? = nil, capabilities: GitLabCapabilities = GitLabCapabilities(), token: GitLabTokenInfo? = nil, checked: Date? = nil) {
        self.user = user
        self.capabilities = capabilities
        self.token = token
        self.checked = checked
    }
}

/// Per-instance switches the person controls (Settings ▸ GitLab). Defaults are the owner-decision defaults: reads
/// only; write actions off (the token may then be `read_api`); approve and merge off, user-only, with SHA checks.
public struct GitLabInstanceSettings: Hashable, Sendable, Codable {
    /// Create merge requests, edit title/description, reply, resolve, retry and play jobs (needs the `api` scope).
    public var writesEnabled: Bool
    /// Approve and Merge buttons in the panel (person only, never agents; each checks the reviewed SHA).
    public var approveAndMergeEnabled: Bool

    public init(writesEnabled: Bool = false, approveAndMergeEnabled: Bool = false) {
        self.writesEnabled = writesEnabled
        self.approveAndMergeEnabled = approveAndMergeEnabled
    }
}
