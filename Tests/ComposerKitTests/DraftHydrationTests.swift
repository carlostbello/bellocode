import BelloCore
import Foundation
import Observation
import Testing
@testable import ComposerKit

/// A host whose stored draft arrives later, as an Engine thread's does (docs/reviews/M1-review.md, M1).
@MainActor
final class LateDraftHost: ComposerHost {
    let draftKey = "late"
    var isDraftLoaded = false
    var stored: ComposerDraft
    var saved: [ComposerDraft] = []
    private var listeners: [@MainActor () -> Void] = []
    var listenerCount: Int { listeners.count }

    init(stored: ComposerDraft) { self.stored = stored }

    func loadDraft() -> ComposerDraft { isDraftLoaded ? stored : .empty }
    func saveDraft(_ draft: ComposerDraft) {
        saved.append(draft)
        stored = draft
    }
    func send(_ submission: ComposerSubmission) async -> ComposerSendOutcome { .accepted }
    func stop() async {}
    var runState: ComposerRunState { .idle }
    func observe(_ onChange: @escaping @MainActor () -> Void) -> ComposerObservation {
        listeners.append(onChange)
        return ComposerObservation {}
    }

    /// The stored draft arrives (synchronously notifies, as a deterministic stand-in for the observation hop).
    func finishLoading() {
        isDraftLoaded = true
        for listener in listeners { listener() }
    }
}

@MainActor
@Suite struct DraftHydrationTests {
    @Test func untouchedComposerShowsTheDraftWhenItArrives() {
        let controller = ComposerController()
        let view = FakeView()
        view.bind(controller)
        let host = LateDraftHost(stored: ComposerDraft(text: "restored"))
        controller.attach(host)
        #expect(controller.awaitingDraft)
        #expect(view.draft == .empty)
        // Leaving before it arrives writes nothing over it.
        controller.flushDraft()
        #expect(host.saved.isEmpty)
        host.finishLoading()
        #expect(view.draft.text == "restored")
        #expect(!controller.awaitingDraft)
        #expect(host.saved.isEmpty)
    }

    /// A change reported before the draft arrives (the view is read-only then, so only a stray programmatic one) is
    /// never saved, even after the debounce; the loaded draft replaces it and nothing is written.
    @Test func anEditBeforeTheDraftArrivesIsNeverSaved() async {
        let controller = ComposerController()
        controller.draftSaveDelay = .zero
        let view = FakeView()
        view.bind(controller)
        let host = LateDraftHost(stored: ComposerDraft(text: "restored"))
        controller.attach(host)
        view.draft = ComposerDraft(text: "typed")
        controller.draftDidChange()
        for _ in 0..<5 { await Task.yield() }
        controller.flushDraft()
        #expect(host.saved.isEmpty)
        host.finishLoading()
        #expect(view.draft.text == "restored")
        #expect(host.saved.isEmpty)
    }

    /// AV2-02: Send while the draft loads is refused: nothing is sent, nothing (not even the empty clear) is saved over
    /// the stored draft, and the stored draft shows when it loads.
    @Test func sendingBeforeTheDraftArrivesIsRefused() async {
        let controller = ComposerController(registry: ComposerController.Registry())
        let view = FakeView()
        view.bind(controller)
        let host = LateDraftHost(stored: ComposerDraft(text: "restored"))
        controller.attach(host)
        view.draft = ComposerDraft(text: "shown")
        #expect(!controller.submit())
        #expect(controller.pendingSends == 0)
        #expect(host.saved.isEmpty)
        host.finishLoading()
        #expect(view.draft.text == "restored")
        #expect(host.saved.isEmpty)
    }

    /// While loading the composer shows the newest cached copy (read-only, never saved), then the loaded draft.
    @Test func aCachedCopyShowsWhileTheDraftLoads() async {
        let cache = ComposerDraftCache()
        cache.store(ComposerDraft(text: "cached copy"), for: "ses_1")
        let thread = FakeThread()
        thread.loaded = false
        let host = ThreadModelComposerHost(thread, cache: cache)
        let controller = ComposerController(registry: ComposerController.Registry())
        let view = FakeView()
        view.bind(controller)
        controller.attach(host)
        #expect(controller.awaitingDraft)
        #expect(!controller.acceptsEdits)
        #expect(view.draft.text == "cached copy")
        controller.flushDraft()
        #expect(thread.draft == "")
        thread.draft = "stored"
        thread.loaded = true
        for _ in 0..<1_000 where controller.awaitingDraft { await Task.yield() }
        #expect(controller.acceptsEdits)
        #expect(view.draft.text == "stored")
    }

    /// A draft that does not load in time (or whose host reports a failure) shows an error with Retry; Retry asks the
    /// host again; still nothing is written; the draft shows when it loads.
    @Test func aDraftThatDoesNotLoadOffersRetryAndWritesNothing() async {
        let thread = FakeThread()
        thread.loaded = false
        let host = ThreadModelComposerHost(thread, cache: ComposerDraftCache())
        let controller = ComposerController(registry: ComposerController.Registry())
        controller.draftLoadTimeout = .milliseconds(20)
        let view = FakeView()
        view.bind(controller)
        controller.attach(host)
        for _ in 0..<2_000 where !controller.draftLoadFailed { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(controller.draftLoadFailed)
        #expect(controller.draftLoadError != nil)
        controller.flushDraft()
        #expect(thread.draft == "")
        controller.draftLoadTimeout = .seconds(60)
        controller.retryDraftLoad()
        #expect(thread.retries == 1)
        #expect(!controller.draftLoadFailed)
        // The host reports a failure itself.
        thread.failed = true
        for _ in 0..<1_000 where !controller.draftLoadFailed { await Task.yield() }
        #expect(controller.draftLoadFailed)
        thread.failed = false
        thread.draft = "stored"
        thread.loaded = true
        for _ in 0..<1_000 where controller.awaitingDraft { await Task.yield() }
        #expect(!controller.awaitingDraft)
        #expect(controller.draftLoadError == nil)
        #expect(view.draft.text == "stored")
    }

    /// After a thread model is evicted and reopened, its tokens and selection come back from the draft cache once the
    /// stored text arrives; nothing typed in the gap overwrites the cache.
    @Test func richDraftSurvivesModelEviction() async throws {
        let cache = ComposerDraftCache()
        let token = ComposerToken(kind: .file, text: "@a", value: "a")
        let rich = ComposerDraft(
            text: "see @a", tokens: [PlacedToken(token: token, range: NSRange(location: 4, length: 2))],
            selection: NSRange(location: 6, length: 0))
        cache.store(rich, for: "ses_1")
        let thread = FakeThread()
        thread.loaded = false
        let host = ThreadModelComposerHost(thread, cache: cache)
        let controller = ComposerController()
        let view = FakeView()
        view.bind(controller)
        controller.attach(host)
        // Shown read-only from the cache meanwhile (never blank), and not editable.
        #expect(view.draft == rich)
        #expect(!controller.acceptsEdits)
        thread.draft = "see @a"
        thread.loaded = true
        for _ in 0..<1_000 where controller.awaitingDraft { await Task.yield() }
        #expect(!controller.awaitingDraft)
        #expect(view.draft == rich)
        #expect(cache.draft(for: "ses_1") == rich)
    }

    @Test func threadAdapterReportsHydration() {
        let thread = FakeThread()
        let host = ThreadModelComposerHost(thread, cache: ComposerDraftCache())
        #expect(host.isDraftLoaded)
        thread.loaded = false
        #expect(!host.isDraftLoaded)
    }
}

/// M4: an unconfirmed send is not "Not sent": the composer stays clear and says delivery is unknown.
@MainActor
@Suite struct UnconfirmedSendTests {
    @Test func unconfirmedOutcomeKeepsTheComposerClear() async {
        let controller = ComposerController()
        let view = FakeView()
        view.bind(controller)
        let host = FakeComposerHost("a")
        host.outcomes = [.unconfirmed("Delivery unknown")]
        var announcements: [String] = []
        controller.announce = { announcements.append($0) }
        controller.attach(host)
        view.draft = ComposerDraft(text: "deploy")
        #expect(controller.submit())
        for _ in 0..<1_000 where controller.pendingSends > 0 { await Task.yield() }
        #expect(controller.pendingSends == 0)
        #expect(view.draft == .empty)
        #expect(host.draft == .empty)
        #expect(controller.errorMessage == "Delivery unknown")
        #expect(announcements.last == "Delivery unknown")
    }

    @Test func adapterMapsUnknownDelivery() async {
        let thread = FakeThread()
        thread.nextResult = nil
        thread.unknown = true
        let host = ThreadModelComposerHost(thread, cache: ComposerDraftCache())
        let outcome = await host.send(ComposerSubmission(text: "x", tokens: [], attachments: [], delivery: .now))
        guard case .unconfirmed = outcome else {
            Issue.record("expected unconfirmed, got \(outcome)")
            return
        }
    }
}
