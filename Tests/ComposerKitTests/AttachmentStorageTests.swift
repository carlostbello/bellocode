import Foundation
import Testing
@testable import ComposerKit

/// M7 (docs/reviews/M1-review.md): attachment files are bounded on every write; preview files are owned and deleted.
@Suite struct AttachmentStorageTests {
    func directory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "composer-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    func total(_ directory: URL) -> Int {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        return folders.reduce(0) { sum, folder in
            let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return sum + files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        }
    }

    /// A long session without relaunch: the total never exceeds the budget; files past the in-use grace are evicted.
    @Test func budgetIsEnforcedOnEveryWrite() async throws {
        let root = directory("budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(directory: root, maxTotalBytes: 100, inUseGrace: .zero)
        for index in 0..<50 {
            _ = try await store.materialize(.text(String(repeating: "x", count: 30), name: "paste\(index).txt"))
            #expect(total(root) <= 100, "after write \(index): \(total(root)) bytes")
        }
    }

    /// Recent attachments (a send may still be queued) are not evicted; a write that cannot fit fails and leaves
    /// nothing behind.
    @Test func inUseAttachmentsAreKeptAndOverflowFails() async throws {
        let root = directory("inuse")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(directory: root, maxTotalBytes: 100, inUseGrace: .seconds(3600))
        let first = try await store.materialize(.text(String(repeating: "a", count: 60), name: "a.txt"))
        await #expect(throws: AttachmentFileStore.StoreError.self) {
            _ = try await store.materialize(.text(String(repeating: "b", count: 60), name: "b.txt"))
        }
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(total(root) == 60)
        // Once the first is past the grace period, it makes room.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: first.deletingLastPathComponent().path)
        _ = try await store.materialize(.text(String(repeating: "c", count: 60), name: "c.txt"))
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(total(root) == 60)
    }

    @Test func previewFilesAreOwnedAndCleaned() async throws {
        let root = directory("previews")
        defer { try? FileManager.default.removeItem(at: root) }
        let previews = PreviewFiles(root: root, processID: ProcessInfo.processInfo.processIdentifier)
        let url = try #require(previews.write(Data("secret".utf8), name: "paste.txt", id: "att_1"))
        #expect(FileManager.default.fileExists(atPath: url.path))
        previews.remove(id: "att_1")
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // A crashed process's folder (pid not running) is removed at launch; this process's folder is kept.
        let ours = try #require(previews.write(Data("x".utf8), name: "a.txt", id: "att_2"))
        let crashed = PreviewFiles(root: root, processID: 999_999)
        let stale = try #require(crashed.write(Data("old".utf8), name: "b.txt", id: "att_3"))
        try Data("loose".utf8).write(to: root.appending(path: "legacy-file"))
        #expect(await previews.cleanUpAbandoned() == 2)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: ours.path))
        await previews.removeAll()
        #expect(!FileManager.default.fileExists(atPath: ours.path))
    }
}
