import Foundation
import Testing

@testable import BrowserKit

/// Review M8, M9 and m1: downloads are verified at read time, admission is bounded, progress hops to the main actor.
@MainActor @Suite struct BrowserDownloadSafetyTests {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "bellocode-downloads-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: M8

    @Test func readReturnsTheFinishedFileAndRefusesReplacementGrowthAndLinks() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "report.csv")
        try Data("a,b\n1,2\n".utf8).write(to: file)
        let identity = try #require(await DownloadFileIdentity.read(file))
        #expect(try await BrowserDownloads.readVerified(file, identity: identity, limit: 1_024) == Data("a,b\n1,2\n".utf8))

        // Replaced by another file of the same size (a different inode): refused.
        let secret = folder.appending(path: "secret")
        try Data("PASSWORD".utf8).write(to: secret)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: secret)
        await #expect(throws: DownloadReadError.changed) { try await BrowserDownloads.readVerified(file, identity: identity, limit: 1_024) }

        // Grown in place: refused, and never more than the cap is allocated for a small promise.
        try Data("x".utf8).write(to: file)
        let small = try #require(await DownloadFileIdentity.read(file))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 1 << 20))
        try handle.close()
        await #expect(throws: DownloadReadError.changed) { try await BrowserDownloads.readVerified(file, identity: small, limit: 1_024) }

        // Swapped for a symbolic link to another file: refused (the link is not followed).
        try Data("x".utf8).write(to: secret)
        try Data("x".utf8).write(to: file)
        let linkIdentity = try #require(await DownloadFileIdentity.read(file))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: secret)
        #expect(await DownloadFileIdentity.read(file) == nil, "a link is not a finished download")
        await #expect(throws: DownloadReadError.changed) { try await BrowserDownloads.readVerified(file, identity: linkIdentity, limit: 1_024) }

        // Larger than the cap: refused before reading.
        let big = folder.appending(path: "big.bin")
        try Data(count: 4_096).write(to: big)
        let bigIdentity = try #require(await DownloadFileIdentity.read(big))
        await #expect(throws: DownloadReadError.tooLarge) { try await BrowserDownloads.readVerified(big, identity: bigIdentity, limit: 1_024) }

        // Removed: unavailable.
        try FileManager.default.removeItem(at: big)
        await #expect(throws: DownloadReadError.unavailable) { try await BrowserDownloads.readVerified(big, identity: bigIdentity, limit: 8_192) }
    }

    @Test func readStopsWhenCancelled() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "data.bin")
        try Data(count: 256 << 10).write(to: file)
        let identity = try #require(await DownloadFileIdentity.read(file))
        let task = Task { try await BrowserDownloads.readVerified(file, identity: identity, limit: 1 << 20) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: M9

    @Test func aBurstOfDownloadsIsAdmittedQueuedOrRefusedAndTheShelfStaysBounded() async throws {
        let downloads = BrowserDownloads(folder: try Self.folder())
        let burst = (0..<30).map { BrowserDownloads.Item(filename: "file\($0)", tabID: "t") }
        let admitted = burst.map { downloads.admit($0) }
        let running = BrowserDownloads.activeLimit
        let queued = BrowserDownloads.queueLimit
        #expect(burst.prefix(running).allSatisfy { if case .running = $0.state { true } else { false } })
        #expect(burst.dropFirst(running).prefix(queued).allSatisfy { $0.state == .queued })
        #expect(burst.dropFirst(running + queued).allSatisfy { if case .refused = $0.state { true } else { false } })
        #expect(admitted.filter { $0 }.count == running + queued)
        #expect(downloads.items.count <= BrowserDownloads.limit)
        #expect(downloads.items.filter(\.isLive).count == running + queued, "no live entry is trimmed")

        // A queued download waits for a slot; finishing a running one starts the oldest queued one.
        let firstQueued = burst[running]
        let waiting = Task { await downloads.waitForSlot(firstQueued) }
        await Task.yield()
        downloads.end(burst[0], as: .finished)
        #expect(await waiting.value == true)
        if case .running = firstQueued.state {} else { Issue.record("promoted: \(firstQueued.state)") }
        // Cancelling a queued download releases its waiter with "no slot".
        let lastQueued = burst[running + queued - 1]
        let cancelled = Task { await downloads.waitForSlot(lastQueued) }
        await Task.yield()
        downloads.cancel(lastQueued)
        #expect(await cancelled.value == false)
        #expect(lastQueued.state == .cancelled)
        // Ended entries are trimmed when downloads end, not only when a new one starts.
        for item in burst where item.isLive { downloads.end(item, as: .finished) }
        #expect(downloads.items.count <= BrowserDownloads.limit)
        #expect(!downloads.hasActive)
    }

    // MARK: m1

    @Test func progressPostedOffTheMainThreadReachesTheItemOnTheMainActor() async throws {
        let downloads = BrowserDownloads(folder: try Self.folder())
        let item = BrowserDownloads.Item(filename: "f", tabID: nil)
        downloads.admit(item)
        let progress = Progress(totalUnitCount: 100)
        downloads.observe(progress, for: item)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                #expect(!Thread.isMainThread)
                progress.completedUnitCount = 40
                done.resume()
            }
        }
        for _ in 0..<1_000 where item.bytes != 40 { await Task.yield() }
        #expect(item.bytes == 40)
        #expect(item.state == .running(fraction: 0.4))
    }
}
