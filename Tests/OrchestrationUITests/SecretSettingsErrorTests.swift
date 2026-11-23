import BelloCore
import Engine
import Foundation
import SecretKit
import Testing

@testable import OrchestrationUI

/// v1.0.1 verification (docs/reviews/v1.0.1-neon-verification.md): the raw-egress field shows the saved entries of the
/// project it saves to, so Save never wipes them (NV06); Settings actions that fail say so (NV12).
@Suite(.timeLimit(.minutes(3)))
@MainActor
struct SecretSettingsErrorTests {
    /// NV06: first display with a single project; the field is loaded before anything can be saved, and Save keeps
    /// the saved entry plus the typed one.
    @Test func theRawEgressFieldLoadsTheFirstProjectsSavedEntries() {
        var saved: [String: [String]] = ["/code/app": ["db.internal:5432"]]
        let read = { (project: String) in saved[project] ?? [] }
        let state = SecretsSettingsState()
        // Save before the field was ever loaded (the old view used `rawProject ?? projects[0]` with a blank field).
        state.saveRaw(["/code/app"], read: read) { entries, project in saved[project] = entries }
        #expect(saved["/code/app"] == ["db.internal:5432"], "saved with an unloaded field: the entry was wiped")

        state.syncRawProject(["/code/app"], read: read)
        #expect(state.rawProject == "/code/app")
        #expect(state.rawText == "db.internal:5432", "the saved entry is shown")
        state.rawText += ", git.example.com:22"
        state.saveRaw(["/code/app"], read: read) { entries, project in saved[project] = entries }
        #expect(saved["/code/app"] == ["db.internal:5432", "git.example.com:22"])

        // Projects change: text typed for a project still listed stays; a project that goes moves to the first.
        state.rawText = "typed:1"
        state.syncRawProject(["/code/app", "/code/other"], read: read)
        #expect(state.rawText == "typed:1")
        state.syncRawProject(["/code/other"], read: read)
        #expect(state.rawProject == "/code/other" && state.rawText.isEmpty)
        state.syncRawProject([], read: read)
        #expect(state.rawProject == nil)
    }

    /// NV12: a revoke or restore that fails is shown.
    @Test func aFailedSecretActionIsShown() async {
        struct StoreDown: Error, CustomStringConvertible { var description: String { "the database is read-only" } }
        let state = SecretsSettingsState()
        await state.perform { throw StoreDown() }
        #expect(state.error?.contains("read-only") == true, "\(state.error ?? "nil")")
        await state.perform {}
        #expect(state.error == nil, "a later success clears it")
    }

    /// NV12: the Keychain refuses the replacement GitLab token: the failure is shown, the typed token stays to retry,
    /// and the old token is not tested as if it were the new one.
    @Test func aReplacementTokenThatCannotBeSavedIsReported() async throws {
        let instance = MergeRequestPanelModelTests.instance
        let server = FakeGitLabServer(instance: instance, token: MergeRequestPanelModelTests.token)
        let vault = RefusingWritesVault()
        try vault.inner.store(account: instance.baseURL, label: "t", value: SecretValue(MergeRequestPanelModelTests.token))
        let service = MergeRequestService(store: try ProjectionStore(location: .inMemory), clock: ManualWallClock(Date(timeIntervalSince1970: 1_800_000_000)),
                                          transport: server, tokens: vault, autoPoll: false)
        await service.start()
        _ = try await service.saveInstance(baseURL: instance.baseURL, token: nil)
        let model = GitLabSettingsModel(service: service)
        model.token = "glpat-NEW-TOKEN-0123456789"
        await model.replaceToken(instance)
        let result = try #require(model.results[instance.baseURL])
        #expect(result.contains("not saved"), "\(result)")
        #expect(!result.contains("Connected"), "the old token was reported as the new one")
        #expect(model.token == "glpat-NEW-TOKEN-0123456789", "kept to retry")
    }
}

/// A Keychain that reads but refuses every write.
final class RefusingWritesVault: SecretVault {
    struct Refused: Error, CustomStringConvertible { var description: String { "the Keychain refused the write" } }
    let inner = InMemorySecretVault()
    func store(account: String, label: String, value: SecretValue) throws { throw Refused() }
    func read(account: String) throws -> SecretValue? { try inner.read(account: account) }
    func delete(account: String) throws { try inner.delete(account: account) }
}
