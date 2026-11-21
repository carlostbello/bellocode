import CryptoKit
import Foundation
import Synchronization
import os

/// The durable part of rich drafts (R28): a draft's tokens (context pills) and staged attachments, which the thread's
/// stored draft text alone cannot carry, so a relaunch restores the screenshot, file or pill the person staged before
/// pressing Send. One versioned JSON record per draft key under `~/Library/Application Support/BelloCode/drafts`.
///
/// Attachments held in memory (pasted images and text) are written to the `AttachmentFileStore` first and recorded by
/// file URL; files dropped from Finder stay where they are. The archive registers the store files its records point
/// at with the store's `AttachmentPins`, so no eviction (at launch or when a new paste is written) removes them however
/// old they are (A15). Text stays owned by the thread's (or project's) stored draft: a record is used only alongside it
/// (see `restore`), and a draft with neither tokens nor attachments has no record. Legacy text-only drafts simply have
/// no record.
///
/// Ordering (A16, N16): `save` is synchronous and mints a per-key sequence number in call order, so saves made one after
/// another on the main actor are ordered however their writes are scheduled. Writes for one key run one at a time, each
/// writes the newest draft handed to `save`, and a write that finds a newer save after materializing its attachments
/// gives way, so an older draft can never land after (and resurrect what) a newer save or clear removed. `flush` writes
/// every key's newest draft and waits for writes already running.
///
/// Main actor (A27): records are read off the main actor into an in-memory index (`preload`, started on creation) and
/// kept current by every write, so `restore` on the main actor reads memory, not disk.
///
/// Threading: an actor; `save`, `load` and `restore` are nonisolated and safe from any context.
public actor ComposerDraftArchive {
    public static let currentVersion = 1
    /// Records kept; the least recently saved go first beyond it (rule 5).
    public static let maxRecords = 256
    /// Materialized attachment files remembered by ID (rule 5: bounded; cleared when full).
    static let maxMaterialized = 512

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

    /// What `save` handed over, per key, in call order.
    struct Intake {
        var sequence: [String: UInt64] = [:]
        var latest: [String: (sequence: UInt64, draft: ComposerDraft)] = [:]
    }

    /// Records in memory (key → draft as recorded, with attachments already known to exist at load time).
    struct Index: Equatable {
        var drafts: [String: ComposerDraft] = [:]
    }

    public nonisolated let directory: URL
    public nonisolated let files: AttachmentFileStore
    private let debounce: Duration
    private nonisolated let intake = Mutex(Intake())
    /// Shared with the pin provider, which outlives no archive but runs outside it.
    final class IndexBox: Sendable {
        let state = Mutex<Index?>(nil)
        func withLock<T>(_ body: (inout Index?) -> T) -> T { state.withLock { body(&$0) } }
    }
    private nonisolated let index = IndexBox()
    /// The debounce per key (the last save wins).
    private var pending: [String: Task<Void, Never>] = [:]
    /// The write chain per key: one write at a time, in order (with an ID, so a finished chain removes itself).
    private var chains: [String: (id: UInt64, task: Task<Void, Never>)] = [:]
    private var nextChain: UInt64 = 0
    /// The sequence last written per key.
    private var committed: [String: UInt64] = [:]
    /// Attachment ID → (byte count, file) already materialized (N27: typing does not rewrite or re-read the bytes).
    private var materialized: [String: (count: Int, url: URL)] = [:]
    private nonisolated let pinToken: UUID
    /// Test seam: runs before an attachment is written to the store.
    private let beforeMaterialize: (@Sendable () async -> Void)?
    private static let log = Logger(subsystem: "app.bellocode", category: "Drafts")

    public init(directory: URL, files: AttachmentFileStore, debounce: Duration = .milliseconds(250)) {
        self.init(directory: directory, files: files, debounce: debounce, beforeMaterialize: nil)
    }

    init(directory: URL, files: AttachmentFileStore, debounce: Duration, beforeMaterialize: (@Sendable () async -> Void)?) {
        self.directory = directory
        self.files = files
        self.debounce = debounce
        self.beforeMaterialize = beforeMaterialize
        let index = self.index
        pinToken = files.pins.add {
            // Records' store files, from memory once the index is loaded; from disk (off the main actor) before.
            if let drafts = index.withLock({ $0?.drafts }) { return Self.storeFiles(in: drafts.values) }
            return Self.storeFiles(in: Self.readRecords(in: directory).values)
        }
        Task { [weak self] in await self?.preload() }
    }

    deinit { files.pins.remove(pinToken) }

    nonisolated func url(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest.prefix(32)).json")
    }

    /// Whether `draft` needs a record (anything the text alone cannot restore).
    public nonisolated static func needsRecord(_ draft: ComposerDraft) -> Bool {
        !draft.attachments.isEmpty || !draft.tokens.isEmpty
    }

    /// Records `draft` for `key` after a short quiet period (the last call wins); a draft without tokens or
    /// attachments removes the record. Synchronous: call order is save order (N16).
    public nonisolated func save(_ draft: ComposerDraft, for key: String) {
        _ = intake.withLock { intake -> UInt64 in
            let sequence = (intake.sequence[key] ?? 0) + 1
            intake.sequence[key] = sequence
            intake.latest[key] = (sequence, draft)
            return sequence
        }
        Task { await self.schedule(key) }
    }

    private func schedule(_ key: String) {
        pending[key]?.cancel()
        let debounce = self.debounce
        pending[key] = Task {
            if debounce > .zero {
                do { try await Task.sleep(for: debounce) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self.enqueueCommit(key)
        }
    }

    /// Queues a write of `key`'s newest draft behind any write already running for it, and returns that write.
    @discardableResult
    private func enqueueCommit(_ key: String) -> Task<Void, Never> {
        pending[key]?.cancel()
        pending[key] = nil
        let previous = chains[key]?.task
        nextChain &+= 1
        let id = nextChain
        let task = Task {
            await previous?.value
            await self.commit(key)
            self.chainFinished(key, id)
        }
        chains[key] = (id, task)
        return task
    }

    private func chainFinished(_ key: String, _ id: UInt64) {
        if chains[key]?.id == id { chains[key] = nil }
    }

    /// Writes every pending save now and waits for writes already running (quit, send).
    public func flush() async {
        let keys = Set(intake.withLock { Array($0.latest.keys) }).union(chains.keys).union(pending.keys)
        let tasks = keys.map { enqueueCommit($0) }
        for task in tasks { await task.value }
    }

    /// Saves immediately (tests): hands `draft` over like `save`, then writes it.
    public func write(_ draft: ComposerDraft, for key: String) async {
        intake.withLock { intake in
            let sequence = (intake.sequence[key] ?? 0) + 1
            intake.sequence[key] = sequence
            intake.latest[key] = (sequence, draft)
        }
        await enqueueCommit(key).value
    }

    /// Writes the newest draft handed over for `key`, unless a newer one arrives while its attachments are stored.
    private func commit(_ key: String) async {
        guard let (sequence, draft) = intake.withLock({ $0.latest[key] }), sequence > committed[key] ?? 0 else { return }
        let file = url(for: key)
        var stored = draft
        if Self.needsRecord(draft) {
            var attachments: [ComposerAttachment] = []
            for attachment in draft.attachments {
                switch attachment.content {
                case .file:
                    attachments.append(attachment)
                case .data(let data):
                    if let url = await materialize(attachment, count: data.count) { attachments.append(attachment.stored(at: url)) }
                case .text(let text):
                    if let url = await materialize(attachment, count: text.utf8.count) { attachments.append(attachment.stored(at: url)) }
                }
            }
            stored.attachments = attachments
        }
        // Fence: a newer save (a clear after Send, a later edit) owns the record now; it is written by a later commit.
        guard intake.withLock({ $0.latest[key]?.sequence }) == sequence else { return }
        committed[key] = sequence
        intake.withLock { intake in
            if intake.latest[key]?.sequence == sequence { intake.latest[key] = nil }
        }
        guard Self.needsRecord(draft) else {
            try? FileManager.default.removeItem(at: file)
            index.withLock { $0?.drafts[key] = nil }
            return
        }
        let record = Record(version: Self.currentVersion, key: key, saved: Date(), draft: stored)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try encoder.encode(record).write(to: file, options: [.atomic])
            index.withLock { $0?.drafts[key] = stored }
        } catch {
            Self.log.error("a draft record could not be written")
        }
        prune()
    }

    /// The store file for an in-memory attachment, written once per attachment ID.
    private func materialize(_ attachment: ComposerAttachment, count: Int) async -> URL? {
        if let known = materialized[attachment.id], known.count == count,
           (try? FileManager.default.attributesOfItem(atPath: known.url.path)[.size] as? Int) == count
        {
            return known.url
        }
        await beforeMaterialize?()
        do {
            let url = try await files.materialize(attachment)
            if materialized.count >= Self.maxMaterialized { materialized = [:] }
            materialized[attachment.id] = (count, url)
            return url
        } catch {
            // Kept in memory for this session; the record keeps the rest (never the whole draft lost).
            Self.log.error("a draft attachment could not be stored")
            return nil
        }
    }

    /// Reads every record into memory off the main actor (attachments whose files are gone are dropped here, once).
    public func preload() async {
        guard index.withLock({ $0 == nil }) else { return }
        let drafts = Self.readRecords(in: directory).mapValues { draft in
            var draft = draft
            draft.attachments = draft.attachments.filter { attachment in
                guard let url = attachment.fileURL else { return true }
                return FileManager.default.fileExists(atPath: url.path)
            }
            return draft
        }
        // Synchronous from here on the actor: no write can finish between the read and publishing the index.
        index.withLock { index in
            if index == nil { index = Index(drafts: drafts) }
        }
    }

    /// The recorded draft for `key`, if any (a record of a newer, unknown version is ignored).
    public nonisolated func load(_ key: String) -> ComposerDraft? {
        if let drafts = index.withLock({ $0?.drafts }) { return drafts[key] }
        guard let data = try? Data(contentsOf: url(for: key)), let record = Self.decode(data), record.key == key else { return nil }
        return record.draft
    }

    /// Combines the stored draft text (the source of truth for text) with a record: the full draft when the text is
    /// the one the record was saved with, otherwise the text with the record's attachments (its token ranges no longer
    /// apply). Nil without a record: the caller uses the text alone (legacy drafts). Reads memory once `preload` ran;
    /// only a selection in the first moments after launch reads its one record from disk.
    public nonisolated func restore(_ key: String, text: String) -> ComposerDraft? {
        let indexed = index.withLock { $0 != nil }
        guard let record = load(key) else { return nil }
        let present = indexed ? record.attachments : record.attachments.filter { attachment in
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

    /// Files inside the attachment store that records reference (launch clean-up keeps them). Off the main actor.
    public func referencedFiles() async -> Set<URL> {
        if let drafts = index.withLock({ $0?.drafts }) { return Self.storeFiles(in: drafts.values) }
        return Self.storeFiles(in: Self.readRecords(in: directory).values)
    }

    private nonisolated static func storeFiles(in drafts: some Sequence<ComposerDraft>) -> Set<URL> {
        var urls: Set<URL> = []
        for draft in drafts { for attachment in draft.attachments { if let url = attachment.fileURL { urls.insert(url) } } }
        return urls
    }

    private nonisolated static func decode(_ data: Data) -> Record? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let record = try? decoder.decode(Record.self, from: data), record.version <= currentVersion else { return nil }
        return record
    }

    private nonisolated static func readRecords(in directory: URL) -> [String: ComposerDraft] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [:] }
        var drafts: [String: ComposerDraft] = [:]
        for entry in entries.prefix(maxRecords * 2) where entry.pathExtension == "json" {
            guard let data = try? Data(contentsOf: entry), let record = decode(data) else { continue }
            drafts[record.key] = record.draft
        }
        return drafts
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
        for entry in sorted.prefix(entries.count - Self.maxRecords) {
            if let data = try? Data(contentsOf: entry), let record = Self.decode(data) { index.withLock { $0?.drafts[record.key] = nil } }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}

extension ComposerAttachment {
    /// The attachment recorded by the file it was written to.
    func stored(at url: URL) -> ComposerAttachment {
        var copy = self
        copy.content = .file(url)
        return copy
    }
}
