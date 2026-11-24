import BelloCore
import Foundation
import Testing
@testable import ComposerKit

/// v1.0.1 AV2-02 and R3-01: a prompt recovered outside the composer (Edit from Here's rewind) goes into its thread's
/// latest draft as one write, every composer of the thread then shows it, and nothing saves a stale copy over it or
/// drops the draft's tokens and attachments, including when the stored draft is slow to load.
@MainActor
@Suite("Recovered prompts", .timeLimit(.minutes(3)))
struct RecoveredPromptTests {
    static let token = ComposerToken(kind: .file, text: "@a.swift", value: "a.swift")
    /// A draft with a file mention, as a composer saves it.
    static let rich = ComposerDraft(text: "see @a.swift now", tokens: [PlacedToken(token: token, range: NSRange(location: 4, length: 8))])

    /// One thread shown in two windows: two composers, each with its own host of the same thread (as the app makes them).
    @MainActor
    struct TwoWindows {
        let thread: FakeThread
        let cache: ComposerDraftCache
        let registry: ComposerController.Registry
        var hosts: [ThreadModelComposerHost] = []
        var views: [FakeView] = []
        var controllers: [ComposerController] = []

        init(draft: ComposerDraft) {
            thread = FakeThread()
            cache = ComposerDraftCache()
            registry = ComposerController.Registry()
            thread.draft = draft.text
            for index in 0..<2 {
                let host = ThreadModelComposerHost(thread, cache: cache)
                if index == 0 { host.saveDraft(draft) }
                let controller = ComposerController(registry: registry)
                let view = FakeView()
                view.bind(controller)
                controller.attach(host)
                hosts.append(host)
                views.append(view)
                controllers.append(controller)
            }
        }

        /// The first window's composer edits and saves (the second has not observed it yet).
        func editFirst(_ draft: ComposerDraft) {
            views[0].draft = draft
            controllers[0].draftDidChange()
            controllers[0].flushDraft()
        }

        var stored: ComposerDraft { hosts[0].loadDraft() }
    }

    /// Two windows show the thread: the prompt goes in front of the stored rich draft once, and both show it.
    @Test func everyOpenComposerOfTheThreadShowsThePrompt() async {
        let windows = TwoWindows(draft: Self.rich)
        #expect(windows.views.allSatisfy { $0.draft.text == Self.rich.text })
        // A composer of another thread is left alone.
        let otherThread = FakeThread()
        otherThread.draft = "other"
        let other = ComposerController(registry: windows.registry)
        let otherView = FakeView()
        otherView.bind(other)
        other.attach(ThreadModelComposerHost(otherThread, cache: ComposerDraftCache()))

        let placement = await ComposerController.placeRecovered(
            ComposerDraft(text: "rewound"), into: windows.hosts[0], registry: windows.registry)
        #expect(placement == .placed(composers: 2))
        #expect(windows.thread.draft == "rewound\n\nsee @a.swift now")
        #expect(windows.stored.tokens == [PlacedToken(token: Self.token, range: NSRange(location: 13, length: 8))])
        for view in windows.views {
            #expect(view.draft.text == "rewound\n\nsee @a.swift now")
            #expect(view.draft.tokens.first?.range == NSRange(location: 13, length: 8), "the mention moves with its text")
            #expect(view.draft.selection == NSRange(location: 25, length: 0), "the caret stays after the same text")
        }
        #expect(otherView.draft.text == "other")
        #expect(otherThread.draft == "other")
        // The second window's next edit saves on top of it.
        windows.views[1].draft.text += "!"
        windows.controllers[1].draftDidChange()
        windows.controllers[1].flushDraft()
        #expect(windows.thread.draft == "rewound\n\nsee @a.swift now!")
    }

    /// R3-01: the first window saved newer text and an attachment; the second, idle, still shows the old copy. The
    /// rewind's prompt goes in front of the newer draft, and the idle window never writes its old copy back.
    @Test func anIdleStaleComposerNeverSavesItsOldCopyOverTheNewerDraft() async {
        let windows = TwoWindows(draft: ComposerDraft(text: "old"))
        windows.editFirst(ComposerDraft(text: "newer text", attachments: [.text("log")]))
        #expect(windows.views[1].draft.text == "old", "the second window has not caught up yet")

        let placement = await ComposerController.placeRecovered(
            ComposerDraft(text: "rewound"), into: windows.hosts[0], registry: windows.registry)
        #expect(placement == .placed(composers: 2))
        #expect(windows.thread.draft == "rewound\n\nnewer text")
        #expect(windows.stored.attachments.count == 1, "the first window's attachment is kept")
        for view in windows.views {
            #expect(view.draft.text == "rewound\n\nnewer text")
            #expect(view.draft.attachments.count == 1)
        }
        // The idle window's next edit saves on top of the newer draft, not its old copy.
        windows.views[1].draft.text += "!"
        windows.controllers[1].draftDidChange()
        windows.controllers[1].flushDraft()
        #expect(windows.thread.draft == "rewound\n\nnewer text!")
        #expect(windows.stored.attachments.count == 1)
        // Closing the idle window writes nothing older.
        windows.controllers[1].flushDraft()
        windows.controllers[1].attach(nil)
        #expect(windows.thread.draft == "rewound\n\nnewer text!")
        #expect(windows.stored.attachments.count == 1)
    }

    /// R3-01, generally: a stale composer's own edit is saved on top of the newer draft (both kept), never over it.
    @Test func aStaleComposersEditIsRebasedOntoTheNewerDraft() {
        let windows = TwoWindows(draft: ComposerDraft(text: "old"))
        windows.editFirst(ComposerDraft(text: "newer text", attachments: [.text("log")]))
        windows.views[1].draft = ComposerDraft(text: "old!")
        windows.controllers[1].draftDidChange()
        windows.controllers[1].flushDraft()
        #expect(windows.thread.draft == "newer text\n\nold!")
        #expect(windows.stored.attachments.count == 1)
        #expect(windows.views[1].draft.text == "newer text\n\nold!", "the second window shows what was saved")
        #expect(windows.views[1].draft.selection == NSRange(location: ("newer text\n\nold!" as NSString).length, length: 0),
                "its caret stays in its own edit")
    }

    /// A following composer's caret stays on the same text: kept before a change, moved by the length change after it,
    /// and put at the end of a changed span it was inside.
    @Test func theCaretFollowsItsTextThroughAnotherWindowsChange() {
        let map = ComposerController.mapSelection
        #expect(map(NSRange(location: 3, length: 0), "abc", "xyabc") == NSRange(location: 5, length: 0))
        #expect(map(NSRange(location: 1, length: 0), "abc", "abcdef") == NSRange(location: 1, length: 0))
        #expect(map(NSRange(location: 2, length: 0), "abcd", "aXYd") == NSRange(location: 3, length: 0))
        #expect(map(NSRange(location: 1, length: 1), "abc", "aXYc") == NSRange(location: 1, length: 2))
        #expect(map(NSRange(location: 0, length: 3), "abc", "zabc") == NSRange(location: 0, length: 4))
        #expect(map(NSRange(location: 3, length: 0), "a😀b", "😀a😀b") == NSRange(location: 5, length: 0))
    }

    /// An idle composer follows another window's save (text, then attachments alone) through its host's observation.
    @Test func anIdleComposerFollowsAnotherWindowsSave() async {
        let windows = TwoWindows(draft: ComposerDraft(text: "old"))
        windows.editFirst(ComposerDraft(text: "newer text"))
        #expect(await waitFor { windows.views[1].draft.text == "newer text" })
        windows.editFirst(ComposerDraft(text: "newer text", attachments: [.text("log")]))
        #expect(await waitFor { windows.views[1].draft.attachments.count == 1 })
        // Sending from the second window clears the draft for both.
        windows.editFirst(ComposerDraft(text: "send me"))
        #expect(await waitFor { windows.views[1].draft.text == "send me" && windows.views[1].draft.attachments.isEmpty })
        #expect(windows.controllers[1].submit())
        #expect(windows.thread.draft == "")
        #expect(await waitFor { windows.views[0].draft.isEmpty })
    }

    /// No composer shows the thread: the prompt goes in front of the stored draft, its mention kept.
    @Test func withNoComposerTheStoredRichDraftKeepsItsTokens() async {
        let registry = ComposerController.Registry()
        let host = FakeComposerHost("ses_1", draft: Self.rich)
        host.owner = ObjectIdentifier(FakeThread())
        let placement = await ComposerController.placeRecovered(ComposerDraft(text: "rewound"), into: host, registry: registry)
        #expect(placement == .placed(composers: 0))
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
        #expect(await placing.value == .placed(composers: 0))
        #expect(host.stored.text == "rewound\n\nsee @a.swift now")
        #expect(host.stored.tokens.first?.range == NSRange(location: 13, length: 8))
    }

    /// AV2-02: the stored draft takes longer than the notice delay. The prompt stays pending (with a notice) instead of
    /// a text-only write, and when the archived rich draft loads its mention and attachment are kept.
    @Test func aSlowDraftKeepsThePromptPendingAndKeepsArchivedMentions() async throws {
        let fixture = try DraftDurabilityTests.Fixture()
        defer { fixture.remove() }
        let archive = fixture.archive()
        var stored = Self.rich
        stored.attachments = [.text("log")]
        await archive.write(stored, for: "ses_1")
        _ = await archive.flush()
        let thread = FakeThread()
        thread.loaded = false
        let host = ThreadModelComposerHost(thread, cache: ComposerDraftCache(), fileStore: fixture.files, archive: archive)
        let (delayed, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let placing = Task {
            await ComposerController.placeRecovered(
                ComposerDraft(text: "rewound"), into: host, registry: ComposerController.Registry(),
                noticeAfter: .milliseconds(20), giveUpAfter: .seconds(120), onDelay: { signal.yield() })
        }
        for await _ in delayed { break }
        #expect(thread.draft == "", "nothing was written while the draft is loading")
        // The stored draft arrives after the notice.
        thread.draft = stored.text
        thread.loaded = true
        #expect(await placing.value == .placed(composers: 0))
        #expect(thread.draft == "rewound\n\nsee @a.swift now")
        _ = await archive.flush()
        let restored = try #require(archive.restore("ses_1", text: thread.draft))
        #expect(restored.tokens == [PlacedToken(token: Self.token, range: NSRange(location: 13, length: 8))])
        #expect(restored.attachments.count == 1)
    }

    /// A draft that never loads is not written at all; neither is one whose wait is cancelled.
    @Test func aDraftThatNeverLoadsIsLeftAlone() async {
        let host = LateDraftHost(stored: Self.rich)
        var noticed = false
        let placement = await ComposerController.placeRecovered(
            ComposerDraft(text: "rewound"), into: host, registry: ComposerController.Registry(),
            noticeAfter: .milliseconds(10), giveUpAfter: .milliseconds(50), onDelay: { noticed = true })
        #expect(placement == .unloadedDraft)
        #expect(noticed)
        #expect(host.saved.isEmpty)

        let cancelled = Task {
            await ComposerController.placeRecovered(ComposerDraft(text: "rewound"), into: host, registry: ComposerController.Registry())
        }
        #expect(await waitFor { host.listenerCount > 1 })
        cancelled.cancel()
        #expect(await cancelled.value == .unloadedDraft)
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
        #expect(placement == .placed(composers: 0))
        #expect(thread.draft == "rewound\n\nsee @a.swift now")
        _ = await archive.flush()
        let restored = try #require(archive.restore("ses_1", text: thread.draft))
        #expect(restored.tokens == [PlacedToken(token: Self.token, range: NSRange(location: 13, length: 8))])
    }

    /// A thread whose stored rich draft (a mention and an attachment) is archived and not loaded yet, shown in a
    /// composer that is still awaiting it (the user came back to the thread while a rewind was in flight).
    @MainActor
    struct LoadingComposer {
        let fixture: DraftDurabilityTests.Fixture
        let archive: ComposerDraftArchive
        let stored: ComposerDraft
        let thread = FakeThread()
        let host: ThreadModelComposerHost
        let controller = ComposerController(registry: ComposerController.Registry())
        let view = FakeView()

        init() async throws {
            fixture = try DraftDurabilityTests.Fixture()
            archive = fixture.archive()
            var stored = RecoveredPromptTests.rich
            stored.attachments = [.text("log")]
            self.stored = stored
            await archive.write(stored, for: "ses_1")
            _ = await archive.flush()
            thread.loaded = false
            host = ThreadModelComposerHost(thread, cache: ComposerDraftCache(), fileStore: fixture.files, archive: archive)
            view.bind(controller)
            controller.draftSaveDelay = .zero
            controller.attach(host)
        }

        /// The archived record still holds the stored draft (text, mention and attachment).
        func recordIsStored() async -> Bool {
            guard let record = await record() else { return false }
            return record.text == stored.text && record.tokens == stored.tokens
                && record.attachments.map(\.id) == stored.attachments.map(\.id)
        }

        /// The archived record, after any pending write.
        func record() async -> ComposerDraft? {
            _ = await archive.flush()
            return archive.load("ses_1")
        }

        /// The stored draft arrives with `text` (the thread's text after any join).
        func finishLoading(text: String) {
            thread.draft = text
            thread.loaded = true
        }
    }

    /// AV2-02, visible path: the rewound prompt arrives while the thread's visible composer still awaits its stored
    /// draft. Nothing is inserted or saved (the archived mention and attachment stay recorded); once the draft loads
    /// the prompt goes in front of it, and its mention and attachment are kept, in the composer and the archive.
    @Test func aVisibleComposerStillLoadingWaitsAndKeepsTheArchivedDraft() async throws {
        let loading = try await LoadingComposer()
        defer { loading.fixture.remove() }
        #expect(loading.controller.awaitingDraft)
        #expect(loading.controller.placeRecoveredIfLoaded(ComposerDraft(text: "rewound")) == nil)
        let (delayed, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let controller = loading.controller
        let placing = Task {
            await controller.placeRecovered(
                ComposerDraft(text: "rewound"), noticeAfter: .milliseconds(20), giveUpAfter: .seconds(120), onDelay: { signal.yield() })
        }
        // The notice, or (a regression) a placement that did not wait at all.
        let finished = Task {
            _ = await placing.value
            signal.yield()
        }
        defer { finished.cancel() }
        for await _ in delayed { break }
        #expect(loading.view.draft.text == loading.stored.text, "nothing is inserted: the archived copy shows read-only")
        #expect(loading.thread.draft == "", "nothing is saved while the draft is loading")
        #expect(await loading.recordIsStored(), "the archived mention and attachment are untouched")

        loading.finishLoading(text: loading.stored.text)
        #expect(await placing.value == .placed(composers: 1))
        let expected = "rewound\n\nsee @a.swift now"
        #expect(loading.thread.draft == expected)
        #expect(loading.view.draft.text == expected)
        #expect(loading.view.draft.tokens == [PlacedToken(token: Self.token, range: NSRange(location: 13, length: 8))])
        #expect(loading.view.draft.attachments.count == 1)
        #expect(loading.view.draft.selection == NSRange(location: 7, length: 0), "the caret is at the end of the prompt")
        #expect(loading.view.undoableReplacements == 1, "placed as one undoable edit")
        let record = try #require(await loading.record())
        #expect(record.text == expected)
        #expect(record.tokens == [PlacedToken(token: Self.token, range: NSRange(location: 13, length: 8))])
        #expect(record.attachments.count == 1)
    }

    /// AV2-02, visible path: a change reported while the draft loads (the view is read-only then, so only a stray
    /// programmatic one) is not taken: nothing is saved, and the prompt goes in front of the loaded draft alone.
    @Test func anEditWhileTheVisibleComposerLoadsIsNotTaken() async throws {
        let loading = try await LoadingComposer()
        defer { loading.fixture.remove() }
        let controller = loading.controller
        let placing = Task { await controller.placeRecovered(ComposerDraft(text: "rewound")) }
        // The placement starts waiting for the stored draft.
        for _ in 0..<20 { await Task.yield() }
        loading.view.draft = ComposerDraft(text: "typed", selection: NSRange(location: 5, length: 0))
        loading.controller.draftDidChange()
        loading.controller.flushDraft()
        #expect(loading.thread.draft == "", "nothing is saved while loading")
        #expect(await loading.recordIsStored())
        loading.finishLoading(text: loading.stored.text)
        #expect(await placing.value == .placed(composers: 1))
        let expected = "rewound\n\nsee @a.swift now"
        #expect(loading.thread.draft == expected)
        #expect(loading.view.draft.text == expected)
        #expect(loading.view.draft.tokens.first?.range == NSRange(location: 13, length: 8))
        #expect(loading.view.draft.attachments.count == 1)
        let record = try #require(await loading.record())
        #expect(record.text == expected)
        #expect(record.attachments.count == 1)
    }

    /// AV2-02: a composer that leaves (thread switch) before the stored draft loaded hands over nothing: the thread's
    /// text, the cache and the archived record are untouched, and the stored rich draft is what loads.
    @Test func aComposerLeavingBeforeTheDraftLoadsWritesNothing() async throws {
        let loading = try await LoadingComposer()
        defer { loading.fixture.remove() }
        loading.view.draft = ComposerDraft(text: "and more", attachments: [.text("trace")])
        loading.controller.draftDidChange()
        loading.controller.attach(nil)
        #expect(loading.thread.draft == "", "nothing is handed to the thread")
        #expect(await loading.recordIsStored(), "the archived record is not replaced")
        loading.finishLoading(text: loading.stored.text)
        let loaded = loading.host.loadDraft()
        #expect(loaded.text == loading.stored.text)
        #expect(loaded.tokens == loading.stored.tokens)
        #expect(loaded.attachments.map(\.id) == loading.stored.attachments.map(\.id))
    }

    /// The thread adapter itself refuses a write before its stored draft has been read (a stray save), so neither the
    /// thread's text nor the cache nor the archive can be replaced by a placeholder.
    @Test func theThreadAdapterRefusesAWriteBeforeTheDraftLoads() async throws {
        let loading = try await LoadingComposer()
        defer { loading.fixture.remove() }
        loading.host.saveDraft(ComposerDraft(text: "stray", attachments: [.text("x")]))
        #expect(loading.thread.draft == "")
        #expect(await loading.recordIsStored())
        loading.finishLoading(text: loading.stored.text)
        #expect(loading.host.loadDraft().attachments.map(\.id) == loading.stored.attachments.map(\.id))
    }

    /// The visible composer puts the prompt in front of its draft (as the offscreen path does), never at the selection:
    /// selected text is not replaced, and the caret ends up after the prompt.
    @Test func theVisibleComposerPutsThePromptInFrontNotAtTheSelection() {
        let windows = TwoWindows(draft: Self.rich)
        windows.views[0].draft.selection = NSRange(location: 4, length: 8)
        let placement = windows.controllers[0].placeRecoveredIfLoaded(ComposerDraft(text: "rewound"))
        #expect(placement == .placed(composers: 2))
        let expected = "rewound\n\nsee @a.swift now"
        #expect(windows.views[0].draft.text == expected, "the selected mention is kept")
        #expect(windows.views[0].draft.tokens == [PlacedToken(token: Self.token, range: NSRange(location: 13, length: 8))])
        #expect(windows.views[0].draft.selection == NSRange(location: 7, length: 0))
        #expect(windows.views[0].undoableReplacements == 1)
        #expect(windows.thread.draft == expected)
        #expect(windows.stored.tokens == [PlacedToken(token: Self.token, range: NSRange(location: 13, length: 8))])
        #expect(windows.views[1].draft.text == expected, "the other window follows")
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<2000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}
