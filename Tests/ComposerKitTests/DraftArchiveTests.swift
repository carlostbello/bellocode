import BelloCore
import Foundation
import Testing
@testable import ComposerKit

/// R28: staged attachments and context pills survive a relaunch with the draft; launch clean-up keeps their files.
@MainActor
@Suite struct DraftArchiveTests {
    struct Fixture {
        let root: URL
        let files: AttachmentFileStore
        let archive: ComposerDraftArchive

        static func make() throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appending(path: "bc-drafts-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let files = AttachmentFileStore(directory: root.appending(path: "attachments", directoryHint: .isDirectory))
            let archive = ComposerDraftArchive(directory: root.appending(path: "drafts", directoryHint: .isDirectory), files: files, debounce: .zero)
            return Fixture(root: root, files: files, archive: archive)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func attachmentsAndPillsAreRestoredAfterRelaunch() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let dropped = fixture.root.appending(path: "notes.md")
        try Data("# notes\n".utf8).write(to: dropped)
        let image = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let token = ComposerToken(kind: .file, text: "@a.swift", value: "/repo/a.swift")
        let draft = ComposerDraft(
            text: "look at @a.swift", tokens: [PlacedToken(token: token, range: NSRange(location: 8, length: 8))],
            attachments: [.image(image, type: .png), .text("long paste\nline 2"), .file(at: dropped)])

        let before = FakeThread()
        let host = ThreadModelComposerHost(before, cache: ComposerDraftCache(), archive: fixture.archive)
        host.saveDraft(draft)
        #expect(before.draft == draft.text)
        // The save is handed to the archive asynchronously; quit flushes whatever is pending.
        for _ in 0..<200 where fixture.archive.load(host.draftKey) == nil { await Task.yield() }
        await fixture.archive.flush()

        // Relaunch: a fresh process-wide cache; only the thread's stored text survived in the database.
        let after = FakeThread()
        after.draft = draft.text
        let relaunched = ThreadModelComposerHost(after, cache: ComposerDraftCache(), archive: fixture.archive)
        let restored = relaunched.loadDraft()
        #expect(restored.text == draft.text)
        #expect(restored.tokens == draft.tokens, "the context pill is back")
        #expect(restored.attachments.map(\.id) == draft.attachments.map(\.id))
        #expect(restored.attachments.map(\.name) == draft.attachments.map(\.name))
        let imageURL = try #require(restored.attachments[0].fileURL)
        #expect(try Data(contentsOf: imageURL) == image)
        #expect(restored.attachments[2].fileURL == dropped, "a dropped file stays where it is")

        // Launch clean-up keeps the files a draft still references, however old.
        let referenced = await fixture.archive.referencedFiles()
        #expect(referenced.contains(imageURL))
        await fixture.files.cleanUp(now: Date().addingTimeInterval(30 * 24 * 3600), keeping: referenced)
        #expect(FileManager.default.fileExists(atPath: imageURL.path))

        // Sending clears the draft, and its record.
        relaunched.saveDraft(.empty)
        for _ in 0..<200 where fixture.archive.load(relaunched.draftKey) != nil { await Task.yield() }
        await fixture.archive.flush()
        #expect(fixture.archive.load(relaunched.draftKey) == nil)
    }

    @Test func legacyTextDraftsAndEditedTextAreHandled() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        // A legacy draft (text only, no record) restores as text.
        let legacy = FakeThread()
        legacy.draft = "an old draft"
        #expect(ThreadModelComposerHost(legacy, cache: ComposerDraftCache(), archive: fixture.archive).loadDraft() == ComposerDraft(text: "an old draft"))
        // Text changed elsewhere after the record was written: the attachments come back with the current text.
        let attachment = ComposerAttachment.text("pasted")
        await fixture.archive.write(ComposerDraft(text: "first", attachments: [attachment]), for: legacy.sessionID.rawValue)
        let restored = fixture.archive.restore(legacy.sessionID.rawValue, text: "an old draft")
        #expect(restored?.text == "an old draft")
        #expect(restored?.attachments.map(\.id) == [attachment.id])
        // A record of an unknown future version is ignored.
        let url = fixture.archive.url(for: "future")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":99,"key":"future","saved":0,"draft":{"text":"x","tokens":[],"attachments":[],"selectionLocation":0,"selectionLength":0}}"#.utf8).write(to: url)
        #expect(fixture.archive.load("future") == nil)
    }
}
