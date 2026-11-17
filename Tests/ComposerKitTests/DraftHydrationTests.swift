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

    @Test func typingBeforeTheDraftArrivesIsMergedAfterIt() async {
        let controller = ComposerController()
        controller.draftSaveDelay = .zero
        let view = FakeView()
        view.bind(controller)
        let host = LateDraftHost(stored: ComposerDraft(text: "restored"))
        controller.attach(host)
        view.draft = ComposerDraft(text: "typed")
        controller.draftDidChange()
        // Even after the debounce, nothing replaces the stored draft.
        for _ in 0..<5 { await Task.yield() }
        #expect(host.saved.isEmpty)
        #expect(host.stored.text == "restored")
        host.finishLoading()
        #expect(view.draft.text == "restored\n\ntyped")
        #expect(host.saved.last?.text == "restored\n\ntyped")
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
        #expect(view.draft == .empty)
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
