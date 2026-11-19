import CryptoKit
import Foundation
import os

/// The durable part of rich drafts (R28): a draft's tokens (context pills) and staged attachments, which the thread's
/// stored draft text alone cannot carry, so a relaunch restores the screenshot, file or pill the person staged before
/// pressing Send. One versioned JSON record per draft key under `~/Library/Application Support/BelloCode/drafts`.
///
/// Attachments held in memory (pasted images and text) are written to the `AttachmentFileStore` first and recorded by
/// file URL; files dropped from Finder stay where they are. `referencedFiles()` lists the store files records still
/// point at, so launch clean-up keeps them however old they are. Text stays owned by the thread's (or project's)
/// stored draft: a record is used only alongside it (see `restore`), and a draft with neither tokens nor attachments
/// has no record. Legacy text-only drafts simply have no record.
///
/// Threading: an actor (writes are debounced per key and run off the main actor); `load` is a small synchronous read
/// that is safe from any context.
public actor ComposerDraftArchive {
    public static let currentVersion = 1
    /// Records kept; the least recently saved go first beyond it (rule 5).
    public static let maxRecords = 256

    public static let shared: ComposerDraftArchive = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return ComposerDraftArchive(directory: base.appending(path: "BelloCode/drafts", directoryHint: .isDirectory), files: .applicationDefault)
    }()

    struct Record: Codable {
        var version: Int
        var key: String
        var saved: Date
        var draft: ComposerDraft
    }

    public nonisolated let directory: URL
    public nonisolated let files: AttachmentFileStore
    private let debounce: Duration
    private var pending: [String: Task<Void, Never>] = [:]
    private static let log = Logger(subsystem: "app.bellocode", category: "Drafts")

    public init(directory: URL, files: AttachmentFileStore, debounce: Duration = .milliseconds(250)) {
        self.directory = directory
        self.files = files
        self.debounce = debounce
    }

    nonisolated func url(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest.prefix(32)).json")
    }

    /// Whether `draft` needs a record (anything the text alone cannot restore).
    public nonisolated static func needsRecord(_ draft: ComposerDraft) -> Bool {
        !draft.attachments.isEmpty || !draft.tokens.isEmpty
    }

    /// Records `draft` for `key` after a short quiet period (the last call wins); a draft without tokens or
    /// attachments removes the record.
    public func save(_ draft: ComposerDraft, for key: String) {
        pending[key]?.cancel()
        latest[key] = draft
        let debounce = self.debounce
        pending[key] = Task {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self.write(draft, for: key)
        }
    }

    /// Writes every debounced save now (quit).
    public func flush() async {
        for task in pending.values { task.cancel() }
        pending = [:]
        // A cancelled debounce never wrote: write the latest drafts directly.
        let drafts = latest
        latest = [:]
        for (key, draft) in drafts { await write(draft, for: key) }
    }

    /// The newest draft handed to `save` per key and not yet written (for `flush`).
    private var latest: [String: ComposerDraft] = [:]

    /// Saves immediately (tests, flush).
    public func write(_ draft: ComposerDraft, for key: String) async {
        latest[key] = nil
        let file = url(for: key)
        guard Self.needsRecord(draft) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        var stored = draft
        var attachments: [ComposerAttachment] = []
        for attachment in draft.attachments {
            switch attachment.content {
            case .file:
                attachments.append(attachment)
            case .data, .text:
                do {
                    let url = try await files.materialize(attachment)
                    var copy = attachment
                    copy.content = .file(url)
                    attachments.append(copy)
                } catch {
                    // Kept in memory for this session; the record keeps the rest (never the whole draft lost).
                    Self.log.error("a draft attachment could not be stored")
                }
            }
        }
        stored.attachments = attachments
        let record = Record(version: Self.currentVersion, key: key, saved: Date(), draft: stored)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try encoder.encode(record).write(to: file, options: [.atomic])
        } catch {
            Self.log.error("a draft record could not be written")
        }
        prune()
    }

    /// The recorded draft for `key`, if any (a record of a newer, unknown version is ignored).
    public nonisolated func load(_ key: String) -> ComposerDraft? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let record = try? decoder.decode(Record.self, from: data), record.version <= Self.currentVersion, record.key == key else { return nil }
        return record.draft
    }

    /// Combines the stored draft text (the source of truth for text) with a record: the full draft when the text is
    /// the one the record was saved with, otherwise the text with the record's attachments (its token ranges no longer
    /// apply). Nil without a record: the caller uses the text alone (legacy drafts).
    public nonisolated func restore(_ key: String, text: String) -> ComposerDraft? {
        guard let record = load(key) else { return nil }
        let present = record.attachments.filter { attachment in
            guard let url = attachment.fileURL else { return true }
            return FileManager.default.fileExists(atPath: url.path)
        }
        if record.text == text {
            var draft = record
            draft.attachments = present
            return draft.validated()
        }
        guard !present.isEmpty else { return nil }
        return ComposerDraft(text: text, attachments: present)
    }

    /// Files inside the attachment store that records reference (launch clean-up keeps them).
    public nonisolated func referencedFiles() -> Set<URL> {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var urls: Set<URL> = []
        for entry in entries where entry.pathExtension == "json" {
            guard let data = try? Data(contentsOf: entry), let record = try? decoder.decode(Record.self, from: data) else { continue }
            for attachment in record.draft.attachments { if let url = attachment.fileURL { urls.insert(url) } }
        }
        return urls
    }

    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
              entries.count > Self.maxRecords else { return }
        let sorted = entries.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            return a < b
        }
        for entry in sorted.prefix(entries.count - Self.maxRecords) { try? FileManager.default.removeItem(at: entry) }
    }
}
