import BelloCore
import Foundation
import Observation
import OpenCodeKit
import os

/// Background-task model settings kept by BelloCode (`app_preference` key `models.background`). Auto's reviewer keeps
/// its own in `AutoReviewer.Settings` (`auto.reviewer`).
public struct BackgroundModelSettings: Codable, Sendable, Hashable {
    /// Commit messages, branch names, merge request title and description.
    public var gitText: ModelChoice
    /// Delegated child threads (`delegate_task`) and scheduled runs that name no model.
    public var delegated: ModelChoice

    public static let standard = BackgroundModelSettings(gitText: .sameAsThread, delegated: .sameAsThread)

    public init(gitText: ModelChoice, delegated: ModelChoice) {
        self.gitText = gitText
        self.delegated = delegated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gitText = (try? container.decodeIfPresent(ModelChoice.self, forKey: .gitText)) ?? .sameAsThread
        delegated = (try? container.decodeIfPresent(ModelChoice.self, forKey: .delegated)) ?? .sameAsThread
    }
}

/// Settings ▸ Models below the UI (docs/features/models.md): opencode's default and small model (written to BelloCode's
/// isolated global `opencode.json`, then the server reloads), and the models of background tasks. `engine.models`.
///
/// Threading: `@MainActor`; file reads and writes and HTTP run off it and hand back values. A write applies only if it
/// is the newest (generation check).
@MainActor
@Observable
public final class ModelSettingsService {
    /// opencode's `model` in the global `opencode.json` (nil: not set there; opencode picks).
    public private(set) var configuredDefault: ModelSelection?
    /// opencode's `agents.title.model` (thread titles; what `small_model` was before opencode 2).
    public private(set) var configuredSmall: ModelSelection?
    public private(set) var background: BackgroundModelSettings = .standard
    /// A problem reading or writing `opencode.json` (syntax error with its position, no folder, write failure).
    public private(set) var configProblem: String?
    /// The global `opencode.json` changed and opencode has not reloaded it yet (approvals were pending).
    public private(set) var reloadPending = false
    public private(set) var saving = false
    public private(set) var loaded = false

    /// The global configuration folder, or nil when the server is not BelloCode's own (attached, tests).
    public let folder: GlobalConfigFolder?
    @ObservationIgnored let modelDefaultsFile: URL?
    @ObservationIgnored private let store: ProjectionStore
    @ObservationIgnored private let client: @Sendable () async throws -> OpenCodeClient
    @ObservationIgnored weak var engine: Engine?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let log = Logger(subsystem: "app.bellocode", category: "models")

    static let key = "models.background"

    public init(
        store: ProjectionStore, folder: GlobalConfigFolder?, modelDefaultsFile: URL?, client: @escaping @Sendable () async throws -> OpenCodeClient
    ) {
        self.store = store
        self.folder = folder
        self.modelDefaultsFile = modelDefaultsFile
        self.client = client
    }

    /// Reads the preferences and the configured models, and rewrites the plugin's defaults file. Call at start.
    public func load() async {
        if let saved = try? await store.preference(Self.key, as: BackgroundModelSettings.self) { background = saved }
        await writeDefaultsFile()
        await readConfig()
        loaded = true
    }

    /// Re-reads `opencode.json` (the person may have edited it).
    public func readConfig() async {
        guard let folder else { return }
        let state = await Self.read(folder)
        configuredDefault = state.model
        configuredSmall = state.small
        configProblem = state.problem
    }

    // MARK: Background tasks

    public func setGitText(_ choice: ModelChoice) async {
        background.gitText = choice
        try? await store.setPreference(Self.key, background)
    }

    public func setDelegated(_ choice: ModelChoice) async {
        background.delegated = choice
        try? await store.setPreference(Self.key, background)
        await writeDefaultsFile()
    }

    private func writeDefaultsFile() async {
        guard let file = modelDefaultsFile else { return }
        let value = ModelDefaultsFile(delegated: background.delegated.token)
        do { try await Self.write(value, to: file) } catch { log.error("model defaults file not written") }
    }

    private nonisolated static func write(_ value: ModelDefaultsFile, to file: URL) async throws { try value.write(to: file) }

    // MARK: opencode's default and small model

    /// The default model for new threads: opencode's `model` (nil removes it, so opencode picks). Returns a problem to
    /// show, or nil. `reload` false saves only (approvals are pending; the person reloads later).
    @discardableResult
    public func setDefaultModel(_ selection: ModelSelection?, reload: Bool = true) async -> String? {
        await write(selection, at: ["model"], reload: reload) { self.configuredDefault = selection }
    }

    /// The small model: opencode's `title` agent model (thread titles). nil removes it (opencode then uses a fast
    /// model of the thread's provider, or the thread's model).
    @discardableResult
    public func setSmallModel(_ selection: ModelSelection?, reload: Bool = true) async -> String? {
        await write(selection, at: ["agents", "title", "model"], reload: reload) { self.configuredSmall = selection }
    }

    private func write(_ selection: ModelSelection?, at path: [String], reload: Bool, applied: () -> Void) async -> String? {
        guard let folder else { return "This opencode server is not managed by BelloCode, so its configuration cannot be changed here." }
        generation += 1
        let mine = generation
        saving = true
        defer { if mine == generation { saving = false } }
        do {
            try await Self.edit(folder, path: path, value: selection?.token)
        } catch {
            let text = (error as? JSONCEditor.EditError)?.description ?? "Could not save opencode.json: \(error.localizedDescription)"
            configProblem = text
            return text
        }
        configProblem = nil
        applied()
        guard reload else {
            reloadPending = true
            return nil
        }
        return await reloadServer()
    }

    /// `POST /api/location/reload`, then fresh catalogs (the default model is part of them). Pending approvals and
    /// questions are cancelled by opencode: callers confirm first when there are any.
    @discardableResult
    public func reloadServer() async -> String? {
        do {
            try await client().reloadLocations()
        } catch {
            reloadPending = true
            return "Saved. opencode could not reload now (\((error as? OpenCodeError).map { String(describing: $0) } ?? error.localizedDescription)); it applies at the next reload or restart."
        }
        reloadPending = false
        await engine?.refreshAllCatalogs()
        return nil
    }

    // MARK: Files (off the main actor)

    struct ConfigState: Sendable {
        var model: ModelSelection?
        var small: ModelSelection?
        var problem: String?
    }

    nonisolated static func read(_ folder: GlobalConfigFolder) async -> ConfigState {
        guard let data = try? Data(contentsOf: folder.path(of: .config)) else { return ConfigState() }
        if let problem = JSONCheck.syntaxError(in: data) { return ConfigState(problem: problem) }
        let text = String(decoding: data, as: UTF8.self)
        func selection(_ path: [String]) -> ModelSelection? {
            let value = JSONCEditor.value(at: path, in: text)
            if let token = value as? String { return ModelSelection(token: token) }
            // The object form: {"providerID": …, "model": …, "variant": …}.
            if let object = value as? [String: Any], let provider = object["providerID"] as? String, let model = object["model"] as? String {
                return ModelSelection(providerID: provider, modelID: model, variant: object["variant"] as? String)
            }
            return nil
        }
        return ConfigState(model: selection(["model"]), small: selection(["agents", "title", "model"]))
    }

    /// Edits one value in place (comments and formatting kept), creating the file from its template when missing. A
    /// file that does not parse is never rewritten.
    nonisolated static func edit(_ folder: GlobalConfigFolder, path: [String], value: String?, attempt: Int = 0) async throws {
        let url = try folder.ensure(.config).url
        let original = try String(contentsOf: url, encoding: .utf8)
        let updated = try JSONCEditor.setString(value, at: path, in: original)
        guard updated != original else { return }
        // Someone else (an editor, the CLI) changed it meanwhile: start again from theirs rather than overwrite it.
        guard try String(contentsOf: url, encoding: .utf8) == original else {
            guard attempt < 3 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "opencode.json keeps changing; try again."]) }
            return try await edit(folder, path: path, value: value, attempt: attempt + 1)
        }
        try Data(updated.utf8).write(to: url, options: .atomic)
    }
}

extension ModelSettingsService {
    static func make(configuration: EngineConfiguration, store: ProjectionStore, core: EngineCore) -> ModelSettingsService {
        guard case .supervised(let supervisor) = configuration.server else {
            return ModelSettingsService(store: store, folder: nil, modelDefaultsFile: nil, client: { try await core.currentClient() })
        }
        let directories = supervisor.configuration.directories
        return ModelSettingsService(
            store: store, folder: GlobalConfigFolder(directories: directories), modelDefaultsFile: directories.modelDefaultsFile,
            client: { try await core.currentClient() })
    }
}
