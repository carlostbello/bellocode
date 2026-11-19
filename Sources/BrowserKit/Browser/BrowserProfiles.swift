import CryptoKit
import Foundation
import WebKit

/// Website data stores: one persistent store per project (cookies, local storage and caches are separate between
/// projects and from Safari), and one ephemeral store per thread for private tabs (nothing written to disk).
@MainActor
final class BrowserProfiles {
    private var persistent: [String: WKWebsiteDataStore] = [:]
    private var ephemeral: [String: WKWebsiteDataStore] = [:]
    /// Tests and the demo harness use ephemeral stores only, so they never touch the person's profiles.
    let isolated: Bool

    init(isolated: Bool = false) { self.isolated = isolated }

    /// A stable identifier for a project's store: a name-based UUID of its directory.
    nonisolated static func identifier(forProject directory: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("bellocode.browser.profile:\(directory)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5 (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9],
                           bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func store(forProject directory: String) -> WKWebsiteDataStore {
        if let store = persistent[directory] { return store }
        let store = isolated ? WKWebsiteDataStore.nonPersistent() : WKWebsiteDataStore(forIdentifier: Self.identifier(forProject: directory))
        CanonicalPreviewProxy.apply(to: store)
        persistent[directory] = store
        return store
    }

    func privateStore(forThread key: String) -> WKWebsiteDataStore {
        if let store = ephemeral[key] { return store }
        let store = WKWebsiteDataStore.nonPersistent()
        CanonicalPreviewProxy.apply(to: store)
        ephemeral[key] = store
        return store
    }

    /// Drops a thread's private store once its last private tab closed.
    func releasePrivateStore(forThread key: String) { ephemeral[key] = nil }

    /// Removes cookies, storage and caches of a project's profile (Clear Site Data). Open pages keep running.
    func clearSiteData(forProject directory: String) async {
        let store = self.store(forProject: directory)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

/// A responsive viewport size for previews. `nil` preset means "fill the pane".
public struct ViewportPreset: Sendable, Hashable, Codable, Identifiable {
    public var name: String
    public var width: Int
    public var height: Int
    /// Mobile presets send a mobile Safari user agent so sites serve their mobile layout.
    public var isMobile: Bool
    /// The device's pixel ratio. WebKit has no public API to emulate it: shown for reference, the page sees the display's.
    public var scale: Double

    public var id: String { "\(name)-\(width)x\(height)" }

    public init(name: String, width: Int, height: Int, isMobile: Bool, scale: Double) {
        self.name = name
        self.width = width
        self.height = height
        self.isMobile = isMobile
        self.scale = scale
    }

    public static let presets: [ViewportPreset] = [
        ViewportPreset(name: "iPhone SE", width: 375, height: 667, isMobile: true, scale: 2),
        ViewportPreset(name: "iPhone 16", width: 393, height: 852, isMobile: true, scale: 3),
        ViewportPreset(name: "iPhone 16 Pro Max", width: 440, height: 956, isMobile: true, scale: 3),
        ViewportPreset(name: "Pixel 9", width: 412, height: 915, isMobile: true, scale: 2.6),
        ViewportPreset(name: "iPad mini", width: 744, height: 1133, isMobile: true, scale: 2),
        ViewportPreset(name: "iPad Pro 13″", width: 1032, height: 1376, isMobile: true, scale: 2),
        ViewportPreset(name: "Laptop", width: 1280, height: 800, isMobile: false, scale: 2),
        ViewportPreset(name: "Desktop", width: 1440, height: 900, isMobile: false, scale: 2),
        ViewportPreset(name: "Full HD", width: 1920, height: 1080, isMobile: false, scale: 1),
    ]

    public static func custom(width: Int, height: Int, scale: Double = 2) -> ViewportPreset {
        ViewportPreset(name: "Custom", width: min(max(width, 200), 3840), height: min(max(height, 200), 3840), isMobile: width < 800, scale: scale)
    }

    static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
}

/// The page's colour scheme: follow BelloCode, or force light or dark (`prefers-color-scheme` follows the web view's
/// appearance in WebKit).
public enum PageAppearance: String, Sendable, Codable, CaseIterable {
    case system, light, dark

    public var title: String {
        switch self {
        case .system: "Match BelloCode"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
