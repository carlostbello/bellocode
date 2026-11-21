import BelloCore
import Foundation
import Synchronization
import Testing
@testable import ComposerKit

/// v1.0.0 reviews A15, A16, A27, N16, N27: draft records are written in save order and never resurrected, quit hands
/// pending edits over, eviction never removes a file an unsent draft or queued send references, typing does not
/// rewrite or re-read attachments, and restoring reads memory.
@Suite("Draft durability", .timeLimit(.minutes(3)))
struct DraftDurabilityTests {
    /// A one-shot gate: `wait` suspends until `open`; `reached` resumes once a waiter arrived.
    final class Gate: Sendable {
        private struct State {
            var open = false
            var waiters: [CheckedContinuation<Void, Never>] = []
            var arrivals: [CheckedContinuation<Void, Never>] = []
            var arrived = false
        }
        private let state = Mutex(State())

        func wait() async {
            let arrivals = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.arrived = true
                defer { state.arrivals = [] }
                return state.arrivals
            }
            for arrival in arrivals { arrival.resume() }
            await withCheckedContinuation { continuation in
                let resume = state.withLock { state -> Bool in
                    if state.open { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if resume { continuation.resume() }
            }
        }

        func reached() async {
            await withCheckedContinuation { continuation in
                let resume = state.withLock { state -> Bool in
                    if state.arrived { return true }
                    state.arrivals.append(continuation)
                    return false
                }
                if resume { continuation.resume() }
            }
        }

        func open() {
            let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.open = true
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    final class Counter: Sendable {
        let value = Mutex(0)
        func increment() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    struct Fixture {
        let root: URL
        var drafts: URL { root.appending(path: "drafts", directoryHint: .isDirectory) }
        let files: AttachmentFileStore

        init(maxTotalBytes: Int = 512 << 20, inUseGrace: Duration = .seconds(3600)) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "bc-durable-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            files = AttachmentFileStore(
                directory: root.appending(path: "attachments", directoryHint: .isDirectory), maxTotalBytes: maxTotalBytes, inUseGrace: inUseGrace)
        }

        func archive(beforeMaterialize: (@Sendable () async -> Void)? = nil) -> ComposerDraftArchive {
            ComposerDraftArchive(directory: drafts, files: files, debounce: .zero, beforeMaterialize: beforeMaterialize)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// A16/N16: an older write suspended while storing its image must not land after a newer clear (Send).
    @Test func aClearWhileAnOlderWriteStoresItsAttachmentIsNotResurrected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = Gate()
        let archive = fixture.archive(beforeMaterialize: { await gate.wait() })
        let old = ComposerDraft(text: "look", attachments: [.image(Data([1, 2, 3, 4]), type: .png)])
        archive.save(old, for: "ses_1")
        await gate.reached()
        archive.save(.empty, for: "ses_1")
        let flushed = Task { await archive.flush() }
        gate.open()
        await flushed.value
        #expect(archive.load("ses_1") == nil)
        #expect(!FileManager.default.fileExists(atPath: archive.url(for: "ses_1").path))
        // Reopened (a relaunch): nothing comes back.
        let reopened = fixture.archive()
        await reopened.preload()
        #expect(reopened.restore("ses_1", text: "") == nil)
    }

    /// N16: saves are written in call order, whatever order their tasks run in, and flush writes the last.
    @Test func savesAreWrittenInCallOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = fixture.archive()
        let first = ComposerDraft(text: "first", attachments: [.text("one")])
        let second = ComposerDraft(text: "second", attachments: [.text("two")])
        for _ in 0..<20 {
            archive.save(first, for: "k")
            archive.save(second, for: "k")
        }
        await archive.flush()
        #expect(archive.load("k")?.text == "second")
        let reopened = fixture.archive()
        #expect(reopened.load("k")?.text == "second")
    }

    /// N27: typing in a draft with a staged image stores the image once, not on every save.
    @Test func typingDoesNotRestoreTheAttachmentEachTime() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let calls = Counter()
        let archive = fixture.archive(beforeMaterialize: { calls.increment() })
        let image = ComposerAttachment.image(Data(repeating: 7, count: 4096), type: .png)
        for text in ["a", "ab", "abc", "abcd"] {
            await archive.write(ComposerDraft(text: text, attachments: [image]), for: "k")
        }
        #expect(calls.count == 1)
        #expect(archive.load("k")?.text == "abcd")
    }

    /// A15: a new paste never evicts the file of an unsent draft's record or a queued send, however old; when those
    /// fill the budget, the new paste fails visibly instead.
    @Test func aNewPasteNeverEvictsPinnedFiles() async throws {
        let fixture = try Fixture(maxTotalBytes: 150, inUseGrace: .zero)
        defer { fixture.remove() }
        let archive = fixture.archive()
        await archive.write(ComposerDraft(text: "draft", attachments: [.text(String(repeating: "d", count: 60), name: "d.txt")]), for: "k")
        let draftFile = try #require(archive.load("k")?.attachments.first?.fileURL)
        let outboxFile = try await fixture.files.materialize(.text(String(repeating: "o", count: 60), name: "o.txt"))
        let token = fixture.files.pins.add { [outboxFile] }
        defer { fixture.files.pins.remove(token) }
        let old = Date().addingTimeInterval(-30 * 24 * 3600)
        for file in [draftFile, outboxFile] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.deletingLastPathComponent().path)
        }
        await #expect(throws: AttachmentFileStore.StoreError.self) {
            _ = try await fixture.files.materialize(.text(String(repeating: "n", count: 60), name: "n.txt"))
        }
        #expect(FileManager.default.fileExists(atPath: draftFile.path))
        #expect(FileManager.default.fileExists(atPath: outboxFile.path))
        // Launch clean-up (expired by age) keeps them too, without being told.
        await fixture.files.cleanUp(now: Date().addingTimeInterval(60 * 24 * 3600))
        #expect(FileManager.default.fileExists(atPath: draftFile.path))
        #expect(FileManager.default.fileExists(atPath: outboxFile.path))
        // Once the draft is cleared, its file may go.
        await archive.write(.empty, for: "k")
        await fixture.files.cleanUp(now: Date().addingTimeInterval(60 * 24 * 3600))
        #expect(!FileManager.default.fileExists(atPath: draftFile.path))
    }

    /// A27: once preloaded (off the main actor), restoring reads memory: the record file is not read again.
    @Test func restoreReadsThePreloadedIndex() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = fixture.archive()
        await writer.write(ComposerDraft(text: "kept", attachments: [.text("pasted")]), for: "k")
        let archive = fixture.archive()
        await archive.preload()
        try FileManager.default.removeItem(at: archive.url(for: "k"))
        #expect(archive.restore("k", text: "kept")?.attachments.count == 1)
        #expect(await archive.referencedFiles().count == 1)
    }

    /// N16: quit hands an edit still inside the composer's save delay to its host.
    @MainActor
    @Test func quitFlushesEveryComposersPendingEdit() async throws {
        let controller = ComposerController()
        let host = FakeComposerHost("k")
        controller.attach(host)
        var current = ComposerDraft(text: "")
        controller.currentDraft = { current }
        current = ComposerDraft(text: "typed just before quit")
        controller.draftDidChange()
        #expect(host.draft.text.isEmpty, "still inside the save delay")
        ComposerController.flushAllDrafts()
        #expect(host.draft.text == "typed just before quit")
    }
}
