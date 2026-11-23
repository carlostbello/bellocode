import BelloCore
import Foundation
import Synchronization
import Testing
@testable import Engine
@testable import OpenCodeKit

/// Settings ▸ Models storage (A17, A29, N15): edits are serialised and re-read, external saves are never overwritten
/// or claimed, and storage and mirror failures reach the caller.
@Suite("Model settings storage", .timeLimit(.minutes(3)))
@MainActor
struct ModelSettingsServiceTests {
    final class Flag: Sendable {
        let value = Mutex(false)
        var on: Bool { value.withLock { $0 } }
        func set(_ on: Bool) { value.withLock { $0 = on } }
    }
    struct Failure: Error, LocalizedError { var errorDescription: String? { "disk full" } }

    func make(_ root: URL, failMirror: Flag = Flag(), failStore: Flag = Flag()) throws -> (ModelSettingsService, GlobalConfigFolder, URL) {
        let folder = GlobalConfigFolder(url: root.appending(path: "config/opencode", directoryHint: .isDirectory))
        let defaults = root.appending(path: "bellocode-models.json")
        let service = ModelSettingsService(
            store: try ProjectionStore(location: .inMemory), folder: folder, modelDefaultsFile: defaults,
            client: { throw EngineError.offline },
            writeDefaults: { value, file in
                if failMirror.on { throw Failure() }
                try value.write(to: file)
            },
            savePreference: { store, value in
                if failStore.on { throw Failure() }
                try await store.setPreference(ModelSettingsService.key, value)
            })
        return (service, folder, defaults)
    }

    func text(_ folder: GlobalConfigFolder) throws -> String { try String(contentsOf: folder.path(of: .config), encoding: .utf8) }

    @Test func interleavedDefaultAndTitleWritesBothLand() async throws {
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (service, folder, _) = try make(root)
        await service.load()
        for round in 0..<8 {
            async let a = service.setDefaultModel(ModelSelection(providerID: "p", modelID: "default-\(round)"), reload: false)
            async let b = service.setSmallModel(ModelSelection(providerID: "p", modelID: "small-\(round)"), reload: false)
            #expect(await a == nil)
            #expect(await b == nil)
        }
        let file = try text(folder)
        #expect(JSONCEditor.string(at: ["model"], in: file) == "p/default-7")
        #expect(JSONCEditor.string(at: ["agents", "title", "model"], in: file) == "p/small-7")
        #expect(service.configuredDefault?.modelID == "default-7")
        #expect(service.configuredSmall?.modelID == "small-7")
    }

    @Test func anExternalSaveIsKeptAndAnOverwrittenEditIsNotClaimed() async throws {
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, folder, _) = try make(root)
        let url = try folder.ensure(.config).url
        // Someone saves between our read and our replace: their change is kept, ours applied on top.
        let once = Flag()
        try await ModelSettingsService.edit(folder, path: ["model"], value: "p/mine", beforeReplace: {
            if !once.on {
                once.set(true)
                try? Data("{\n  \"theirs\": true\n}\n".utf8).write(to: url, options: .atomic)
            }
        })
        let merged = try text(folder)
        #expect(JSONCEditor.value(at: ["theirs"], in: merged) as? Bool == true)
        #expect(JSONCEditor.string(at: ["model"], in: merged) == "p/mine")
        // Someone saves right after our replace: the edit is reported as not saved, theirs stays.
        await #expect(throws: CocoaError.self) {
            try await ModelSettingsService.edit(folder, path: ["model"], value: "p/second", afterReplace: {
                try? Data("{\n  \"model\": \"x/theirs\"\n}\n".utf8).write(to: url, options: .atomic)
            })
        }
        #expect(JSONCEditor.string(at: ["model"], in: try text(folder)) == "x/theirs")
    }

    /// AF24: an editor saves an unrelated setting after BelloCode's comparison and before its replace. The swap keeps
    /// the displaced file, sees it is not the one the edit was made from, puts it back and edits it: both survive.
    @Test func aSaveBetweenTheComparisonAndTheReplaceIsKept() async throws {
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, folder, _) = try make(root)
        let url = try folder.ensure(.config).url
        let once = Flag()
        try await ModelSettingsService.edit(folder, path: ["model"], value: "p/mine", beforeSwap: {
            if !once.on {
                once.set(true)
                try? Data("{\n  \"theme\": \"editor\"\n}\n".utf8).write(to: url, options: .atomic)
            }
        })
        #expect(once.on)
        let merged = try text(folder)
        #expect(JSONCEditor.string(at: ["theme"], in: merged) == "editor", "the editor's save survives")
        #expect(JSONCEditor.string(at: ["model"], in: merged) == "p/mine")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).filter { $0.contains("bellocode-") }
        #expect(leftovers.isEmpty, "\(leftovers)")
    }

    /// AF24: a save before the swap and a further one right after it: the first is put back and the second, which
    /// the put-back displaced, is kept beside the file; the edit fails saying so.
    @Test func aSecondRacingSaveIsKeptAsAConflictCopy() async throws {
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, folder, _) = try make(root)
        let url = try folder.ensure(.config).url
        await #expect(throws: CocoaError.self) {
            try await ModelSettingsService.edit(folder, path: ["model"], value: "p/mine", beforeSwap: {
                try? Data("{\n  \"theme\": \"first\"\n}\n".utf8).write(to: url, options: .atomic)
            }, afterSwap: {
                try? Data("{\n  \"theme\": \"second\"\n}\n".utf8).write(to: url, options: .atomic)
            })
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        let conflict = try #require(files.first { $0.hasPrefix("opencode.json.conflict-") })
        let kept = try String(contentsOf: url.deletingLastPathComponent().appending(path: conflict), encoding: .utf8)
        #expect(JSONCEditor.string(at: ["theme"], in: kept) == "second")
        #expect(JSONCEditor.string(at: ["theme"], in: try text(folder)) == "first")
        #expect(!files.contains { $0.contains("bellocode-") })
    }

    /// AF24 (second round): when the displaced save cannot be moved to a conflict name, it is not deleted with the
    /// staged file: it stays there and the error names it.
    @Test func aSaveThatCannotBeMovedAsideStaysInTheStagedFile() async throws {
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, folder, _) = try make(root)
        let url = try folder.ensure(.config).url
        var message = ""
        do {
            try await ModelSettingsService.edit(folder, path: ["model"], value: "p/mine", beforeSwap: {
                try? Data("{\n  \"theme\": \"first\"\n}\n".utf8).write(to: url, options: .atomic)
            }, afterSwap: {
                try? Data("{\n  \"theme\": \"second\"\n}\n".utf8).write(to: url, options: .atomic)
            }, preserve: { _, _ in throw CocoaError(.fileWriteFileExists) })
            Issue.record("the edit must fail")
        } catch let error as CocoaError {
            message = error.userInfo[NSLocalizedDescriptionKey] as? String ?? ""
        }
        let folderPath = url.deletingLastPathComponent().path
        let staged = try #require(try FileManager.default.contentsOfDirectory(atPath: folderPath).first { $0.contains("bellocode-") }, "the save was deleted")
        #expect(message.contains(staged), "\(message)")
        let kept = try String(contentsOfFile: folderPath + "/" + staged, encoding: .utf8)
        #expect(JSONCEditor.string(at: ["theme"], in: kept) == "second")
        #expect(JSONCEditor.string(at: ["theme"], in: try text(folder)) == "first")
    }

    /// AF24 (second round): a conflict copy never replaces a file already under its name; it takes the next one.
    @Test func aConflictCopyNeverReplacesAnExistingFile() throws {
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "opencode.json")
        for name in ["opencode.json.conflict-T", "opencode.json.conflict-T-2"] {
            try Data(name.utf8).write(to: root.appending(path: name))
        }
        let save = root.appending(path: "staged")
        try Data("theirs".utf8).write(to: save)
        let copy = try ModelSettingsService.keepConflictCopy(save, beside: url, stamp: "T")
        #expect(copy.lastPathComponent == "opencode.json.conflict-T-3")
        #expect(try String(contentsOf: copy, encoding: .utf8) == "theirs")
        #expect(try String(contentsOf: root.appending(path: "opencode.json.conflict-T"), encoding: .utf8) == "opencode.json.conflict-T")
        #expect(try String(contentsOf: root.appending(path: "opencode.json.conflict-T-2"), encoding: .utf8) == "opencode.json.conflict-T-2")
    }

    @Test func aFailedPreferenceSaveKeepsThePreviousChoiceAndSaysSo() async throws {
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let failStore = Flag()
        let (service, _, _) = try make(root, failStore: failStore)
        await service.load()
        failStore.set(true)
        let problem = await service.setGitText(.smallModel)
        #expect(problem?.contains("disk full") == true)
        #expect(service.background.gitText == .sameAsThread)
        #expect(service.storageProblem != nil)
        failStore.set(false)
        #expect(await service.setGitText(.smallModel) == nil)
        #expect(service.background.gitText == .smallModel)
        #expect(service.storageProblem == nil)
    }

    @Test func aFailedMirrorWriteIsReportedAndRetried() async throws {
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let failMirror = Flag()
        let (service, _, defaults) = try make(root, failMirror: failMirror)
        await service.load()
        failMirror.set(true)
        let chosen = ModelChoice.specific(ModelSelection(providerID: "openai", modelID: "gpt-x"))
        let problem = await service.setDelegated(chosen)
        #expect(problem?.contains("previous model") == true)
        #expect(service.storageProblem != nil)
        #expect(ModelDefaultsFile.read(from: defaults)?.delegated == "thread")
        failMirror.set(false)
        #expect(await service.setDelegated(chosen) == nil)  // unchanged choice, still mirrored now
        #expect(ModelDefaultsFile.read(from: defaults)?.delegated == chosen.token)
        #expect(service.storageProblem == nil)
    }

    /// AF27: a saved choice that cannot be read leaves the plugin's copy alone and stays reported; a change waits for
    /// a successful read, so the unread field is never replaced with a default.
    @Test func anUnreadablePreferenceKeepsTheMirrorAndTheWarning() async throws {
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectionStore(location: .inMemory)
        let defaults = root.appending(path: "bellocode-models.json")
        let failRead = Flag()
        func service() -> ModelSettingsService {
            ModelSettingsService(
                store: store, folder: nil, modelDefaultsFile: defaults, client: { throw EngineError.offline },
                loadPreference: { store in
                    if failRead.on { throw Failure() }
                    return try await store.preference(ModelSettingsService.key, as: BackgroundModelSettings.self)
                })
        }
        let chosen = ModelChoice.specific(ModelSelection(providerID: "openai", modelID: "gpt-x"))
        let first = service()
        await first.load()
        #expect(await first.setDelegated(chosen) == nil)
        #expect(ModelDefaultsFile.read(from: defaults)?.delegated == chosen.token)

        // Relaunch with the store failing to read: the mirror keeps the confirmed choice, the warning stays.
        failRead.set(true)
        let second = service()
        await second.load()
        #expect(ModelDefaultsFile.read(from: defaults)?.delegated == chosen.token)
        #expect(second.storageProblem?.contains("disk full") == true)
        // A change while it still cannot be read is refused; nothing is saved over the unread choice.
        #expect(await second.setGitText(.smallModel)?.contains("disk full") == true)
        #expect(try await store.preference(ModelSettingsService.key, as: BackgroundModelSettings.self)?.delegated == chosen)

        // Readable again: the change applies on top of the saved choice.
        failRead.set(false)
        #expect(await second.setGitText(.smallModel) == nil)
        #expect(second.background.delegated == chosen)
        #expect(second.background.gitText == .smallModel)
        #expect(ModelDefaultsFile.read(from: defaults)?.delegated == chosen.token)
        #expect(second.storageProblem == nil)
    }
}
