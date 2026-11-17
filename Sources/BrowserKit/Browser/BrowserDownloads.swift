import AppKit
import Foundation
import Observation
import OpenCodeKit
import WebKit

/// Downloads to the Downloads folder, shown in a small shelf; completed files can be revealed in Finder. The agent sees
/// completed downloads of its tabs through `files.list`/`files.get`.
///
/// Bounded (review M9): at most `activeLimit` downloads write at once; up to `queueLimit` more wait for a slot
/// ("Queued": WebKit is not given a destination until then); beyond that a new download is cancelled and shown as
/// "Refused". The shelf keeps at most `limit` entries, trimming the oldest finished ones whenever one is added or ends.
@MainActor
@Observable
public final class BrowserDownloads: NSObject {
    public enum State: Equatable, Sendable {
        case running(fraction: Double?)
        /// Waiting for one of the `activeLimit` slots.
        case queued
        case finished
        /// Not started: too many downloads at once.
        case refused(String)
        case failed(String)
        case cancelled
    }

    @MainActor
    @Observable
    public final class Item: Identifiable {
        public let id = UUID()
        public internal(set) var filename: String
        public internal(set) var destination: URL?
        public internal(set) var state: State = .running(fraction: nil)
        public internal(set) var bytes: Int64 = 0
        /// The finished file as it was when the download ended; `files.get` refuses a file that no longer matches.
        public internal(set) var identity: DownloadFileIdentity?
        /// The tab that started it (agent `files.*` scope).
        public let tabID: String?
        public let fileID = BrowserContract.newFileID()
        @ObservationIgnored weak var download: WKDownload?
        @ObservationIgnored var observation: NSKeyValueObservation?

        init(filename: String, tabID: String?) {
            self.filename = filename
            self.tabID = tabID
        }
    }

    /// Entries kept in the shelf.
    public static let limit = 20
    /// Downloads writing at once.
    public static let activeLimit = 3
    /// Downloads waiting for a slot; more are refused.
    public static let queueLimit = 7
    public private(set) var items: [Item] = []
    /// The folder downloads go to (the person's Downloads folder; the demo harness uses a temporary one).
    public var folder: URL
    public var onChange: (() -> Void)?

    public init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        super.init()
    }

    public var hasActive: Bool { items.contains(where: \.isLive) }

    func track(_ download: WKDownload, tabID: String?) {
        let item = Item(filename: download.originalRequest?.url?.lastPathComponent ?? "download", tabID: tabID)
        item.download = download
        download.delegate = self
        guard admit(item) else {
            download.cancel { _ in }
            return
        }
        observe(download.progress, for: item)
    }

    /// Adds an item as running, queued or refused (see the type's comment). Returns false when refused.
    @discardableResult
    func admit(_ item: Item) -> Bool {
        let running = items.count { if case .running = $0.state { true } else { false } }
        let queued = items.count { $0.state == .queued }
        if running < Self.activeLimit {
            item.state = .running(fraction: nil)
        } else if queued < Self.queueLimit {
            item.state = .queued
        } else {
            item.state = .refused("Too many downloads at once. Try again when one finishes.")
        }
        items.insert(item, at: 0)
        trim()
        onChange?()
        if case .refused = item.state { return false }
        return true
    }

    /// Progress from KVO, which WebKit posts on whatever thread updates it (review m1): the values are read there and
    /// handed to the main actor explicitly.
    func observe(_ progress: Progress, for item: Item) {
        item.observation = Self.observeProgress(progress) { [weak self, weak item] fraction, completed in
            guard let item, case .running = item.state, completed >= item.bytes else { return }
            item.state = .running(fraction: fraction)
            item.bytes = completed
            self?.onChange?()
        }
    }

    nonisolated private static func observeProgress(
        _ progress: Progress, apply: @escaping @MainActor @Sendable (Double?, Int64) -> Void
    ) -> NSKeyValueObservation {
        progress.observe(\.fractionCompleted) { progress, _ in
            let fraction = progress.totalUnitCount > 0 ? progress.fractionCompleted : nil
            let completed = progress.completedUnitCount
            Task { @MainActor in apply(fraction, completed) }
        }
    }

    public func cancel(_ item: Item) {
        item.download?.cancel { _ in }
        end(item, as: .cancelled)
    }

    /// A download left the running or queued state: frees its slot (or its queue place) and trims the shelf.
    func end(_ item: Item, as state: State) {
        let wasRunning = if case .running = item.state { true } else { false }
        guard item.isLive else { return }
        item.state = state
        item.observation = nil
        if let waiter = slotWaiters.removeValue(forKey: item.id) { waiter.resume(returning: false) }
        if wasRunning { promoteQueued() }
        trim()
        onChange?()
    }

    /// Starts the oldest queued download in the freed slot.
    private func promoteQueued() {
        guard let next = items.last(where: { $0.state == .queued }) else { return }
        next.state = .running(fraction: nil)
        slotWaiters.removeValue(forKey: next.id)?.resume(returning: true)
    }

    /// Suspends a queued download's destination decision until it has a slot; false when it was cancelled meanwhile.
    func waitForSlot(_ item: Item) async -> Bool {
        switch item.state {
        case .running: return true
        case .queued: return await withCheckedContinuation { slotWaiters[item.id] = $0 }
        default: return false
        }
    }

    @ObservationIgnored private var slotWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// Drops the oldest ended entries beyond `limit`. Live entries are at most `activeLimit + queueLimit` (< `limit`).
    private func trim() {
        var excess = items.count - Self.limit
        guard excess > 0 else { return }
        for index in items.indices.reversed() where excess > 0 && !items[index].isLive {
            items.remove(at: index)
            excess -= 1
        }
    }

    public func reveal(_ item: Item) {
        guard let destination = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    public func clearFinished() {
        items.removeAll { !$0.isLive }
        onChange?()
    }

    /// A unique file URL in the folder: `name.ext`, `name 2.ext`, …
    nonisolated static func uniqueDestination(in folder: URL, suggested: String) -> URL {
        let safe = suggested.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let name = safe.isEmpty ? "download" : safe
        var candidate = folder.appending(path: name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            index += 1
        }
        return candidate
    }

    private func item(for download: WKDownload) -> Item? { items.first { $0.download === download } }

    /// Completed downloads started by a tab, as agent files (bounded by `BrowserContract.maxFileBytes` on read).
    func completed(forTab tabID: String) -> [Item] {
        items.filter { $0.tabID == tabID && $0.state == .finished }
    }
}

extension BrowserDownloads.Item {
    /// Running or queued.
    var isLive: Bool {
        switch state {
        case .running, .queued: true
        case .finished, .failed, .cancelled, .refused: false
        }
    }
}

extension BrowserDownloads: WKDownloadDelegate {
    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        // A queued download gets no destination (WebKit writes nothing) until a slot frees; nil cancels it.
        guard let item = item(for: download), await waitForSlot(item) else { return nil }
        let destination = Self.uniqueDestination(in: folder, suggested: suggestedFilename)
        item.filename = destination.lastPathComponent
        item.destination = destination
        onChange?()
        return destination
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download), case .running = item.state else { return }
        item.observation = nil
        guard let destination = item.destination else { return end(item, as: .finished) }
        // Record what was written (off the main actor); `files.get` hands out exactly that file or nothing.
        Task { [weak self, weak item] in
            let identity = await DownloadFileIdentity.read(destination)
            guard let self, let item, case .running = item.state else { return }
            item.identity = identity
            if let identity { item.bytes = identity.size }
            self.end(item, as: .finished)
        }
    }

    public func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        let nsError = error as NSError
        end(item, as: nsError.code == NSURLErrorCancelled ? .cancelled : .failed(nsError.localizedDescription))
    }
}

/// A finished download's file identity: device, inode, size and modification time of a regular file (not a link).
public struct DownloadFileIdentity: Sendable, Hashable {
    public var device: UInt64
    public var inode: UInt64
    public var size: Int64
    public var modifiedSeconds: Int
    public var modifiedNanoseconds: Int

    init(_ info: stat) {
        device = UInt64(bitPattern: Int64(info.st_dev))
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }

    /// The identity of the file at `url`, nil unless it is a regular file (a symbolic link is not followed).
    @concurrent public static func read(_ url: URL) async -> DownloadFileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return DownloadFileIdentity(info)
    }
}

/// Why a finished download could not be handed to the agent.
public enum DownloadReadError: Error, Sendable, Equatable {
    /// Moved, replaced, linked, grown or rewritten since the download finished.
    case changed
    case tooLarge
    case unavailable
}

extension BrowserDownloads {
    /// Reads a finished download for `files.get` (review M8), off the main actor: the file is opened without following
    /// a link, must still be the very file that finished (device, inode, size, modification time, checked on the open
    /// descriptor before and after reading), and is read with a hard cap of `limit` bytes, checking cancellation.
    @concurrent public static func readVerified(_ url: URL, identity: DownloadFileIdentity, limit: Int) async throws -> Data {
        guard identity.size <= Int64(limit) else { throw DownloadReadError.tooLarge }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw errno == ELOOP ? DownloadReadError.changed : DownloadReadError.unavailable }
        defer { close(descriptor) }
        func current() throws -> DownloadFileIdentity {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw DownloadReadError.unavailable }
            guard info.st_mode & S_IFMT == S_IFREG else { throw DownloadReadError.changed }
            return DownloadFileIdentity(info)
        }
        guard try current() == identity else { throw DownloadReadError.changed }
        let expected = Int(identity.size)
        var data = Data(count: expected + 1)
        var total = 0
        while total <= expected {
            try Task.checkCancellation()
            let chunk = min(64 << 10, expected + 1 - total)
            let count = data.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress! + total, chunk)
            }
            if count < 0 { throw DownloadReadError.unavailable }
            if count == 0 { break }
            total += count
        }
        // More bytes than recorded, fewer, or any change during the read: not the file that finished.
        guard total == expected, try current() == identity else { throw DownloadReadError.changed }
        data.count = total
        return data
    }
}
