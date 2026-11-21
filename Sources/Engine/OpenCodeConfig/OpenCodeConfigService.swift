import BelloCore
import Darwin
import Foundation
import Observation
import OpenCodeKit

/// Where an agent, command or skill the server reports comes from.
public enum OpenCodeItemSource: String, Sendable, Hashable, CaseIterable {
    /// Built into opencode.
    case builtIn
    /// BelloCode's own (its plugin or inline configuration).
    case bellocode
    /// The global configuration folder (files or `opencode.json`).
    case global
    /// The repository (trusted `.opencode/`, `.agents/skills`, or native project config).
    case project
    /// Anything else (a global plugin, for example).
    case other

    public var label: String {
        switch self {
        case .builtIn: "Built in"
        case .bellocode: "BelloCode"
        case .global: "Global"
        case .project: "Project"
        case .other: "Plugin"
        }
    }
}

public struct OpenCodeItem: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case agent, command, skill }
    public var kind: Kind
    public var name: String
    public var detail: String?
    public var source: OpenCodeItemSource
    public var id: String { "\(kind.rawValue):\(name)" }

    public init(kind: Kind, name: String, detail: String? = nil, source: OpenCodeItemSource) {
        self.kind = kind
        self.name = name
        self.detail = detail
        self.source = source
    }
}

/// What the server reports for one project, with problems worth showing.
public struct OpenCodeInventory: Sendable, Equatable {
    public var directory: String
    public var agents: [OpenCodeItem]
    public var commands: [OpenCodeItem]
    public var skills: [OpenCodeItem]
    /// Global plugins (files in `plugins/` or entries in `opencode.json`), by id.
    public var userPlugins: [String]
    /// The bundled plugin is not active (a `plugin.use` deny policy, a load failure): orchestration tools, the
    /// container guard hook and the environment contract are off.
    public var pluginProblem: String?
    /// Files the plugin skipped in a trusted project (with the reason).
    public var skipped: [String]

    public init(directory: String, agents: [OpenCodeItem] = [], commands: [OpenCodeItem] = [], skills: [OpenCodeItem] = [],
                userPlugins: [String] = [], pluginProblem: String? = nil, skipped: [String] = []) {
        self.directory = directory
        self.agents = agents
        self.commands = commands
        self.skills = skills
        self.userPlugins = userPlugins
        self.pluginProblem = pluginProblem
        self.skipped = skipped
    }
}

/// Settings ▸ opencode's model below the UI (docs/features/opencode-config.md): the global configuration folder, the
/// per-project trust of repository configuration (kept in the store and mirrored to the plugin's trust file), what the
/// server reports, problems in `opencode.json`, and reload or restart.
///
/// Threading: `@MainActor`; file checks and HTTP run off it and hand back values. A refresh applies only if it is the
/// newest (generation check).
@MainActor
@Observable
public final class OpenCodeConfigService {
    public let directories: OpenCodeDirectories?
    public var folder: GlobalConfigFolder? { directories.map { GlobalConfigFolder(directories: $0) } }
    /// The policy the running server was started with (`.native` loads every repository's config natively).
    public private(set) var runningPolicy: RepositoryConfigPolicy
    public private(set) var trusted: [String: Date] = [:]
    public private(set) var inventory: OpenCodeInventory?
    public private(set) var refreshing = false
    /// The last refresh failed (offline, server error); the previous inventory is kept and shown as stale.
    public private(set) var refreshError: String?
    /// A syntax problem in the global `opencode.json`, or opencode ignoring it.
    public private(set) var configProblem: String?
    /// A trust change saved but not yet acknowledged by the server's plugin (offline, a failed reload): retried at the
    /// next refresh, applied at the latest when the server restarts.
    public private(set) var trustPending = false
    /// The plugin's trust file could not be written (then it is removed, so no project's configuration loads).
    public private(set) var trustProblem: String?

    @ObservationIgnored private let store: ProjectionStore
    @ObservationIgnored private let client: @Sendable () async throws -> OpenCodeClient
    @ObservationIgnored private let restartServer: (@MainActor () async -> Bool)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private let writeTrust: @Sendable (ProjectTrustFile, URL) throws -> Void
    /// The revision of the trust file last written (the plugin must acknowledge it).
    @ObservationIgnored private(set) var trustRevision = 0
    /// Projects whose trust change the plugin has not acknowledged yet.
    @ObservationIgnored private var unacknowledged: Set<String> = []
    /// Trust changes run one at a time, in order (rapid toggles must not interleave their writes or rollbacks).
    @ObservationIgnored private var trustTail: Task<Void, Never>?

    public init(
        store: ProjectionStore, directories: OpenCodeDirectories?, runningPolicy: RepositoryConfigPolicy,
        client: @escaping @Sendable () async throws -> OpenCodeClient, restartServer: (@MainActor () async -> Bool)?,
        writeTrust: @escaping @Sendable (ProjectTrustFile, URL) throws -> Void = { try $0.write(to: $1) }
    ) {
        self.store = store
        self.directories = directories
        self.runningPolicy = runningPolicy
        self.client = client
        self.restartServer = restartServer
        self.writeTrust = writeTrust
    }

    // MARK: Trust

    /// Reads the trust table and rewrites the plugin's trust file. Call once at start, before the server starts.
    public func load() async {
        guard !loaded else { return }
        loaded = true
        if let file = directories?.trustFile { trustRevision = await Self.revision(of: file) }
        do {
            trusted = try await store.openCodeTrust()
        } catch {
            // Unknown trust: nothing is trusted (the file is written empty), and the reason is shown.
            trusted = [:]
            trustProblem = "Could not read the trusted projects: \(error.localizedDescription)"
        }
        _ = await writeTrustFile()
    }

    public func isTrusted(_ directory: String) -> Bool { trusted[directory] != nil }

    /// Saves the choice, rewrites the trust file and asks the plugin at that project to reload (no restart). Returns
    /// a problem to show, or nil. A change counts as applied only when the plugin acknowledges the trust file's revision
    /// and every transform reload (A10); otherwise `trustPending` stays set and the problem says so. Calls are
    /// serialised in order.
    @discardableResult
    public func setTrusted(_ directory: String, _ value: Bool) async -> String? {
        let previous = trustTail
        let task = Task { @MainActor [weak self] () -> String? in
            await previous?.value
            guard let self else { return nil }
            return await self.performSetTrusted(directory, value)
        }
        trustTail = Task { _ = await task.value }
        return await task.value
    }

    private func performSetTrusted(_ directory: String, _ value: Bool) async -> String? {
        await load()
        let before = trusted[directory]
        trusted[directory] = value ? (before ?? Date()) : nil
        do {
            try await store.setOpenCodeTrust(directory: directory, trusted: value)
        } catch {
            trusted[directory] = before
            return "Could not save the setting: \(error.localizedDescription)"
        }
        let fileProblem = await writeTrustFile()
        guard runningPolicy == .bellocode else { return fileProblem }
        unacknowledged.insert(directory)
        let applyProblem = await applyTrust(directory)
        await refresh(directory: directory, retryTrust: false)
        return fileProblem ?? applyProblem
    }

    /// Asks the plugin at `directory` to re-read the trust file; nil when it acknowledged this revision. Offline (no
    /// client) is not a problem: the server reads the file when it starts.
    private func applyTrust(_ directory: String) async -> String? {
        let connection: OpenCodeClient
        do {
            connection = try await client()
        } catch {
            trustPending = true
            return nil
        }
        do {
            let status = try await connection.reloadProjectConfig(directory: directory)
            if let failures = status.failures, status.applied == false {
                trustPending = true
                return "Saved, but opencode did not apply it (\(failures.joined(separator: ", ")) did not reload). It applies at the next reload or restart."
            }
            if let revision = status.revision, revision != trustRevision {
                trustPending = true
                return "Saved, but opencode applied an older trust list. It applies at the next reload or restart."
            }
            unacknowledged.remove(directory)
            trustPending = !unacknowledged.isEmpty || trustProblem != nil
            return nil
        } catch {
            trustPending = true
            return "Saved, but opencode has not applied it yet (\(error)). It applies at the next reload or restart."
        }
    }

    /// Writes the plugin's trust file with a new revision. On failure the file is removed, so the plugin trusts no
    /// project rather than keep an older list (fail closed), and the problem is returned and kept in `trustProblem`.
    private func writeTrustFile() async -> String? {
        guard let file = directories?.trustFile else { return nil }
        trustRevision = max(trustRevision + 1, Int(Date().timeIntervalSince1970 * 1000))
        let value = ProjectTrustFile(trusted: Array(trusted.keys), revision: trustRevision)
        do {
            try await Self.write(value, to: file, with: writeTrust)
            trustProblem = nil
            return nil
        } catch {
            let removed = await Self.remove(file)
            let text = "Could not write BelloCode's trust file (\(error.localizedDescription))"
                + (removed ? ". Until it can be written, no project's repository configuration loads." : ", and the old one could not be removed.")
            trustProblem = text
            trustPending = true
            return text
        }
    }

    private nonisolated static func write(
        _ value: ProjectTrustFile, to file: URL, with writer: @Sendable (ProjectTrustFile, URL) throws -> Void
    ) async throws { try writer(value, file) }

    private nonisolated static func remove(_ file: URL) async -> Bool { unlink(file.path) == 0 || errno == ENOENT }

    private nonisolated static func revision(of file: URL) async -> Int { ProjectTrustFile.read(from: file).revision }

    /// Retries what the plugin has not acknowledged (a failed write first).
    private func retryPendingTrust() async {
        guard runningPolicy == .bellocode, trustPending else { return }
        if trustProblem != nil, await writeTrustFile() != nil { return }
        for directory in unacknowledged.sorted() { _ = await applyTrust(directory) }
        if unacknowledged.isEmpty, trustProblem == nil { trustPending = false }
    }

    // MARK: Files

    /// The global file, created from a template if missing.
    public func ensure(_ file: GlobalConfigFolder.File) async throws -> URL {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        return try await Self.ensure(folder, file: file)
    }

    public func ensure(_ kind: GlobalConfigFolder.Folder) async throws -> URL {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        return try await Self.ensure(folder, kind: kind)
    }

    private nonisolated static func ensure(_ folder: GlobalConfigFolder, file: GlobalConfigFolder.File) async throws -> URL {
        try folder.ensure(file).url
    }

    private nonisolated static func ensure(_ folder: GlobalConfigFolder, kind: GlobalConfigFolder.Folder) async throws -> URL {
        try folder.ensure(kind)
    }

    // MARK: Inventory

    /// Lists what the server reports for `directory` (the selected project, or nil for the global view), classifies
    /// sources and checks the configuration.
    public func refresh(directory: String?) async {
        await refresh(directory: directory, retryTrust: true)
    }

    private func refresh(directory: String?, retryTrust: Bool) async {
        await load()
        if retryTrust { await retryPendingTrust() }
        generation += 1
        let mine = generation
        refreshing = true
        defer { if mine == generation { refreshing = false } }
        let folder = self.folder
        let trustedNow = directory.map { isTrusted($0) } ?? false
        let policy = runningPolicy
        let syntax = await Self.syntaxError(folder)
        do {
            let client = try await client()
            let result = try await Self.inventory(
                client: client, directory: directory, folder: folder, projectLoaded: trustedNow || policy == .native)
            guard mine == generation, !Task.isCancelled else { return }
            inventory = result.inventory
            configProblem = syntax ?? result.ignoredConfig
            refreshError = nil
        } catch {
            guard mine == generation else { return }
            configProblem = syntax
            refreshError = (error as? OpenCodeError).map { String(describing: $0) } ?? error.localizedDescription
        }
    }

    private nonisolated static func syntaxError(_ folder: GlobalConfigFolder?) async -> String? { folder?.configSyntaxError() }

    /// opencode's built-in agents and commands (2.3.2).
    nonisolated static let builtInAgents: Set<String> = ["build", "general", "explore", "compaction", "title", "summary", "plan"]
    nonisolated static let builtInCommands: Set<String> = ["init", "review", "goal"]

    private nonisolated static func inventory(
        client: OpenCodeClient, directory: String?, folder: GlobalConfigFolder?, projectLoaded: Bool
    ) async throws -> (inventory: OpenCodeInventory, ignoredConfig: String?) {
        let location = directory
        async let agents = client.agents(directory: location)
        async let commands = client.commands(directory: location)
        async let skills = client.skills(directory: location)
        async let entries = client.configEntries(directory: location)
        async let plugins = client.plugins(directory: location ?? folder?.url.path ?? "/")
        // A failed plugin listing is a failed refresh (shown as stale), never "BelloCode's plugin is off" (N14).
        let (agentList, commandList, skillList, entryList, pluginList) = try await (agents, commands, skills, entries, plugins)

        // With its trailing slash, so a sibling such as `opencode-extra/` is not taken for the global folder (N33).
        let globalFolder = folder.map { Self.folderPrefix($0.url.standardizedFileURL.path) } ?? "\u{0}"
        let globalConfigPath = folder?.path(of: .config).standardizedFileURL.path
        var globalAgents = Set<String>(), globalCommands = Set<String>(), projectAgents = Set<String>(), projectCommands = Set<String>()
        var userPlugins: [String] = []
        var configListed = false
        var denyPolicy: String?
        for entry in entryList {
            guard entry["type"]?.stringValue == "document" else { continue }
            let path = entry["path"]?.stringValue
            let info = entry["info"]
            let isGlobal = path.map { ($0 as NSString).standardizingPath.hasPrefix(globalFolder) } ?? false
            if let path, (path as NSString).standardizingPath == globalConfigPath { configListed = true }
            let agentNames = info?["agents"]?.objectValue.map { Array($0.keys) } ?? []
            let commandNames = info?["commands"]?.objectValue.map { Array($0.keys) } ?? []
            if path == nil { continue }  // BelloCode's inline layer
            if isGlobal {
                globalAgents.formUnion(agentNames)
                globalCommands.formUnion(commandNames)
                for plugin in info?["plugins"]?.arrayValue ?? [] {
                    if let name = plugin.stringValue ?? plugin["package"]?.stringValue { userPlugins.append(name) }
                }
            } else {
                projectAgents.formUnion(agentNames)
                projectCommands.formUnion(commandNames)
            }
            for policy in info?["policies"]?.arrayValue ?? [] where policy["action"]?.stringValue == "plugin.use"
                && policy["effect"]?.stringValue == "deny" {
                denyPolicy = "\(path.map { ($0 as NSString).lastPathComponent } ?? "configuration") denies plugins (\"plugin.use\": \"\(policy["resource"]?.stringValue ?? "*")\")"
            }
        }
        let fileManager = FileManager.default
        func exists(_ base: String, _ kinds: [String], _ name: String) -> Bool {
            kinds.contains { fileManager.fileExists(atPath: "\(base)/\($0)/\(name).md") }
        }
        if let folder {
            let base = folder.url.path
            for name in ["plugins", "plugin"] {
                for file in (try? fileManager.contentsOfDirectory(atPath: "\(base)/\(name)")) ?? [] where !file.hasPrefix(".") {
                    userPlugins.append(file)
                }
            }
        }
        let globalBase = folder?.url.path ?? "\u{0}"
        let projectBase = directory.map { "\($0)/.opencode" } ?? "\u{0}"

        let agentItems = agentList.filter { !$0.hidden || !builtInAgents.contains($0.id) }.map { agent -> OpenCodeItem in
            let source: OpenCodeItemSource =
                builtInAgents.contains(agent.id) ? .builtIn
                : globalAgents.contains(agent.id) || exists(globalBase, ["agents", "agent"], agent.id) ? .global
                : projectAgents.contains(agent.id) || (projectLoaded && exists(projectBase, ["agents", "agent"], agent.id)) ? .project
                : .other
            return OpenCodeItem(kind: .agent, name: agent.id, detail: agent.description, source: source)
        }
        let commandItems = commandList.filter { $0.name != ContainerExecution.verifyCommandName }.map { command -> OpenCodeItem in
            let source: OpenCodeItemSource =
                builtInCommands.contains(command.name) ? .builtIn
                : globalCommands.contains(command.name) || exists(globalBase, ["commands", "command"], command.name) ? .global
                : projectCommands.contains(command.name) || (projectLoaded && exists(projectBase, ["commands", "command"], command.name)) ? .project
                : .other
            return OpenCodeItem(kind: .command, name: command.name, detail: command.description, source: source)
        }
        let skillItems = skillList.map { skill -> OpenCodeItem in
            let path = skill.path.map { ($0 as NSString).standardizingPath } ?? ""
            let source: OpenCodeItemSource =
                path.hasPrefix("skill://") || skill.path?.hasPrefix("skill://") == true ? .builtIn
                : path.hasPrefix(globalFolder) ? .global
                : directory.map { path.hasPrefix(($0 as NSString).standardizingPath + "/") } == true ? .project
                : .other
            return OpenCodeItem(kind: .skill, name: skill.name, detail: skill.description, source: source)
        }
        let bello = pluginList.first { $0.id == OrchestrationContract.pluginID }
        var problem: String?
        if bello?.status != "active" {
            let why = denyPolicy ?? bello.map { "its state is \($0.status)\($0.error.map { ": \($0)" } ?? "")" } ?? "it is not loaded"
            problem = "\(why.prefix(1).uppercased() + why.dropFirst()). Orchestration tools, the container guard hook and the environment contract are unavailable until this is fixed."
        }
        var skipped: [String] = []
        if projectLoaded, let directory, let status = try? await client.reloadStatus(directory: directory) { skipped = status }
        let configExists = globalConfigPath.map { fileManager.fileExists(atPath: $0) } ?? false
        let ignored = configExists && !configListed
            ? "opencode ignored opencode.json (it could not read it as a configuration document); its settings are not in effect."
            : nil
        let order: (OpenCodeItem, OpenCodeItem) -> Bool = { a, b in
            a.source == b.source ? a.name.localizedStandardCompare(b.name) == .orderedAscending
                : OpenCodeItemSource.allCases.firstIndex(of: a.source)! < OpenCodeItemSource.allCases.firstIndex(of: b.source)!
        }
        return (
            OpenCodeInventory(
                directory: directory ?? "", agents: agentItems.sorted(by: order), commands: commandItems.sorted(by: order),
                skills: skillItems.sorted(by: order), userPlugins: Array(Set(userPlugins)).sorted(), pluginProblem: problem,
                skipped: skipped),
            ignored
        )
    }

    /// `path` with exactly one trailing slash, for containment checks by prefix.
    nonisolated static func folderPrefix(_ path: String) -> String { path.hasSuffix("/") ? path : path + "/" }

    /// Snapshots and demos only: shows fixed values without a server.
    public func presentForSnapshots(inventory: OpenCodeInventory?, configProblem: String?, refreshError: String? = nil, trusted: [String] = [],
                                    runningPolicy: RepositoryConfigPolicy = .bellocode) {
        loaded = true
        self.inventory = inventory
        self.configProblem = configProblem
        self.refreshError = refreshError
        self.trusted = Dictionary(uniqueKeysWithValues: trusted.map { ($0, Date()) })
        self.runningPolicy = runningPolicy
        generation += 1
    }

    // MARK: Reload and restart

    /// `POST /api/location/reload`: every project re-reads its configuration (global files included). Pending
    /// approvals and questions are cancelled; running threads continue at their next step.
    public func reload(directory: String?) async -> String? {
        do {
            try await client().reloadLocations()
        } catch {
            return "opencode could not reload: \((error as? OpenCodeError).map { String(describing: $0) } ?? error.localizedDescription)"
        }
        await refresh(directory: directory)
        return nil
    }

    /// Restarts the supervised server (needed for a policy change). Running threads are interrupted.
    public func restart(policy: RepositoryConfigPolicy, directory: String?) async -> String? {
        guard let restartServer else { return "This server is not managed by BelloCode, so it cannot be restarted from here." }
        guard await restartServer() else { return "The server could not be restarted." }
        runningPolicy = policy
        // A new server reads the trust file at setup: what was written is now applied.
        if trustProblem == nil {
            unacknowledged = []
            trustPending = false
        }
        await refresh(directory: directory)
        return nil
    }
}

extension OpenCodeConfigService {
    /// The engine's service: the supervised server's directories and policy; restart through the engine core.
    static func make(configuration: EngineConfiguration, store: ProjectionStore, core: EngineCore) -> OpenCodeConfigService {
        guard case .supervised(let supervisor) = configuration.server else {
            return OpenCodeConfigService(store: store, directories: nil, runningPolicy: .bellocode,
                                         client: { try await core.currentClient() }, restartServer: nil)
        }
        return OpenCodeConfigService(
            store: store, directories: supervisor.configuration.directories, runningPolicy: supervisor.configuration.effectiveRepositoryConfig,
            client: { try await core.currentClient() }, restartServer: { await core.restartServer() })
    }
}

extension OpenCodeClient {
    /// The plugin's skipped-file list for a trusted project (names and reasons only).
    func reloadStatus(directory: String) async throws -> [String] {
        try await reloadProjectConfig(directory: directory, reload: false).skipped
    }
}
