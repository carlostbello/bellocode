import Foundation
import Testing

@testable import Engine

/// S6 (docs/reviews/deep-review-1.md): an HTML visual reads a file only from the calling thread's project and worktree
/// folders (after resolving symlinks and `..`), only a regular file, and with a size cap applied while reading.
@Suite("Visual file authorisation")
struct VisualFileAuthorisationTests {
    let root: URL
    let project: String
    let worktree: String
    let outside: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "bellocode-s6-\(UUID().uuidString)", directoryHint: .isDirectory)
        project = root.appending(path: "project").path
        worktree = root.appending(path: "worktrees/feature").path
        outside = root.appending(path: "elsewhere").path
        for folder in [project, worktree, outside] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        try "<p>inside</p>".write(toFile: project + "/chart.html", atomically: true, encoding: .utf8)
        try "<p>worktree</p>".write(toFile: worktree + "/w.html", atomically: true, encoding: .utf8)
        try "SECRET host file".write(toFile: outside + "/secret.html", atomically: true, encoding: .utf8)
    }

    func read(_ path: String, limit: Int = 2 << 20) throws -> String {
        try VisualService.readAuthorisedFile(path, base: project, roots: [project, worktree], limit: limit)
    }

    @Test func filesInTheProjectAndItsWorktreesAreRead() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try read("chart.html") == "<p>inside</p>")
        #expect(try read(project + "/chart.html") == "<p>inside</p>")
        #expect(try read(worktree + "/w.html") == "<p>worktree</p>")
    }

    @Test func pathsOutsideAreRefused() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ExtrasError.self) { try read(outside + "/secret.html") }
        #expect(throws: ExtrasError.self) { try read("../elsewhere/secret.html") }
        #expect(throws: ExtrasError.self) { try read(project + "/../elsewhere/secret.html") }
        #expect(throws: ExtrasError.self) { try read("/etc/hosts") }
    }

    @Test func symlinksAreResolvedBeforeTheCheck() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(atPath: project + "/link.html", withDestinationPath: outside + "/secret.html")
        try FileManager.default.createSymbolicLink(atPath: project + "/dir", withDestinationPath: outside)
        #expect(throws: ExtrasError.self) { try read("link.html") }
        #expect(throws: ExtrasError.self) { try read("dir/secret.html") }
        // A link that stays inside is fine.
        try FileManager.default.createSymbolicLink(atPath: project + "/alias.html", withDestinationPath: project + "/chart.html")
        #expect(try read("alias.html") == "<p>inside</p>")
    }

    @Test func onlyRegularFilesWithinTheCapAreRead() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(atPath: project + "/zero.html", withDestinationPath: "/dev/zero")
        #expect(throws: ExtrasError.self) { try read("zero.html") }
        #expect(mkfifo(project + "/pipe.html", 0o600) == 0)
        #expect(throws: ExtrasError.self) { try read("pipe.html") }
        #expect(throws: ExtrasError.self) { try read(project) }
        // The cap is applied to the bytes read from the opened file, not to an earlier size check.
        try String(repeating: "x", count: 17).write(toFile: project + "/big.html", atomically: true, encoding: .utf8)
        #expect(throws: ExtrasError.self) { try read("big.html", limit: 16) }
        #expect(try read("big.html", limit: 17).count == 17)
    }
}
