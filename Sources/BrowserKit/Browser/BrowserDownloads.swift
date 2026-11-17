import AppKit
import Foundation
import Observation
import OpenCodeKit
import WebKit

/// Downloads to the Downloads folder, shown in a small shelf. Bounded list; completed files can be revealed in Finder.
/// The agent sees completed downloads of its tabs through `files.list`/`files.get`.
@MainActor
@Observable
public final class BrowserDownloads: NSObject {
    public enum State: Equatable, Sendable {
        case running(fraction: Double?)
        case finished
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

    public static let limit = 20
    public private(set) var items: [Item] = []
    /// The folder downloads go to (the person's Downloads folder; the demo harness uses a temporary one).
    public var folder: URL
    public var onChange: (() -> Void)?

    public init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        super.init()
    }

    public var hasActive: Bool { items.contains { if case .running = $0.state { true } else { false } } }

    func track(_ download: WKDownload, tabID: String?) {
        let item = Item(filename: download.originalRequest?.url?.lastPathComponent ?? "download", tabID: tabID)
        item.download = download
        item.observation = download.progress.observe(\.fractionCompleted) { [weak self, weak item] progress, _ in
            let fraction = progress.totalUnitCount > 0 ? progress.fractionCompleted : nil
            let completed = progress.completedUnitCount
            MainActor.assumeIsolated {
                guard let item, case .running = item.state else { return }
                item.state = .running(fraction: fraction)
                item.bytes = completed
                self?.onChange?()
            }
        }
        download.delegate = self
        items.insert(item, at: 0)
        if items.count > Self.limit {
            items.removeAll { item in
                guard items.count > Self.limit else { return false }
                if case .running = item.state { return false }
                return true
            }
        }
        onChange?()
    }

    public func cancel(_ item: Item) {
        item.download?.cancel { _ in }
        item.state = .cancelled
        onChange?()
    }

    public func reveal(_ item: Item) {
        guard let destination = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    public func clearFinished() {
        items.removeAll { if case .running = $0.state { false } else { true } }
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

extension BrowserDownloads: WKDownloadDelegate {
    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let destination = Self.uniqueDestination(in: folder, suggested: suggestedFilename)
        if let item = item(for: download) {
            item.filename = destination.lastPathComponent
            item.destination = destination
        }
        onChange?()
        return destination
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.state = .finished
        if let destination = item.destination,
           let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber {
            item.bytes = size.int64Value
        }
        item.observation = nil
        onChange?()
    }

    public func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        let nsError = error as NSError
        item.state = nsError.code == NSURLErrorCancelled ? .cancelled : .failed(nsError.localizedDescription)
        item.observation = nil
        onChange?()
    }
}
