import Foundation
import Synchronization
import os

/// The files still needed from an attachment store, shared by every copy of the store for one directory: unsent draft
/// records and sends not yet settled register providers, and every eviction (launch clean-up and the budget check of
/// each write) protects what they return, so a new paste can never evict a file an unsent draft or a queued send
/// still references (A15).
public final class AttachmentPins: Sendable {
    public typealias Provider = @Sendable () async -> Set<URL>

    private let providers = Mutex<[UUID: Provider]>([:])
    private static let registry = Mutex<[String: AttachmentPins]>([:])

    init() {}

    /// The registry for a store directory (one per directory in the process).
    public static func shared(for directory: URL) -> AttachmentPins {
        let key = directory.standardizedFileURL.path
        return registry.withLock { registry in
            if let pins = registry[key] { return pins }
            let pins = AttachmentPins()
            registry[key] = pins
            return pins
        }
    }

    /// Adds a source of referenced files; the returned token removes it.
    @discardableResult
    public func add(_ provider: @escaping Provider) -> UUID {
        let id = UUID()
        providers.withLock { $0[id] = provider }
        return id
    }

    public func remove(_ id: UUID) { providers.withLock { _ = $0.removeValue(forKey: id) } }

    /// Every file a provider references now.
    public func files() async -> Set<URL> {
        let current = providers.withLock { Array($0.values) }
        var files: Set<URL> = []
        for provider in current { files.formUnion(await provider()) }
        return files
    }
}

/// Writes pasted images and large pasted text to files in an app-owned directory, so they can be sent as `file://`
/// URIs (opencode's prompt input has no byte field). Bounded by age and total size, on every write as well as at
/// launch: the oldest files go first, but never one written within `inUseGrace` (a send may still be queued and opencode
/// reads the file when it delivers) nor one `pins` reports as referenced (an unsent draft's record, a queued send).
/// If the budget cannot be met without those, the write fails visibly (`StoreError.full`) instead of exceeding it.
///
/// Files are named by attachment ID, so retrying a failed send reuses the same file. Writes and clean-up run off the
/// main actor. Threading: `Sendable` value; every method is safe from any context.
public struct AttachmentFileStore: Sendable {
    public let directory: URL
    /// Files older than this are deleted by `cleanUp()`.
    public var maxAge: Duration
    /// Total size kept; beyond it the oldest files are deleted.
    public var maxTotalBytes: Int
    /// Files written more recently than this are treated as in use and never evicted to make room.
    public var inUseGrace: Duration

    public enum StoreError: Error, LocalizedError {
        /// The attachment does not fit in the budget beside attachments still in use.
        case full

        public var errorDescription: String? {
            "Attachment storage is full (recent attachments may still be waiting to be delivered). Try again shortly or attach a smaller file."
        }
    }

    public init(
        directory: URL, maxAge: Duration = .seconds(7 * 24 * 3600), maxTotalBytes: Int = 512 * 1_048_576,
        inUseGrace: Duration = .seconds(3600)
    ) {
        self.directory = directory
        self.maxAge = maxAge
        self.maxTotalBytes = maxTotalBytes
        self.inUseGrace = inUseGrace
    }

    /// `~/Library/Application Support/BelloCode/attachments`.
    public static var applicationDefault: AttachmentFileStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return AttachmentFileStore(directory: base.appending(path: "BelloCode/attachments", directoryHint: .isDirectory))
    }

    /// Every file the store must keep however old (shared by all copies of the store for this directory).
    public var pins: AttachmentPins { AttachmentPins.shared(for: directory) }

    /// The file URL to send for an attachment: files on disk as they are; image bytes and text written here.
    @concurrent
    public func materialize(_ attachment: ComposerAttachment) async throws -> URL {
        switch attachment.content {
        case .file(let url):
            return url
        case .data(let data):
            return try await write(data, for: attachment)
        case .text(let text):
            return try await write(Data(text.utf8), for: attachment)
        }
    }

    private func write(_ data: Data, for attachment: ComposerAttachment) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folder = directory.appending(path: Self.safeComponent(attachment.id), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: Self.safeComponent(attachment.name))
        // Files are named by attachment ID, whose bytes never change: an existing file of the same size is the same
        // attachment, compared without reading it back (N27); a different size is rewritten.
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? nil
        if size == data.count { return file }
        try data.write(to: file, options: [.atomic])
        // Enforce the budget now, not only at launch: evict the oldest folders no one references; if that is not
        // enough, remove what was just written and fail.
        let pinned = folders(of: await pins.files())
        let total = evict(now: Date(), protecting: pinned.union([folder.lastPathComponent]))
        if total > maxTotalBytes {
            try? FileManager.default.removeItem(at: folder)
            throw StoreError.full
        }
        return file
    }

    /// Removes expired folders, then the oldest until the total fits (launch). Returns how many folders were removed.
    /// `keeping` and everything `pins` reports: files that unsent drafts or sends not yet settled still reference;
    /// their folders are never removed, however old.
    @discardableResult
    @concurrent
    public func cleanUp(now: Date = Date(), keeping files: Set<URL> = []) async -> Int {
        var removed = 0
        let kept = files.union(await pins.files())
        _ = evict(now: now, protecting: folders(of: kept), removed: &removed)
        if removed > 0 { AttachmentFileStore.log.info("removed \(removed) attachment folders") }
        return removed
    }

    /// Evicts expired folders, then the oldest folders outside `inUseGrace` and `protecting` until the total fits.
    /// Returns the total size left.
    @discardableResult
    func evict(now: Date, protecting: Set<String>) -> Int {
        var removed = 0
        return evict(now: now, protecting: protecting, removed: &removed)
    }

    /// The attachment folders (named by attachment ID) that hold `files`.
    func folders(of files: Set<URL>) -> Set<String> {
        let root = directory.standardizedFileURL.path
        return Set(files.compactMap { file in
            let folder = file.standardizedFileURL.deletingLastPathComponent()
            return folder.deletingLastPathComponent().path == root ? folder.lastPathComponent : nil
        })
    }

    private func evict(now: Date, protecting: Set<String>, removed: inout Int) -> Int {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let folders = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var entries: [(url: URL, date: Date, size: Int)] = []
        for folder in folders {
            let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            var size = 0
            if let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) {
                for file in files { size += (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }
            }
            entries.append((folder, date, size))
        }
        entries.sort { $0.date < $1.date }
        let maxAgeSeconds = Double(maxAge.components.seconds)
        let graceSeconds = Double(inUseGrace.components.seconds)
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries {
            let age = now.timeIntervalSince(entry.date)
            let expired = age > maxAgeSeconds
            let protected = protecting.contains(entry.url.lastPathComponent)
            let inUse = protected || age < graceSeconds
            guard !protected, expired || (total > maxTotalBytes && !inUse) else { continue }
            if (try? manager.removeItem(at: entry.url)) != nil {
                total -= entry.size
                removed += 1
            }
        }
        return total
    }

    static func safeComponent(_ name: String) -> String {
        let cleaned = name.map { "/:\\\0".contains($0) ? "_" : $0 }
        let string = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty || string == "." || string == ".." ? "attachment" : String(string.prefix(120))
    }

    private static let log = Logger(subsystem: "app.bellocode", category: "Attachments")
}
