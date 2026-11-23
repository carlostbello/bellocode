import BelloCore
import Darwin
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

    /// A missing field is the default; a field that is present but does not decode (damaged, or a choice from another
    /// version) makes the whole value unreadable rather than silently the default, so it never replaces a saved
    /// choice or the plugin's copy of it (AF27).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gitText = try container.decodeIfPresent(ModelChoice.self, forKey: .gitText) ?? .sameAsThread
        delegated = try container.decodeIfPresent(ModelChoice.self, forKey: .delegated) ?? .sameAsThread
    }
}

/// Settings ▸ Models below the UI (docs/features/models.md): opencode's default and small model (written to BelloCode's
/// isolated global `opencode.json`, then the server reloads), and the models of background tasks. `engine.models`.
///
/// Threading: `@MainActor`; file reads and writes and HTTP run off it and hand back values. Every read and write of
/// `opencode.json` and every preference change runs one at a time, in order (`serially`), and what is shown comes from
/// what was committed: a write re-reads the file before it reports success (A17). Storage and mirror failures are
/// returned to the caller and kept in `storageProblem`, never only logged (A29).
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
    /// A background-task choice that could not be saved, or the plugin's copy that could not be written (retried at
    /// the next change or load). Nil when everything is stored.
    public private(set) var storageProblem: String?

    /// The global configuration folder, or nil when the server is not BelloCode's own (attached, tests).
    public let folder: GlobalConfigFolder?
    @ObservationIgnored let modelDefaultsFile: URL?
    @ObservationIgnored private let store: ProjectionStore
    @ObservationIgnored private let client: @Sendable () async throws -> OpenCodeClient
    @ObservationIgnored weak var engine: Engine?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let log = Logger(subsystem: "app.bellocode", category: "models")
    /// The last queued operation: the next one starts after it (rule 9: owned by the service, awaited by callers).
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private let writeDefaults: @Sendable (ModelDefaultsFile, URL) throws -> Void
    @ObservationIgnored private let savePreference: @Sendable (ProjectionStore, BackgroundModelSettings) async throws -> Void
    @ObservationIgnored private let loadPreference: @Sendable (ProjectionStore) async throws -> BackgroundModelSettings?
    /// The plugin's defaults file does not match the saved choice yet.
    @ObservationIgnored private var mirrorStale = false
    /// The saved choice could not be read (unlike an absent one, which means the defaults): the shown defaults are a
    /// fallback, so neither the plugin's copy nor a save is derived from them until a read succeeds.
    @ObservationIgnored private var preferenceUnread = false

    static let key = "models.background"

    public init(
        store: ProjectionStore, folder: GlobalConfigFolder?, modelDefaultsFile: URL?, client: @escaping @Sendable () async throws -> OpenCodeClient,
        writeDefaults: @escaping @Sendable (ModelDefaultsFile, URL) throws -> Void = { try $0.write(to: $1) },
        savePreference: @escaping @Sendable (ProjectionStore, BackgroundModelSettings) async throws -> Void = { store, value in
            try await store.setPreference("models.background", value)
        },
        loadPreference: @escaping @Sendable (ProjectionStore) async throws -> BackgroundModelSettings? = { store in
            try await store.preference("models.background", as: BackgroundModelSettings.self)
        }
    ) {
        self.store = store
        self.folder = folder
        self.modelDefaultsFile = modelDefaultsFile
        self.client = client
        self.writeDefaults = writeDefaults
        self.savePreference = savePreference
        self.loadPreference = loadPreference
    }

    /// Runs `operation` after every operation queued before it.
    private func serially<T: Sendable>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    /// Reads the preferences and the configured models, and rewrites the plugin's defaults file. Call at start.
    /// A saved choice that cannot be read keeps the plugin's copy as it is (it matches the last confirmed choice) and
    /// stays reported; the read is retried before the next change.
    public func load() async {
        await serially { [self] in
            if await readPreference() == nil {
                mirrorStale = true
                _ = await writeDefaultsFile()
            }
            await performReadConfig()
            loaded = true
        }
    }

    /// Reads the saved choice (absent: the defaults). Returns the problem to show when it cannot be read.
    private func readPreference() async -> String? {
        do {
            background = try await loadPreference(store) ?? .standard
            preferenceUnread = false
            return nil
        } catch {
            preferenceUnread = true
            let text = "Could not read the saved background-task models (\(error.localizedDescription)); the defaults are shown and nothing was changed."
            storageProblem = text
            return text
        }
    }

    /// Before a change: a choice that could not be read at load is read again (and mirrored), so a save never
    /// replaces the other, unread field with a default. Returns the problem when it still cannot be read.
    private func ensurePreferenceRead() async -> String? {
        guard preferenceUnread else { return nil }
        if let problem = await readPreference() { return problem }
        storageProblem = nil
        mirrorStale = true
        _ = await writeDefaultsFile()
        return nil
    }

    /// Re-reads `opencode.json` (the person may have edited it). Queued behind any save, so an older read never
    /// replaces a newer save.
    public func readConfig() async {
        await serially { [self] in await performReadConfig() }
    }

    private func performReadConfig() async {
        guard let folder else { return }
        let state = await Self.read(folder)
        configuredDefault = state.model
        configuredSmall = state.small
        configProblem = state.problem
    }

    // MARK: Background tasks

    /// Saves the git-writing choice. Returns a problem to show (the previous choice stays), or nil.
    @discardableResult
    public func setGitText(_ choice: ModelChoice) async -> String? {
        await serially { [self] in
            if let problem = await ensurePreferenceRead() { return problem }
            var next = background
            next.gitText = choice
            return await save(next)
        }
    }

    /// Saves the delegated-thread choice and mirrors it to the plugin's file. Returns a problem to show, or nil.
    @discardableResult
    public func setDelegated(_ choice: ModelChoice) async -> String? {
        await serially { [self] in
            if let problem = await ensurePreferenceRead() { return problem }
            var next = background
            next.delegated = choice
            let changed = next.delegated != background.delegated
            if let problem = await save(next) { return problem }
            if changed { mirrorStale = true }
            return await writeDefaultsFile()
        }
    }

    /// Stores `next`; only then is it shown. A failure keeps the confirmed value and is returned.
    private func save(_ next: BackgroundModelSettings) async -> String? {
        do {
            try await savePreference(store, next)
        } catch {
            let text = "Could not save the model choice (\(error.localizedDescription)); the previous choice is still in use."
            storageProblem = text
            return text
        }
        background = next
        if !mirrorStale { storageProblem = nil }
        return nil
    }

    /// Mirrors the delegated choice for the plugin. On failure the plugin keeps the previous choice: said so, and retried
    /// at the next change or load.
    private func writeDefaultsFile() async -> String? {
        guard let file = modelDefaultsFile, mirrorStale else { return nil }
        let value = ModelDefaultsFile(delegated: background.delegated.token)
        do {
            try await Self.write(value, to: file, with: writeDefaults)
            mirrorStale = false
            storageProblem = nil
            return nil
        } catch {
            log.error("model defaults file not written")
            let text = "Saved, but delegated threads still use the previous model: BelloCode could not update its plugin's copy (\(error.localizedDescription))."
            storageProblem = text
            return text
        }
    }

    private nonisolated static func write(
        _ value: ModelDefaultsFile, to file: URL, with writer: @Sendable (ModelDefaultsFile, URL) throws -> Void
    ) async throws { try writer(value, file) }

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

    private func write(_ selection: ModelSelection?, at path: [String], reload: Bool, applied: @escaping @MainActor () -> Void) async -> String? {
        guard let folder else { return "This opencode server is not managed by BelloCode, so its configuration cannot be changed here." }
        generation += 1
        let mine = generation
        saving = true
        defer { if mine == generation { saving = false } }
        let saved: String? = await serially { [self] in
            do {
                try await Self.edit(folder, path: path, value: selection?.token)
            } catch {
                let text = (error as? JSONCEditor.EditError)?.description ?? "Could not save opencode.json: \(error.localizedDescription)"
                await performReadConfig()
                configProblem = text
                return text
            }
            // What is shown is what the file now says (another program may have saved too).
            await performReadConfig()
            if configProblem == nil { applied() }
            return nil
        }
        if let saved { return saved }
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
    /// file that does not parse is never rewritten. BelloCode's own edits are serialised by the caller; against other
    /// programs (an editor, the CLI) the file is compared just before the replace, and after it the value is read back:
    /// if someone else's save replaced ours, the edit is reported as not saved rather than claimed (A17).
    ///
    /// The replace itself keeps what it displaces (AF24): the new text is swapped in (`RENAME_SWAP`, atomic), and the
    /// file that was in place is checked against the one the edit was made from. A save that landed between the
    /// comparison and the swap is put back and the edit starts again from it; if yet another save landed meanwhile,
    /// that one is kept beside the file as `opencode.json.conflict-<time>` and the edit fails saying so. Another
    /// program's save is never silently replaced, and never deleted: the staged file is removed only while it holds
    /// BelloCode's own text or the version the edit was made from; if a displaced save cannot be moved to its conflict
    /// name, it stays in the staged file and the error names that file (AF24). `preserve` is the move (tests).
    nonisolated static func edit(
        _ folder: GlobalConfigFolder, path: [String], value: String?, attempt: Int = 0,
        beforeReplace: @Sendable () -> Void = {}, beforeSwap: @Sendable () -> Void = {}, afterSwap: @Sendable () -> Void = {},
        afterReplace: @Sendable () -> Void = {},
        preserve: @Sendable (URL, URL) throws -> URL = { try keepConflictCopy($0, beside: $1) }
    ) async throws {
        let url = try folder.ensure(.config).url
        let original = try String(contentsOf: url, encoding: .utf8)
        let updated = try JSONCEditor.setString(value, at: path, in: original)
        guard updated != original else { return }
        func again() async throws {
            guard attempt < 3 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "opencode.json keeps changing; try again."]) }
            try await edit(folder, path: path, value: value, attempt: attempt + 1, afterReplace: afterReplace, preserve: preserve)
        }
        beforeReplace()
        // Someone else changed it meanwhile: start again from theirs rather than overwrite it.
        guard try String(contentsOf: url, encoding: .utf8) == original else { return try await again() }
        let staged = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).bellocode-\(UUID().uuidString)")
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o644
        guard FileManager.default.createFile(atPath: staged.path, contents: Data(updated.utf8), attributes: [.posixPermissions: permissions]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Could not save opencode.json."])
        }
        // Removed on the way out only while it holds nothing but our own text or the version the edit started from.
        var stagedIsDisposable = true
        defer { if stagedIsDisposable { try? FileManager.default.removeItem(at: staged) } }
        /// `staged` holds another program's save: move it to a conflict name, or leave it where it is and say so.
        func keep(_ message: (String) -> String) -> CocoaError {
            stagedIsDisposable = false
            guard let copy = try? preserve(staged, url) else {
                return CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: message(staged.lastPathComponent)])
            }
            return CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: message(copy.lastPathComponent)])
        }
        beforeSwap()
        guard renamex_np(url.path, staged.path, UInt32(RENAME_SWAP)) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Could not save opencode.json (\(String(cString: strerror(errno))))."])
        }
        afterSwap()
        // `staged` now holds the file that was in place.
        guard (try? String(contentsOf: staged, encoding: .utf8)) == original else {
            // A save landed between the comparison and the swap: put it back, then edit it.
            guard renamex_np(url.path, staged.path, UInt32(RENAME_SWAP)) == 0 else {
                throw keep { "another program saved opencode.json at the same moment and it could not be put back; its version is in \($0)." }
            }
            // What the swap back displaced should be our own text; anything else is a further save, kept aside.
            if (try? String(contentsOf: staged, encoding: .utf8)) != updated {
                throw keep { "other programs saved opencode.json at the same moment, so this choice was not saved; one of their versions is in \($0)." }
            }
            return try await again()
        }
        afterReplace()
        let committed = try String(contentsOf: url, encoding: .utf8)
        guard JSONCEditor.string(at: path, in: committed) == value else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "another program saved opencode.json at the same moment, so this choice was not saved; choose it again."])
        }
    }

    /// Moves `file` to `opencode.json.conflict-<time>` beside `url`, never over an existing file: each name is taken with
    /// an exclusive rename (`RENAME_EXCL`), so a file that appears under that name meanwhile makes it try the next one
    /// instead of being replaced. Returns the new URL; throws (leaving `file` in place) when no name can be taken.
    nonisolated static func keepConflictCopy(_ file: URL, beside url: URL, stamp: String? = nil) throws -> URL {
        let stamp = stamp ?? ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let folder = url.deletingLastPathComponent()
        for suffix in 1...100 {
            let copy = folder.appending(path: "\(url.lastPathComponent).conflict-\(stamp)" + (suffix == 1 ? "" : "-\(suffix)"))
            if renamex_np(file.path, copy.path, UInt32(RENAME_EXCL)) == 0 { return copy }
            guard errno == EEXIST else { break }
        }
        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Could not keep a conflict copy of opencode.json."])
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

extension Engine {
    /// Snapshots and demos against a server BelloCode does not manage: Settings ▸ Models edits `folder`'s
    /// `opencode.json` instead (the server still reloads).
    public func useModelSettings(folder: GlobalConfigFolder) async {
        let core = self.core
        models = ModelSettingsService(
            store: store, folder: folder, modelDefaultsFile: folder.url.appending(path: "bellocode-models.json"),
            client: { try await core.currentClient() })
        models.engine = self
        await models.load()
    }
}
