import Foundation
import Testing

@testable import ComposerKit

/// Deep review 1, C6: launch clean-up keeps the files of sends that are not settled, however old.
@Suite struct AttachmentOutboxTests {
    @Test func cleanUpKeepsFilesStillReferencedByTheOutbox() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "attachments-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentFileStore(directory: root, maxAge: .seconds(60), maxTotalBytes: 1 << 20, inUseGrace: .seconds(1))
        var files: [URL] = []
        for name in ["kept", "expired"] {
            let folder = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "a.txt")
            try Data("x".utf8).write(to: file)
            files.append(file)
        }
        let later = Date().addingTimeInterval(3_600)
        let removed = await store.cleanUp(now: later, keeping: [files[0]])
        #expect(removed == 1)
        #expect(FileManager.default.fileExists(atPath: files[0].path))
        #expect(!FileManager.default.fileExists(atPath: files[1].path))
    }
}
