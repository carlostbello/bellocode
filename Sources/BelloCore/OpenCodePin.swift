import Foundation

/// The bundled opencode version, from its single source of truth (docs/features/opencode-upgrades.md).
///
/// The pin is `Scripts/opencode-version`. `Scripts/fetch-opencode.sh` and `Scripts/make-app.sh` read that file, and
/// make-app writes it into the bundle's `Info.plist` (`BelloCodeOpenCodeVersion`). The app reads the bundle; tests and
/// development tools read the file. `BELLOCODE_OPENCODE_VERSION` overrides the file for the regression gate
/// (`make opencode-verify VERSION=x.y.z`), which runs everything against a candidate without changing the pin.
public enum OpenCodePin {
    public static let infoPlistKey = "BelloCodeOpenCodeVersion"
    public static let environmentOverride = "BELLOCODE_OPENCODE_VERSION"

    /// The repository root of this checkout (from this file's compile-time path); nil in a shipped app.
    public static var repositoryRoot: URL? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: root.appending(path: "Scripts/opencode-version").path) ? root : nil
    }

    /// The version bundled in `bundle` (`Contents/Helpers/opencode`), if it is a built app.
    public static func bundledVersion(bundle: Bundle = .main) -> String? {
        (bundle.object(forInfoDictionaryKey: infoPlistKey) as? String).flatMap(clean)
    }

    /// The version a checkout works against: the override, else `Scripts/opencode-version`.
    public static func repositoryVersion(
        root: URL? = repositoryRoot, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let override = environment[environmentOverride].flatMap(clean) { return override }
        guard let root else { return nil }
        return (try? String(contentsOf: root.appending(path: "Scripts/opencode-version"), encoding: .utf8)).flatMap(clean)
    }

    /// What this process runs against: the bundle's version in the app, else the checkout's.
    public static var current: String? { bundledVersion() ?? repositoryVersion() }

    /// `Vendor/opencode/<version>/opencode`, if fetched.
    public static func vendoredBinary(root: URL? = repositoryRoot, version: String? = nil) -> URL? {
        guard let root, let version = version ?? repositoryVersion(root: root) else { return nil }
        let url = root.appending(path: "Vendor/opencode/\(version)/opencode")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// `Contracts/opencode-<version>`: the OpenAPI document and recorded streams of that release.
    public static func contractsDirectory(root: URL? = repositoryRoot, version: String? = nil) -> URL? {
        guard let root, let version = version ?? repositoryVersion(root: root) else { return nil }
        return root.appending(path: "Contracts/opencode-\(version)", directoryHint: .isDirectory)
    }

    private static func clean(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
