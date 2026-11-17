import Foundation
import os

/// Writes pasted images and large pasted text to files in an app-owned directory, so they can be sent as `file://`
/// URIs (opencode's prompt input has no byte field). Bounded by age and total size, on every write as well as at
/// launch: the oldest files go first, but never one written within `inUseGrace` (a send may still be queued and opencode
/// reads the file when it delivers). If the budget cannot be met without those, the write fails visibly
/// (`StoreError.full`) instead of exceeding it. Drafts keep their bytes in memory, so a file is only needed from send
/// to delivery.
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

    /// The file URL to send for an attachment: files on disk as they are; image bytes and text written here.
    @concurrent
    public func materialize(_ attachment: ComposerAttachment) async throws -> URL {
        switch attachment.content {
        case .file(let url):
            return url
        case .data(let data):
            return try write(data, for: attachment)
        case .text(let text):
            return try write(Data(text.utf8), for: attachment)
        }
    }

    private func write(_ data: Data, for attachment: ComposerAttachment) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folder = directory.appending(path: Self.safeComponent(attachment.id), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: Self.safeComponent(attachment.name))
        if let existing = try? Data(contentsOf: file), existing == data { return file }
        try data.write(to: file, options: [.atomic])
        // Enforce the budget now, not only at launch: evict the oldest unprotected folders; if that is not enough,
        // remove what was just written and fail.
        let total = evict(now: Date(), protecting: [folder.lastPathComponent])
        if total > maxTotalBytes {
            try? FileManager.default.removeItem(at: folder)
            throw StoreError.full
        }
        return file
    }

    /// Removes expired folders, then the oldest until the total fits (launch). Returns how many folders were removed.
    @discardableResult
    @concurrent
    public func cleanUp(now: Date = Date()) async -> Int {
        var removed = 0
        _ = evict(now: now, protecting: [], removed: &removed)
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
            let inUse = protecting.contains(entry.url.lastPathComponent) || age < graceSeconds
            guard expired || (total > maxTotalBytes && !inUse) else { continue }
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
