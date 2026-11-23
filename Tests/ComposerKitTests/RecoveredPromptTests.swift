import BelloCore
import Foundation
import Testing
@testable import ComposerKit

/// v1.0.1 AV2-02: a prompt recovered outside the composer (Edit from Here's rewind) reaches every composer of its
/// thread and the stored rich draft, and nothing saves over it or drops the draft's tokens.
@MainActor
@Suite("Recovered prompts", .timeLimit(.minutes(3)))
struct RecoveredPromptTests {
    static let token = ComposerToken(kind: .file, text: "@a.swift", value: "a.swift")
    /// A draft with a file mention, as a composer saves it.
    static let rich = ComposerDraft(text: "see @a.swift now", tokens: [PlacedToken(token: token, range: NSRange(location: 4, length: 8))])

    /// Two windows show the thread: both take the prompt in front of what they show, so the next save from either keeps it.
    @Test func everyOpenComposerOfTheThreadTakesThePrompt() async {
        let registry = ComposerController.Registry()
        let thread = FakeThread()
        let owner = ObjectIdentifier(thread)
        var views: [FakeView] = []
        var controllers: [ComposerController] = []
        var hosts: [FakeComposerHost] = []
        for _ in 0..<2 {
            let controller = ComposerController(registry: registry)
            let view = FakeView()
            view.bind(controller)
            let host = FakeComposerHost("ses_1", draft: Self.rich)
            host.owner = owner
            controller.attach(host)
            views.append(view)
            controllers.append(controller)
            hosts.append(host)
        }
        // A composer of another thread is left alone.
        let other = ComposerController(registry: registry)
        let otherView = FakeView()
        otherView.bind(other)
        let otherHost = FakeComposerHost("ses_2", draft: ComposerDraft(text: "other"))
        otherHost.owner = ObjectIdentifier(FakeThread())
        other.attach(otherHost)

        let placement = await ComposerController.placeRecovered(ComposerDraft(text: "rewound"), into: hosts[0], registry: registry)
        #expect(placement == .composers(2))
        for (view, host) in zip(views, hosts) {
            #expect(view.draft.text == "rewound\n\nsee @a.swift now")
            #expect(view.draft.tokens.first?.range == NSRange(location: 13, length: 8), "the mention moves with its text")
            #expect(host.draft == view.draft, "saved through each composer's host")
        }
        #expect(otherView.draft.text == "other")
        // The second window's next edit saves its own view, which already holds the prompt.
        views[1].draft.text += "!"
        controllers[1].flushDraft()
        controllers[1].draftDidChange()
        controllers[1].flushDraft()
        #expect(hosts[1].draft.text.hasPrefix("rewound\n\n"))
        _ = other
    }

    /// No composer shows the thread: the prompt goes in front of the stored draft, its mention kept.
    @Test func withNoComposerTheStoredRichDraftKeepsItsTokens() async {
        let registry = ComposerController.Registry()
        let host = FakeComposerHost("ses_1", draft: Self.rich)
        host.owner = ObjectIdentifier(FakeThread())
        let placement = await ComposerController.placeRecovered(ComposerDraft(text: "rewound"), into: host, registry: registry)
        #expect(placement == .storedDraft)
        #expect(host.draft.text == "rewound\n\nsee @a.swift now")
        #expect(host.draft.tokens == [PlacedToken(token: Self.token, range: NSRange(location: 13, length: 8))])
    }

    /// The stored draft arrives later: it is awaited, then merged (never saved over before it is read).
    @Test func aDraftStillLoadingIsAwaited() async {
        let registry = ComposerController.Registry()
        let host = LateDraftHost(stored: Self.rich)
        let placing = Task { await ComposerController.placeRecovered(ComposerDraft(text: "rewound"), into: host, registry: registry) }
        #expect(await waitFor { host.listenerCount > 0 })
        #expect(host.saved.isEmpty, "nothing is saved over a draft that has not been read")
        host.finishLoading()
        #expect(await placing.value == .storedDraft)
        #expect(host.stored.text == "rewound\n\nsee @a.swift now")
        #expect(host.stored.tokens.first?.range == NSRange(location: 13, length: 8))
    }

    /// A draft that never loads is not saved over at all.
    @Test func aDraftThatNeverLoadsIsLeftAlone() async {
        let host = LateDraftHost(stored: Self.rich)
        let placement = await ComposerController.placeRecovered(
            ComposerDraft(text: "rewound"), into: host, registry: ComposerController.Registry(), timeout: .milliseconds(50))
        #expect(placement == .unloadedDraft)
        #expect(host.saved.isEmpty)
    }

    /// The thread adapter with a draft archive (relaunch): the archived mention survives the prompt going in front.
    @Test func anArchivedRichDraftKeepsItsTokensThroughTheThreadAdapter() async throws {
        let fixture = try DraftDurabilityTests.Fixture()
        defer { fixture.remove() }
        let archive = fixture.archive()
        await archive.write(Self.rich, for: "ses_1")
        let thread = FakeThread()
        thread.draft = Self.rich.text
        let host = ThreadModelComposerHost(thread, cache: ComposerDraftCache(), fileStore: fixture.files, archive: archive)
        let placement = await ComposerController.placeRecovered(ComposerDraft(text: "rewound"), into: host, registry: ComposerController.Registry())
        #expect(placement == .storedDraft)
        #expect(thread.draft == "rewound\n\nsee @a.swift now")
        _ = await archive.flush()
        let restored = try #require(archive.restore("ses_1", text: thread.draft))
        #expect(restored.tokens == [PlacedToken(token: Self.token, range: NSRange(location: 13, length: 8))])
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}
