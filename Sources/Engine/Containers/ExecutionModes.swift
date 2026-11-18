import BelloCore
import ContainerKit
import Foundation

// Code roots and execution modes (docs/features/containers.md, "Execution modes" and "Code roots").

extension EnvironmentService {
    nonisolated static let modesMigratedKey = "containers.executionModesMigrated"

    // MARK: Code roots

    /// The roots as configured, before validation: an administrator's locked list, else the developer's, else the
    /// administrator's defaults.
    public var configuredCodeRoots: [String] {
        if codeRootsLocked, let roots = managedExecution?.codeRoots { return roots }
        return defaults.codeRoots ?? managedExecution?.codeRoots ?? []
    }

    /// True when an administrator set the code roots and locked them.
    public var codeRootsLocked: Bool { managedExecution?.codeRootsLocked == true && managedExecution?.codeRoots != nil }

    /// Where the roots in force came from.
    public var codeRootsSource: TrustedRoots.Source {
        if codeRootsLocked || (defaults.codeRoots == nil && managedExecution?.codeRoots != nil) { return .managed }
        return defaults.codeRootsSource ?? (defaults.codeRoots == nil ? .none : .configured)
    }

    /// The validated code roots, as the policy layer's trusted roots (Auto mode, risk notices).
    public var trustedRoots: TrustedRoots { TrustedRoots(paths: codeRootsValidation.roots, source: codeRootsSource) }

    /// What the policy layer (Auto mode, Full-access risk notices) treats as "in scope" for a thread in `directory`:
    /// the project and its worktrees first, then the trusted code roots. A path outside all of them still escalates
    /// (Auto) or produces a notice (Full access).
    public func policyRoots(for directory: String) -> [String] {
        let model = environment(for: directory)
        return trustedRoots.scope(projectRoots: workspaceRoots(model, create: false))
    }

    /// Re-validates the roots (file-system checks: a handful of `stat`/`realpath` calls).
    func recomputeCodeRoots() {
        let validation = CodeRoots.validate(configuredCodeRoots)
        if validation != codeRootsValidation { codeRootsValidation = validation }
    }

    /// Saves the developer's roots (ignored while an administrator locks them). The shared workspace is recreated with
    /// the new mounts on its next use.
    public func setCodeRoots(_ paths: [String]) async {
        guard !codeRootsLocked else { return }
        var value = defaults
        value.codeRoots = paths.map { CodeRoots.standardize($0) }
        value.codeRootsSource = .configured
        await setDefaults(value)
        recomputeCodeRoots()
        for model in models.values { refreshImageAndPhase(model) }
        scheduleConfigWrite()
    }

    /// First run: when nothing is configured or managed, suggest roots from where the projects live and save them
    /// (marked as suggested; Settings shows them for review).
    func suggestCodeRootsIfNeeded() {
        guard defaults.codeRoots == nil, managedExecution?.codeRoots == nil else { return }
        let projects = projectDirectories.sorted()
        let suggestion = CodeRoots.suggestion(projectDirectories: projects)
        guard !suggestion.isEmpty else { return }
        var value = defaults
        value.codeRoots = suggestion
        value.codeRootsSource = .suggested
        defaults = value
        recomputeCodeRoots()
        let store = store
        tasks.set("save-code-roots", Task { try? await store.setPreference(EnvironmentDefaults.preferenceKey, value) })
        for model in models.values { refreshImageAndPhase(model) }
        scheduleConfigWrite()
    }

    // MARK: Modes

    /// True when the administrator allows `mode` (every mode when nothing is managed).
    public func isAllowed(_ mode: ExecutionMode) -> Bool { managedExecution?.allows(mode) ?? true }

    /// The app-wide default: the administrator's, else Settings', else the shared workspace (the first allowed one).
    public var defaultMode: ExecutionMode {
        let candidate = managedExecution?.defaultMode ?? defaults.defaultMode ?? .defaultMode
        if isAllowed(candidate) { return candidate }
        return ExecutionMode.allCases.first(where: isAllowed) ?? .projectContainer
    }

    /// The mode a project runs in: its own choice when allowed, else the default.
    public func mode(for model: ProjectEnvironment) -> ExecutionMode {
        if let chosen = model.settings.executionMode, isAllowed(chosen) { return chosen }
        return defaultMode
    }

    public func mode(forDirectory directory: String) -> ExecutionMode { mode(for: environment(for: directory)) }

    /// Changes the app-wide default (projects that chose a mode keep it).
    public func setDefaultMode(_ mode: ExecutionMode) async {
        var value = defaults
        value.defaultMode = mode
        await setDefaults(value)
    }

    /// Chooses a project's mode (nil follows the default). Running commands of the project stop: the switch effect is
    /// explained before this is called.
    public func setMode(_ mode: ExecutionMode?, for directory: String) async {
        var settings = environment(for: directory).settings
        settings.executionMode = mode
        await update(directory, settings: settings)
    }

    // MARK: Migration

    /// Once: projects that already have a workspace container with state keep running in it ("Project container");
    /// every other project follows the default (the shared workspace).
    func migrateExecutionModes() async {
        guard policyReadFailure == nil else { return }
        guard (try? await store.preference(Self.modesMigratedKey, as: Bool.self)) != true else { return }
        for model in models.values where model.settings.executionMode == nil && Self.hasContainerState(model.record)
            && !unreadablePolicies.contains(model.directory) {
            model.settings.executionMode = .projectContainer
            await persist(model)
        }
        try? await store.setPreference(Self.modesMigratedKey, true)
    }

    /// A container was created for the project before (its record names one, or it ran).
    nonisolated static func hasContainerState(_ record: EnvironmentRecord) -> Bool {
        record.containerID != nil || record.lastUsed != nil || record.mountIdentity != nil
    }
}

// MARK: - The shared workspace

extension EnvironmentService {
    /// Why a shared-mode project cannot use the shared workspace (it is outside every code root), or nil.
    func outsideRootsMessage(_ model: ProjectEnvironment) -> String? {
        let roots = codeRootsValidation.roots
        if roots.isEmpty {
            return "This project uses the shared workspace, but no code roots are set. Add the folder your repositories are in under Settings ▸ Containers ▸ Code roots, or switch the project to Project container in Project Settings ▸ Environment."
        }
        guard CodeRoots.root(containing: model.directory, in: roots) == nil else { return nil }
        let parent = CodeRoots.display((model.directory as NSString).deletingLastPathComponent)
        return "\(CodeRoots.display(model.directory)) is outside your code roots (\(roots.map { CodeRoots.display($0) }.joined(separator: ", "))), so the shared workspace cannot see it. Add \(parent) under Settings ▸ Containers ▸ Code roots, or switch the project to Project container in Project Settings ▸ Environment."
    }

    /// The folders the shared workspace mounts besides the code roots: BelloCode's and opencode's worktree folders
    /// (whole, so adding a project does not recreate the container), and any shared project's own worktree folder
    /// outside them. Missing folders are created (they must exist to be mounted).
    func sharedExtraMounts() -> [String] {
        let roots = codeRootsValidation.roots
        // The folder BelloCode's worktrees live in (~/.bellocode/worktrees), whole.
        var mounts = [(worktreeParent("/shared") as NSString).deletingLastPathComponent]
        if let data = configuration?.opencodeDataDirectory { mounts.append(data.appending(path: "opencode/worktree").path) }
        for model in models.values.sorted(by: { $0.directory < $1.directory })
        where mode(for: model) == .sharedWorkspace && CodeRoots.root(containing: model.directory, in: roots) != nil {
            mounts.append(worktreeParent(model.directory))
            mounts += model.extraWorktrees
        }
        var seen = Set<String>()
        let standardized = mounts.map { CodeRoots.lexicallyNormalized($0) }.filter { seen.insert($0).inserted }
        let outer = standardized.filter { path in
            !(roots + standardized).contains { $0 != path && CodeRoots.inside(path, $0) }
        }
        for path in outer where !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        return outer
    }

    /// The shared workspace's container setting: every code root and the worktree folders at the same paths, the
    /// app-wide default image, standard limits. Nil without roots or an allowed default image.
    func sharedSpec() -> WorkspaceSpec? {
        let roots = codeRootsValidation.roots
        guard !roots.isEmpty, let image = defaultImage, imageRefusal(image) == nil else { return nil }
        var spec = WorkspaceSpec.shared(roots: roots, extraMounts: sharedExtraMounts(), image: image)
        spec.sharedKeySeed = sharedKeySeed
        return spec
    }

    /// Roots whose marker file, written on the Mac, is not visible in the container (Rancher Desktop does not share
    /// the folder with its VM, or shares a stale view). Markers are removed at once.
    nonisolated static func invisibleRoots(_ roots: [String], container: String, user: String, runtime: any WorkspaceRuntime) async -> [String] {
        let name = ".bellocode-root-check-\(UUID().uuidString.prefix(8))"
        var markers: [String: String] = [:]
        for root in roots {
            let marker = (root as NSString).appendingPathComponent(name)
            if FileManager.default.createFile(atPath: marker, contents: Data()) { markers[root] = marker }
        }
        defer { for marker in markers.values { try? FileManager.default.removeItem(atPath: marker) } }
        guard !markers.isEmpty else { return [] }
        let ordered = markers.sorted { $0.key < $1.key }
        let script = #"for f; do if [ -e "$f" ]; then echo 1; else echo 0; fi; done"#
        guard let result = try? await runtime.run(container: container, argv: ["/bin/sh", "-c", script, "check"] + ordered.map(\.value),
                                                  workingDir: nil, environment: [:], user: user, timeout: .seconds(10)) else { return [] }
        let flags = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n")
        guard flags.count == ordered.count else { return [] }
        return zip(ordered, flags).filter { $0.1 == "0" }.map(\.0.key)
    }

    /// Idle stop for the shared workspace: only when no project using it was active within the shortest idle setting,
    /// none forwards a port and nothing runs in it.
    func stopSharedIfIdle() async {
        let shared = models.values.filter { $0.mode == .sharedWorkspace && $0.phase == .ready }
        guard !shared.isEmpty, shared.allSatisfy({ $0.forwards.isEmpty && $0.serviceForwards.isEmpty }) else { return }
        let minutes = shared.map(\.settings.idleStopMinutes).min() ?? 30
        guard minutes > 0, let id = shared.compactMap(\.record.containerID).first else { return }
        let last = shared.map { $0.lastActivity ?? $0.record.lastUsed ?? .distantPast }.max() ?? .distantPast
        guard Date().timeIntervalSince(last) > TimeInterval(minutes * 60) else { return }
        let runtimeRef = activeRuntime
        guard await runtimeRef.runningExecs(container: id) == 0 else {
            for model in shared { model.lastActivity = Date() }
            return
        }
        _ = try? await runtimeRef.reap(container: id, user: "\(getuid()):\(getgid())")
        try? await runtimeRef.stop(container: id)
        for model in shared {
            stopBridge(model)
            model.phase = .idle
        }
        scheduleConfigWrite()
    }

    // MARK: Docker access per workspace (the filtered endpoint, step 4)

    /// `DOCKER_HOST` for commands in a container of `scope`, when the filtered endpoint runs.
    func containerDockerAccess(scope: String, spec: WorkspaceSpec?) -> ExecHelperConfig.DockerAccess? {
        guard let spec, let endpoint = dockerEndpoint, let token = endpoint.token(scope: scope, roots: spec.workspaceRoots + spec.userMounts.filter { !$0.readOnly }.map(\.path)) else { return nil }
        return ExecHelperConfig.DockerAccess(host: "tcp://host.docker.internal:\(endpoint.port)/\(token)")
    }

    /// Host docker-only mode: Rancher Desktop's docker by absolute path, BelloCode's own docker configuration, the
    /// endpoint on the Mac's loopback.
    func hostDockerAccess(_ model: ProjectEnvironment) -> ExecHelperConfig.DockerAccess? {
        guard let endpoint = dockerEndpoint, let token = endpoint.token(scope: model.projectKey, roots: workspaceRoots(model, create: false)) else { return nil }
        return ExecHelperConfig.DockerAccess(host: "tcp://127.0.0.1:\(endpoint.port)/\(token)", binary: endpoint.hostDockerBinary,
                                             configDirectory: endpoint.hostDockerConfig)
    }
}
