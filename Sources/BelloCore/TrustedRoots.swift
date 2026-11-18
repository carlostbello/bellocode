import Foundation

/// The folders a developer configured as code roots (Settings ▸ Containers ▸ Code roots), handed to the policy layer
/// (Auto mode, Full-access risk notices) as *trusted*: a path inside one counts as "in scope" like the project itself,
/// so reading another repository under `~/Documents/Repos` needs no approval, while anything outside the roots and the
/// project still escalates or produces a notice (docs/features/containers.md, "Code roots").
///
/// Plain value, no I/O apart from resolving links in `contains`. Paths are canonical (links resolved) when the app
/// builds it; `contains` checks the path both as given and resolved, so a link inside a root that points outside is
/// outside.
public struct TrustedRoots: Sendable, Hashable, Codable {
    public enum Source: String, Sendable, Hashable, Codable {
        /// Nothing configured (no projects yet, or the person removed every root).
        case none
        /// Chosen by the developer in Settings.
        case configured
        /// Suggested from where the projects live on first run and saved.
        case suggested
        /// Set by an administrator (managed preferences).
        case managed
    }

    /// Canonical absolute folders, outermost only.
    public var paths: [String]
    public var source: Source

    /// Existing roots are stored with links resolved (`/var/…` becomes `/private/var/…`), so `contains` compares like
    /// with like.
    public init(paths: [String], source: Source) {
        self.paths = paths.map { path in
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        self.source = paths.isEmpty ? .none : source
    }

    public static let none = TrustedRoots(paths: [], source: .none)

    public var isEmpty: Bool { paths.isEmpty }

    /// True when `path` (absolute) is one of the roots or inside one, both as written and with links resolved.
    public func contains(_ path: String) -> Bool {
        guard !paths.isEmpty, path.hasPrefix("/") else { return false }
        // A link inside a root that leads outside it is outside: decide on the resolved path (longest existing prefix).
        let resolved = Self.resolveExistingPrefix((path as NSString).standardizingPath)
        return paths.contains { Self.inside(resolved, $0) }
    }

    /// The roots a policy check for one project should treat as "in scope": the project's own roots (its folder and
    /// worktrees) first, then the trusted code roots.
    public func scope(projectRoots: [String]) -> [String] {
        var seen = Set<String>()
        return (projectRoots + paths).filter { seen.insert($0).inserted }
    }

    static func inside(_ path: String, _ root: String) -> Bool {
        let root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// Resolves links in the longest prefix of `path` that exists; the rest is appended unchanged.
    static func resolveExistingPrefix(_ path: String) -> String {
        var prefix = path
        var rest: [String] = []
        while prefix != "/" && !prefix.isEmpty {
            if let resolved = realpath(prefix, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return rest.isEmpty ? base : (base as NSString).appendingPathComponent(rest.reversed().joined(separator: "/"))
            }
            rest.append((prefix as NSString).lastPathComponent)
            prefix = (prefix as NSString).deletingLastPathComponent
        }
        return path
    }
}
