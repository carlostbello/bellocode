import Foundation

/// Where a project's commands run (docs/features/containers.md, "Execution modes"). opencode itself, its file tools and
/// BelloCode's git always stay on the Mac; this decides only what the agent and the person *run*.
public enum ExecutionMode: String, Codable, Sendable, CaseIterable, Hashable {
    /// One long-lived BelloCode container per developer that mounts every code root at the same path. Commands run
    /// there with the thread's project as working directory; other repositories under the roots are visible.
    case sharedWorkspace = "shared"
    /// The project's own container (its own image, services, caches): the behaviour before execution modes.
    case projectContainer = "project"
    /// The agent's shell runs on the Mac but only `docker`, `docker compose` and `docker buildx` (Rancher Desktop's,
    /// by absolute path) are allowed, talking to BelloCode's filtered endpoint. Weaker: it relies on parsing one
    /// command line, and anything compound is refused.
    case hostDocker = "host-docker"

    /// The app-wide default for projects that have not chosen.
    public static let defaultMode = ExecutionMode.sharedWorkspace

    public var title: String {
        switch self {
        case .sharedWorkspace: "Shared workspace"
        case .projectContainer: "Project container"
        case .hostDocker: "Host shell, docker only"
        }
    }

    /// A word or two for context lines and the thread header.
    public var shortTitle: String {
        switch self {
        case .sharedWorkspace: "Shared"
        case .projectContainer: "Project container"
        case .hostDocker: "Host docker"
        }
    }

    public var symbolName: String {
        switch self {
        case .sharedWorkspace: "square.stack.3d.up"
        case .projectContainer: "shippingbox"
        case .hostDocker: "terminal"
        }
    }

    /// What choosing the mode does, for the picker.
    public var explanation: String {
        switch self {
        case .sharedWorkspace:
            "Commands run in one BelloCode container shared by your projects. Every code root is mounted at the same path, so the agent can read and build other repositories under them without asking. Uses the default image; docker inside talks to BelloCode's filtered endpoint."
        case .projectContainer:
            "Commands run in this project's own container, with its own image, services and caches. Only this project and its worktrees are mounted."
        case .hostDocker:
            "Commands run on this Mac, but only docker, docker compose and docker buildx are allowed (Rancher Desktop's), through BelloCode's filtered endpoint. Weaker: a single command line is parsed and anything compound is refused. No terminal."
        }
    }

    /// What switching to this mode changes for running work.
    public var switchEffect: String {
        switch self {
        case .sharedWorkspace:
            "Running commands and terminals of this project stop. The next command starts in the shared workspace; the project's own container is kept (stopped) until you delete it."
        case .projectContainer:
            "Running commands and terminals of this project stop. The next command starts the project's own container with its image."
        case .hostDocker:
            "Running commands and terminals of this project stop. Only docker commands will run, on this Mac; terminals and other commands are refused."
        }
    }
}

/// Why a code root is not usable (or only usable with care), phrased for Settings ▸ Containers ▸ Code roots.
public struct CodeRootIssue: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Equatable, Hashable {
        case notAbsolute, missing, notDirectory, notCanonical, systemLocation, wholeHome, sensitive, overlaps, notShared
    }

    public var path: String
    public var kind: Kind
    public var message: String
    /// The fix BelloCode can apply itself (the canonical spelling), when there is one.
    public var suggestion: String?
    /// False for issues that do not stop the root from being used: an overlap is dropped, and a link is replaced by
    /// the real folder it leads to (which is then validated itself).
    public var isBlocking: Bool { kind != .overlaps && kind != .notCanonical }

    public init(path: String, kind: Kind, message: String, suggestion: String? = nil) {
        self.path = path
        self.kind = kind
        self.message = message
        self.suggestion = suggestion
    }
}

/// The folders a developer keeps their repositories in (docs/features/containers.md, "Code roots"). The shared
/// workspace mounts each at the same path; the policy layer treats them as trusted (inside them is "in scope").
public enum CodeRootPaths {
    /// System locations a root may neither be, nor contain, nor sit inside (apart from the temporary folders, which
    /// Rancher Desktop shares and tests use).
    public static let systemLocations = [
        "/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/var", "/private/var", "/Applications",
        "/opt", "/dev", "/cores", "/Network", "/private", "/tmp",
    ]
    /// Locations a root may be inside of but neither be nor contain.
    public static let containerLocations = ["/Users", "/Volumes"]
    /// Temporary folders allowed below the system locations above.
    public static let temporaryLocations = ["/private/tmp", "/tmp", "/private/var/folders", "/var/folders"]
    /// Folders in the home folder that hold credentials or configuration: never mounted.
    public static let sensitiveHomeFolders = [
        "Library", ".ssh", ".gnupg", ".aws", ".config", ".local", ".docker", ".rd", ".kube", ".bellocode", ".netrc",
        ".git-credentials", ".npmrc", ".azure", ".gcloud", ".password-store", ".Trash",
    ]
    /// Top-level home folders too broad to suggest on their own (a project directly in one suggests itself).
    public static let broadHomeFolders = ["Documents", "Desktop", "Downloads", "Developer", "Pictures", "Movies", "Music", "Public"]

    /// The path with `~` expanded, `.`/`..` and trailing slashes removed (no symlinks resolved).
    public static func standardize(_ path: String, home: String = NSHomeDirectory()) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "~" { value = home } else if value.hasPrefix("~/") { value = home + value.dropFirst(1) }
        return lexicallyNormalized(value)
    }

    /// Removes `.`, `..`, repeated and trailing slashes without touching links (unlike `standardizingPath`, which also
    /// drops a leading `/private`).
    public static func lexicallyNormalized(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The path with every symlink resolved (the canonical spelling), or nil when it does not exist.
    public static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func inside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    static func strictlyInside(_ path: String, _ root: String) -> Bool { path != root && inside(path, root) }

    /// Validates one root (exists, a folder, canonical, not a system or sensitive location, not the home folder, shared
    /// with Rancher Desktop's VM). `sharedPrefixes` are the folders the VM sees.
    public static func issues(for path: String, home: String = NSHomeDirectory(),
                              sharedPrefixes: [String]? = nil) -> [CodeRootIssue] {
        let standardized = standardize(path, home: home)
        guard standardized.hasPrefix("/") else {
            return [CodeRootIssue(path: path, kind: .notAbsolute, message: "“\(path)” is not a full path. Choose the folder with Add Folder….")]
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory) else {
            return [CodeRootIssue(path: standardized, kind: .missing, message: "\(display(standardized, home: home)) does not exist.")]
        }
        guard isDirectory.boolValue else {
            return [CodeRootIssue(path: standardized, kind: .notDirectory, message: "\(display(standardized, home: home)) is a file, not a folder.")]
        }
        var found: [CodeRootIssue] = []
        let canonicalPath = canonical(standardized) ?? standardized
        if canonicalPath != standardized {
            found.append(CodeRootIssue(
                path: standardized, kind: .notCanonical,
                message: "\(display(standardized, home: home)) is a link to \(display(canonicalPath, home: home)); the real folder is used, so paths in the container and on the Mac agree.",
                suggestion: canonicalPath))
        }
        // Checked on both spellings: a link may not lead into a system location.
        let canonicalHome = canonical(home) ?? home
        for candidate in Set([standardized, canonicalPath]) {
            if candidate == "/" || candidate == home || candidate == canonicalHome {
                found.append(CodeRootIssue(path: standardized, kind: candidate == "/" ? .systemLocation : .wholeHome,
                                           message: candidate == "/" ? "The whole disk cannot be a code root." : "Your whole home folder cannot be a code root: it holds credentials and settings. Choose the folder your repositories are in, such as ~/Documents/Repos."))
                continue
            }
            if strictlyInside(home, candidate) || strictlyInside(canonicalHome, candidate) {
                found.append(CodeRootIssue(path: standardized, kind: .wholeHome, message: "\(display(candidate, home: home)) contains your home folder. Choose the folder your repositories are in."))
                continue
            }
            if let location = containerLocations.first(where: { inside($0, candidate) }) {
                found.append(CodeRootIssue(path: standardized, kind: .systemLocation, message: "\(display(candidate, home: home)) is or contains \(location). Choose the folder your repositories are in."))
                continue
            }
            let temporary = temporaryLocations.contains { strictlyInside(candidate, $0) }
            if !temporary, let system = systemLocations.first(where: { inside(candidate, $0) || strictlyInside($0, candidate) }),
               !(inside(candidate, home) || inside(candidate, canonicalHome)) {
                found.append(CodeRootIssue(path: standardized, kind: .systemLocation, message: "\(display(candidate, home: home)) is a system location (\(system)). Code roots must be folders of your own."))
                continue
            }
            for name in sensitiveHomeFolders {
                for base in Set([home, canonicalHome]) {
                    let sensitive = base + "/" + name
                    if inside(candidate, sensitive) || strictlyInside(sensitive, candidate) {
                        found.append(CodeRootIssue(path: standardized, kind: .sensitive, message: "\(display(candidate, home: home)) is or contains ~/\(name), which holds credentials or settings. Choose a folder that holds only repositories."))
                    }
                }
            }
        }
        let shared = sharedPrefixes ?? RancherFileSharing.sharedPrefixes(home: home)
        if !shared.contains(where: { inside(canonicalPath, $0) || inside(standardized, $0) }) {
            found.append(CodeRootIssue(path: standardized, kind: .notShared, message: notSharedMessage(standardized, home: home)))
        }
        var unique: [CodeRootIssue] = []
        for issue in found where !unique.contains(where: { $0.kind == issue.kind }) { unique.append(issue) }
        return unique
    }

    /// How to make Rancher Desktop share a folder (BelloCode never edits Rancher Desktop's configuration itself).
    public static func notSharedMessage(_ path: String, home: String = NSHomeDirectory()) -> String {
        "Rancher Desktop does not share \(display(path, home: home)) with its virtual machine (it shares your home folder, /Volumes and the temporary folders), so the container cannot mount it. Move the repositories under your home folder, or add the folder as a writable mount in Rancher Desktop's Lima override (~/Library/Application Support/rancher-desktop/lima/_config/override.yaml, under mounts:) and restart Rancher Desktop."
    }

    /// The result of validating a list: usable roots (canonical, de-duplicated, outermost only) and every issue.
    public struct Validation: Sendable, Equatable {
        public var roots: [String]
        public var issues: [CodeRootIssue]
        public var isValid: Bool { !issues.contains(where: \.isBlocking) }

        public init(roots: [String], issues: [CodeRootIssue]) {
            self.roots = roots
            self.issues = issues
        }
    }

    /// Validates a list: each root on its own, then overlaps (a root inside another adds nothing and is dropped).
    public static func validate(_ paths: [String], home: String = NSHomeDirectory(), sharedPrefixes: [String]? = nil) -> Validation {
        var issues: [CodeRootIssue] = []
        var usable: [String] = []
        for path in paths where !path.trimmingCharacters(in: .whitespaces).isEmpty {
            let found = Self.issues(for: path, home: home, sharedPrefixes: sharedPrefixes)
            issues += found
            if !found.contains(where: \.isBlocking) {
                let standardized = standardize(path, home: home)
                usable.append(canonical(standardized) ?? standardized)
            }
        }
        var seen = Set<String>()
        usable = usable.filter { seen.insert($0).inserted }
        var roots: [String] = []
        for root in usable {
            if let outer = usable.first(where: { strictlyInside(root, $0) }) {
                issues.append(CodeRootIssue(path: root, kind: .overlaps, message: "\(display(root, home: home)) is inside \(display(outer, home: home)), which is already a code root; it is not mounted separately."))
            } else {
                roots.append(root)
            }
        }
        return Validation(roots: roots.sorted(), issues: issues)
    }

    /// A first-run suggestion from where the person's projects live: the folder that holds them (for projects in
    /// `~/Documents/Repos/*`, that folder). Never the home folder, `/`, a system or sensitive location, or a broad home
    /// folder such as ~/Documents on its own: a project directly in one of those suggests itself. Only folders Rancher
    /// Desktop shares are suggested.
    public static func suggestion(projectDirectories: [String], home: String = NSHomeDirectory(),
                                  sharedPrefixes: [String]? = nil) -> [String] {
        var candidates: [String] = []
        for directory in projectDirectories {
            let project = canonical(standardize(directory, home: home)) ?? standardize(directory, home: home)
            let parent = (project as NSString).deletingLastPathComponent
            let canonicalHome = canonical(home) ?? home
            let broad = parent == home || parent == canonicalHome || parent == "/"
                || broadHomeFolders.contains { parent == home + "/" + $0 || parent == canonicalHome + "/" + $0 }
            let choice = broad ? project : parent
            if issues(for: choice, home: home, sharedPrefixes: sharedPrefixes).contains(where: \.isBlocking) {
                if !issues(for: project, home: home, sharedPrefixes: sharedPrefixes).contains(where: \.isBlocking) { candidates.append(project) }
            } else {
                candidates.append(choice)
            }
        }
        return validate(candidates, home: home, sharedPrefixes: sharedPrefixes).roots
    }

    /// `~/…` for paths in the home folder.
    public static func display(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The root containing `path` (lexically or after resolving links), if any.
    public static func root(containing path: String, in roots: [String]) -> String? {
        let standardized = lexicallyNormalized(path)
        let resolved = canonical(standardized) ?? standardized
        return roots.filter { inside(standardized, $0) || inside(resolved, $0) || inside(standardized, canonical($0) ?? $0) }
            .max { $0.count < $1.count }
    }
}

/// The administrator's execution settings, from the same managed sources as `ManagedImagePolicy` (a configuration
/// profile for `com.bellocode.app`, or the root-owned `/Library/Preferences/app.bellocode.policy.plist`):
/// `ContainerCodeRoots` (array of paths, `~/` allowed: the developer's defaults), `ContainerCodeRootsLocked` (bool: the
/// list cannot be edited), `ContainerDefaultExecutionMode` (`shared` | `project` | `host-docker`) and
/// `ContainerAllowedExecutionModes` (array: modes developers may choose; others are hidden and refused).
public enum ManagedExecutionPolicy {
    public static let codeRootsKey = "ContainerCodeRoots"
    public static let codeRootsLockedKey = "ContainerCodeRootsLocked"
    public static let defaultModeKey = "ContainerDefaultExecutionMode"
    public static let allowedModesKey = "ContainerAllowedExecutionModes"
    public static let keys = [codeRootsKey, codeRootsLockedKey, defaultModeKey, allowedModesKey]

    public struct Managed: Sendable, Equatable {
        public var codeRoots: [String]?
        public var codeRootsLocked: Bool
        public var defaultMode: ExecutionMode?
        public var allowedModes: Set<ExecutionMode>?
        public var source: String

        public init(codeRoots: [String]? = nil, codeRootsLocked: Bool = false, defaultMode: ExecutionMode? = nil,
                    allowedModes: Set<ExecutionMode>? = nil, source: String) {
            self.codeRoots = codeRoots
            self.codeRootsLocked = codeRootsLocked
            self.defaultMode = defaultMode
            self.allowedModes = allowedModes
            self.source = source
        }

        public func allows(_ mode: ExecutionMode) -> Bool { allowedModes?.contains(mode) ?? true }
    }

    public static func read(defaults: UserDefaults = .standard, systemPlist: String = ManagedImagePolicy.systemPlist,
                            home: String = NSHomeDirectory()) -> Managed? {
        if keys.contains(where: { defaults.objectIsForced(forKey: $0) }) {
            return managed(from: { defaults.objectIsForced(forKey: $0) ? defaults.object(forKey: $0) : nil }, source: "configuration profile", home: home)
        }
        guard let values = ManagedImagePolicy.rootOwnedPlist(systemPlist), keys.contains(where: { values[$0] != nil }) else { return nil }
        return managed(from: { values[$0] }, source: systemPlist, home: home)
    }

    static func managed(from value: (String) -> Any?, source: String, home: String) -> Managed {
        let roots = ((value(codeRootsKey) as? [String]) ?? (value(codeRootsKey) as? String).map { [$0] })?
            .map { CodeRootPaths.standardize($0, home: home) }
        let allowed = (value(allowedModesKey) as? [String]).map { Set($0.compactMap(ExecutionMode.init(rawValue:))) }
        return Managed(codeRoots: roots, codeRootsLocked: (value(codeRootsLockedKey) as? Bool) ?? false,
                       defaultMode: (value(defaultModeKey) as? String).flatMap(ExecutionMode.init(rawValue:)),
                       allowedModes: allowed?.isEmpty == true ? nil : allowed, source: source)
    }
}
