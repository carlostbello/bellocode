import BelloCore
import Foundation
import Testing
@testable import ComposerKit

/// The rich-draft cache is process-wide and keyed by session ID. Two thread sources with the same session ID (two
/// engines in one process, as in the app test suites, where every shell runs the same mock fixture) must not replace
/// each other's tokens. Observed as a flaky `IntegratedShellTests.sendStreamApproveQueueStopAndSwitch`: the draft's
/// `@README.md` token was missing after switching back, while a concurrently running suite's shell sent from the same
/// session ID (which stores an empty draft for it).
@MainActor
@Suite struct DraftCacheIsolationTests {
    static let rich: ComposerDraft = {
        let token = ComposerToken(kind: .file, text: "@README.md", value: "/tmp/README.md")
        return ComposerDraft(
            text: "Draft for later about @README.md", tokens: [PlacedToken(token: token, range: NSRange(location: 22, length: 10))],
            selection: NSRange(location: 32, length: 0))
    }()

    @Test func anotherSourceWithTheSameSessionIDDoesNotReplaceTheRichDraft() {
        let cache = ComposerDraftCache()
        let mine = FakeThread()
        let theirs = FakeThread()  // another engine's thread with the same server session ID
        #expect(mine.sessionID == theirs.sessionID)
        let controller = ComposerController()
        let view = FakeView()
        view.bind(controller)
        controller.attach(ThreadModelComposerHost(mine, cache: cache))
        view.draft = Self.rich
        controller.draftDidChange()
        controller.attach(nil)  // switch away: the draft is flushed with its token
        #expect(mine.draft == Self.rich.text)

        // Meanwhile the other engine's composer sends from its thread: it stores an empty draft under the same key.
        let other = ThreadModelComposerHost(theirs, cache: cache)
        other.saveDraft(ComposerDraft(text: "Please greet the world in the README."))
        other.saveDraft(.empty)

        controller.attach(ThreadModelComposerHost(mine, cache: cache))
        #expect(view.draft.text == Self.rich.text)
        #expect(view.draft.tokens.map(\.token.text) == ["@README.md"], "tokens restored after switching back")
        #expect(view.draft == Self.rich)
        #expect(ThreadModelComposerHost(theirs, cache: cache).loadDraft() == .empty)
    }

    /// A reopened thread (a new model instance for the same session) still gets its tokens back while the text matches.
    @Test func reopenedSourceStillRestoresTokens() {
        let cache = ComposerDraftCache()
        let first = FakeThread()
        ThreadModelComposerHost(first, cache: cache).saveDraft(Self.rich)
        let reopened = FakeThread()
        reopened.draft = Self.rich.text
        #expect(ThreadModelComposerHost(reopened, cache: cache).loadDraft() == Self.rich)
        reopened.draft = "changed elsewhere"
        #expect(ThreadModelComposerHost(reopened, cache: cache).loadDraft() == ComposerDraft(text: "changed elsewhere"))
    }
}
