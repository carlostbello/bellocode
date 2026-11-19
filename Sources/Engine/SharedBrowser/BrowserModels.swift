import CryptoKit
import Foundation

/// A thread's place in the shared Chromium (docs/features/shared-browser.md "Multi-agent model"): its own named tab
/// group and default tab, keyed by the immutable opencode session ID (renames keep it; forks and children get their own).
public struct BrowserBinding: Codable, Sendable, Equatable, Hashable {
    public var sessionID: String
    public var project: String
    /// The browse group label (`bc-<8 hex>`), unique across threads.
    public var group: String
    /// The default tab every call without a `tab` goes to (`<group>-main`).
    public var mainTab: String
    /// The tab plain calls go to now (the main tab unless the thread selected another of its own or a shared one).
    public var selectedTab: String
    /// Tabs this thread created in its group (string IDs), newest last; bounded.
    public var tabs: [String]
    public var created: Date

    public init(sessionID: String, project: String, group: String, created: Date = .now) {
        self.sessionID = sessionID
        self.project = project
        self.group = group
        mainTab = BrowserNaming.mainTab(group: group)
        selectedTab = mainTab
        tabs = [mainTab]
        self.created = created
    }

    public static let maxTabs = 24

    public mutating func remember(_ tab: String) {
        tabs.removeAll { $0 == tab }
        tabs.append(tab)
        if tabs.count > Self.maxTabs { tabs.removeFirst(tabs.count - Self.maxTabs) }
        if !tabs.contains(mainTab) { tabs.insert(mainTab, at: 0) }
    }

    public func owns(_ tab: String) -> Bool { tabs.contains(tab) || tab == mainTab || tab.hasPrefix(group + "-") }
}

/// A tab one thread deliberately shared with another (recorded: who, which tab, when, until when). The person does it
/// (Use Shared Tab… in the Chrome panel); agents cannot grant themselves access.
public struct BrowserShare: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var ownerSession: String
    public var granteeSession: String
    public var tab: String
    public var created: Date
    public var expires: Date?

    public init(id: String = "share-" + UUID().uuidString.prefix(8).lowercased(), ownerSession: String, granteeSession: String, tab: String,
                created: Date = .now, expires: Date? = nil) {
        self.id = id
        self.ownerSession = ownerSession
        self.granteeSession = granteeSession
        self.tab = tab
        self.created = created
        self.expires = expires
    }

    public func isActive(at now: Date) -> Bool { expires.map { now < $0 } ?? true }
}

/// Names in the shared browser and the canonical project URLs.
public enum BrowserNaming {
    /// `bc-<8 hex of SHA-256(session)>`; `attempt` > 0 adds a suffix on the (unlikely) collision.
    public static func group(sessionID: String, attempt: Int = 0) -> String {
        let digest = SHA256.hash(data: Data(sessionID.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return attempt == 0 ? "bc-\(digest)" : "bc-\(digest)-\(attempt)"
    }

    public static func mainTab(group: String) -> String { "\(group)-main" }

    /// A browse tab ID: lowercase, starts with a letter, letters/digits/`-`/`_`, at most 64 characters.
    public static func isValidTabID(_ id: String) -> Bool {
        guard let first = id.first, first.isLetter, first.isLowercase, id.count <= 64 else { return false }
        return id.allSatisfy { ($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "-" || $0 == "_" } && id.allSatisfy(\.isASCII)
    }

    /// A tab ID the thread asked for, placed in its group (`<group>-<slug>`), or a numbered one.
    public static func tabID(group: String, requested: String?, existing: [String]) -> String {
        if let requested, isValidTabID(requested) {
            let candidate = requested.hasPrefix(group + "-") ? requested : "\(group)-\(requested)"
            if candidate.count <= 64 { return candidate }
        }
        var n = 2
        while existing.contains("\(group)-t\(n)") { n += 1 }
        return "\(group)-t\(n)"
    }

    /// A stable DNS label for a project (`https://<label>.bc:<port>/`): its folder name, lowercased, letters, digits
    /// and `-`; unique among `taken` (a numeric suffix otherwise).
    public static func projectLabel(directory: String, taken: Set<String>) -> String {
        let base = URL(filePath: directory).lastPathComponent.lowercased()
        var slug = String(base.map { ($0.isLetter || $0.isNumber) && $0.isASCII ? $0 : "-" })
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty || !(slug.first?.isLetter ?? false) { slug = "p" + (slug.isEmpty ? "" : "-" + slug) }
        slug = String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if !taken.contains(slug) { return slug }
        var n = 2
        while taken.contains("\(slug)-\(n)") { n += 1 }
        return "\(slug)-\(n)"
    }

    public static let suffix = "bc"

    /// The canonical URL of a project's dev server on a port: `https://<label>.bc:<port>/`.
    public static func projectURL(label: String, port: Int) -> String { "https://\(label).\(suffix):\(port)/" }
    /// The canonical URL of a project's service: `https://<service>.<label>.bc/` (443 maps to its declared port).
    public static func serviceURL(service: String, label: String) -> String { "https://\(service).\(label).\(suffix)/" }
}

/// The person's settings for the shared browser (Settings ▸ Browser ▸ Shared Chrome). Stored in user defaults
/// (`browser.shared.*`): no secrets.
public struct SharedBrowserSettings: Codable, Sendable, Equatable {
    /// Agents may use the shared Chrome at all (each project still needs the person's approval of the MCP server).
    public var enabled: Bool = true
    /// Stop the browser after this long without calls, viewers, handoffs or human control.
    public var idleMinutes: Int = 10
    /// Warn above this profile size (Docker named volumes have no byte quota; BelloCode measures and warns).
    public var profileLimitGiB: Int = 4
    /// The compact 1024×640 display (36% fewer pixels per full redraw), on request.
    public var compactDisplay: Bool = false
    /// Close a thread's disposable tabs when it ends (not shared or lent ones).
    public var closeTabsWhenDone: Bool = true

    public init() {}

    public static let defaultsKey = "browser.shared.settings"

    public static func load(_ defaults: UserDefaults = .standard) -> SharedBrowserSettings {
        guard let data = defaults.data(forKey: defaultsKey), let value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return value
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    public var idle: Duration { .seconds(max(1, idleMinutes) * 60) }
    public var screen: (width: Int, height: Int) { compactDisplay ? (1024, 640) : (1280, 800) }
}
