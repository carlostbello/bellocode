import AppKit
import BelloCore
import Foundation
import Testing
@testable import ComposerKit

/// v1.0.2 AV2-02, R5-01, R5-02: edits made in a composer before its thread's stored draft has loaded, and been observed
/// by that composer, used to be handed over and joined with the stored draft later; each join lost something. A
/// composer now takes no edit until it has observed its loaded draft, and saves nothing for that thread before then.
///
/// These drive the real `ComposerViewController` (typing, paste, file completion) on a thread whose stored rich draft
/// is archived and not loaded yet.
@MainActor
@Suite("Draft load gate", .serialized, .timeLimit(.minutes(3)))
struct DraftLoadGateTests {
    static let mention = ComposerToken(kind: .file, text: "@a.swift", value: "a.swift")
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])

    /// A thread whose stored draft is archived (`stored`) and has not loaded yet, behind a real thread adapter.
    @MainActor
    struct LoadingThread {
        let fixture: DraftDurabilityTests.Fixture
        let archive: ComposerDraftArchive
        let cache = ComposerDraftCache()
        let stored: ComposerDraft
        let thread = FakeThread()
        let host: ThreadModelComposerHost

        init(stored: ComposerDraft) async throws {
            fixture = try DraftDurabilityTests.Fixture()
            archive = fixture.archive()
            self.stored = stored
            if !stored.isEmpty {
                await archive.write(stored, for: "ses_1")
                _ = await archive.flush()
            }
            thread.loaded = false
            host = ThreadModelComposerHost(thread, cache: cache, fileStore: fixture.files, archive: archive)
        }

        /// The model reads its stored draft. Synchronous: no composer has observed it yet (its observation hop is a
        /// task that has not run).
        func modelLoads(text: String) {
            thread.draft = text
            thread.loaded = true
        }

        /// A new thread model for the same session (the window closed and released the last lease, or the model was
        /// evicted, and the thread was opened again): a new owner, sharing the process-wide cache and archive.
        func reopened(storedText: String) -> ThreadModelComposerHost {
            let fresh = FakeThread()
            fresh.draft = storedText
            return ThreadModelComposerHost(fresh, cache: cache, fileStore: fixture.files, archive: archive)
        }

        func record() async -> ComposerDraft? {
            _ = await archive.flush()
            return archive.load("ses_1")
        }
    }

    func mount(_ host: any ComposerHost) -> (ComposerViewController, NSWindow) {
        let composer = ComposerViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = composer
        window.makeFirstResponder(composer.textView)
        composer.host = host
        return (composer, window)
    }

    func pasteboard(png: Data) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("bellocode-test-\(UUID().uuidString)"))
        board.clearContents()
        board.setData(png, forType: .png)
        return board
    }

    /// AV2-02: the person types into the placeholder while the draft loads; the model then loads, and the person
    /// switches threads before the composer's queued observation ran. The switch-away flush must not save the
    /// placeholder edit over the loaded draft: its text, mention and attachment stay, in the thread, cache and archive.
    @Test func aSwitchAfterTheModelLoadsButBeforeTheComposerObservedItSavesNothing() async throws {
        var stored = ComposerDraft(
            text: "see @a.swift now", tokens: [PlacedToken(token: Self.mention, range: NSRange(location: 4, length: 8))])
        stored.attachments = [.text("log")]
        let loading = try await LoadingThread(stored: stored)
        defer { loading.fixture.remove() }
        let (composer, window) = mount(loading.host)
        defer { window.close() }

        composer.insert(text: "typed")
        loading.modelLoads(text: stored.text)
        // The switch, before any task (the composer's observation hop) has run.
        composer.host = FakeComposerHost("other")

        #expect(loading.thread.draft == stored.text, "the loaded draft's text is not replaced")
        let shown = loading.host.loadDraft()
        #expect(shown.text == stored.text)
        #expect(shown.tokens == stored.tokens, "its mention is kept")
        #expect(shown.attachments.map(\.id) == stored.attachments.map(\.id), "its attachment is kept")
        let record = try #require(await loading.record())
        #expect(record.text == stored.text)
        #expect(record.tokens == stored.tokens)
        #expect(record.attachments.map(\.id) == stored.attachments.map(\.id))
    }

    /// R5-01: an empty stored draft; the person pastes an image while it loads and switches threads; the window closes
    /// (or the model is evicted) before the thread is shown again, so the thread model is replaced. An image the
    /// composer took must still be there, not kept only by the released model.
    @Test func anImagePastedWhileTheDraftLoadsIsNeverHeldOnlyByAReleasableModel() async throws {
        let loading = try await LoadingThread(stored: .empty)
        defer { loading.fixture.remove() }
        let (composer, window) = mount(loading.host)
        defer { window.close() }

        _ = composer.composerTextView(composer.textView, read: pasteboard(png: Self.png), inline: false)
        for _ in 0..<20 { await Task.yield() }
        let accepted = !composer.currentDraft().attachments.isEmpty
        composer.host = FakeComposerHost("other")
        for _ in 0..<20 { await Task.yield() }

        let reopened = loading.reopened(storedText: loading.thread.draft)
        let restored = reopened.loadDraft()
        #expect(!accepted || restored.attachments.count == 1,
                "the composer took the image (\(accepted)); after the model was replaced it has \(restored.attachments.count)")
    }

    /// R5-02: the stored draft holds an image and the literal words `review @a.swift now`. Before it loads the person
    /// enters the same words, choosing `a.swift` from file completion, and leaves the thread; the same model survives.
    /// A mention the composer took must still be there when the draft loads, and the stored image is kept.
    @Test func aFileChosenWhileTheDraftLoadsIsNeverDroppedForIdenticalText() async throws {
        let stored = ComposerDraft(text: "review @a.swift now", attachments: [.image(Self.png, type: .png)])
        let loading = try await LoadingThread(stored: stored)
        defer { loading.fixture.remove() }
        let (composer, window) = mount(loading.host)
        defer { window.close() }

        composer.insert(text: "review ")
        composer.insert(token: Self.mention)
        composer.insert(text: "now")
        let accepted = composer.currentDraft().tokens.contains { $0.token.value == Self.mention.value }
        if accepted { #expect(composer.currentDraft().text == stored.text) }
        composer.host = FakeComposerHost("other")

        // The model reads the stored words; joined with the same words typed meanwhile, they are unchanged.
        loading.modelLoads(text: stored.text)
        let loaded = loading.host.loadDraft()
        #expect(loaded.text == stored.text)
        #expect(!accepted || loaded.tokens.map(\.token.value) == [Self.mention.value],
                "the composer took the mention (\(accepted)); the loaded draft has \(loaded.tokens.count) mentions")
        #expect(loaded.attachments.count == 1, "the stored image is kept")
    }

    /// While the draft loads the composer is read-only with "Loading draft…": typing, insertion, completion tokens,
    /// paste and attachments are all refused, Send is unavailable, and nothing is written. A load that does not finish
    /// in time shows an error with Retry. Once the draft loads the composer shows it and takes edits.
    @Test func theComposerIsReadOnlyUntilItHasObservedItsLoadedDraft() async throws {
        var stored = ComposerDraft(text: "stored words")
        stored.attachments = [.text("log")]
        let loading = try await LoadingThread(stored: stored)
        defer { loading.fixture.remove() }
        loading.cache.store(stored, for: "ses_1")
        let composer = ComposerViewController()
        composer.controller.draftLoadTimeout = .milliseconds(30)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = composer
        defer { window.close() }
        composer.host = loading.host

        #expect(composer.isLoadingDraft)
        #expect(!composer.textView.isEditable)
        #expect(composer.textView.string == "stored words", "the cached copy shows read-only, never a blank pane")
        #expect(!composer.insert(text: "x"))
        #expect(!composer.insert(token: Self.mention))
        #expect(composer.add(attachments: [.text("more")]) == [.draftLoading])
        _ = composer.composerTextView(composer.textView, read: pasteboard(png: Self.png), inline: false)
        composer.textView.insertText("typed", replacementRange: composer.textView.selectedRange())
        #expect(composer.textView.string == "stored words")
        #expect(composer.currentDraft().attachments.map(\.id) == stored.attachments.map(\.id))
        #expect(composer.primaryAction == .send(.now))
        #expect(!composer.validateMenuItem(NSMenuItem(title: "Send", action: #selector(ComposerViewController.sendPrompt(_:)), keyEquivalent: "")))
        composer.sendPrompt(nil)
        #expect(composer.controller.pendingSends == 0)

        // Too slow: an error with Retry, and still nothing written.
        for _ in 0..<2_000 where !composer.controller.draftLoadFailed { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(composer.visibleError?.contains("could not be loaded") == true)
        #expect(loading.thread.draft == "")
        composer.controller.draftLoadTimeout = .seconds(60)
        composer.controller.retryDraftLoad()
        #expect(loading.thread.retries == 1)
        #expect(composer.visibleError == nil)

        loading.modelLoads(text: stored.text)
        for _ in 0..<1_000 where composer.isLoadingDraft { await Task.yield() }
        #expect(!composer.isLoadingDraft)
        #expect(composer.textView.isEditable)
        #expect(composer.insert(text: " and more"))
        composer.controller.flushDraft()
        #expect(loading.thread.draft == "stored words and more")
        #expect(loading.host.loadDraft().attachments.map(\.id) == stored.attachments.map(\.id))
    }
}
