import BelloCore
import Foundation
import MockOpenCode
import Testing

@testable import Engine

/// v1.0.0 reviews A05, A14, N17: rewind writes stay inside the worktree through ancestor links, submodules on either
/// side are refused, file↔directory transitions restore, and a rewind that opencode refuses leaves nothing staged.
@Suite("Rewind confinement and completeness", .timeLimit(.minutes(3)))
struct RewindConfinementTests {
    /// Two disposable directories: the worktree and somewhere outside it that must stay untouched.
    struct Dirs {
        let base: URL
        var root: String { base.appending(path: "root").path }
        var outside: String { base.appending(path: "outside").path }
        init() throws {
            base = FileManager.default.temporaryDirectory.appending(path: "bellocode-confine-\(UUID().uuidString)").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(atPath: base.appending(path: "root").path, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: base.appending(path: "outside").path, withIntermediateDirectories: true)
        }
        func remove() { try? FileManager.default.removeItem(at: base) }
        func outsideContents() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: outside))?.sorted() ?? [] }
    }

    /// A05: a directory above a missing file is replaced by a link after planning; the create must not land outside.
    @Test func anExistingAncestorSwappedForALinkIsRefused() throws {
        let dirs = try Dirs()
        defer { dirs.remove() }
        try FileManager.default.createDirectory(atPath: dirs.root + "/sub", withIntermediateDirectories: true)
        let root = dirs.root, outside = dirs.outside
        let copy = WorkingCopy(root: root, beforeReplace: { _ in
            try? FileManager.default.removeItem(atPath: root + "/sub")
            try? FileManager.default.createSymbolicLink(atPath: root + "/sub", withDestinationPath: outside)
        })
        let plan = copy.planRestore(path: "sub/new.txt", to: Data("restored\n".utf8))
        #expect(plan.before.data == nil)
        #expect(throws: WorkingCopyError.unsupported("sub/new.txt")) { try copy.apply([plan]) }
        #expect(dirs.outsideContents().isEmpty)
    }

    /// A05: a missing ancestor that appears as a link after planning is refused too (no `mkdir -p` through it).
    @Test func aMissingAncestorThatAppearsAsALinkIsRefused() throws {
        let dirs = try Dirs()
        defer { dirs.remove() }
        let root = dirs.root, outside = dirs.outside
        let copy = WorkingCopy(root: root, beforeReplace: { _ in
            try? FileManager.default.createSymbolicLink(atPath: root + "/deep", withDestinationPath: outside)
        })
        let plan = copy.planRestore(path: "deep/er/new.txt", to: Data("restored\n".utf8))
        #expect(throws: WorkingCopyError.unsupported("deep/er/new.txt")) { try copy.apply([plan]) }
        #expect(dirs.outsideContents().isEmpty)
    }

    /// A05: a replace whose parent becomes a link to a directory holding a file with the same bytes (so a content
    /// compare-and-swap alone would pass) must not swap the outside file.
    @Test func aReplaceThroughAnAncestorLinkWithMatchingBytesIsRefused() throws {
        let dirs = try Dirs()
        defer { dirs.remove() }
        try FileManager.default.createDirectory(atPath: dirs.root + "/sub", withIntermediateDirectories: true)
        try Data("same\n".utf8).write(to: URL(filePath: dirs.root + "/sub/f.txt"))
        try Data("same\n".utf8).write(to: URL(filePath: dirs.outside + "/f.txt"))
        let root = dirs.root, outside = dirs.outside
        let copy = WorkingCopy(root: root, beforeReplace: { _ in
            try? FileManager.default.moveItem(atPath: root + "/sub", toPath: root + "/moved")
            try? FileManager.default.createSymbolicLink(atPath: root + "/sub", withDestinationPath: outside)
        })
        let plan = copy.planRestore(path: "sub/f.txt", to: Data("restored\n".utf8))
        #expect(throws: WorkingCopyError.unsupported("sub/f.txt")) { try copy.apply([plan]) }
        #expect(try String(contentsOfFile: dirs.outside + "/f.txt", encoding: .utf8) == "same\n")
        #expect(dirs.outsideContents() == ["f.txt"])
    }

    /// A05/A14: a path through a link snapshots as unsupported (never followed), distinct from missing.
    @Test func aSnapshotThroughALinkIsUnsupportedNotTheLinkedFile() throws {
        let dirs = try Dirs()
        defer { dirs.remove() }
        try Data("secret\n".utf8).write(to: URL(filePath: dirs.outside + "/f.txt"))
        try FileManager.default.createSymbolicLink(atPath: dirs.root + "/link", withDestinationPath: dirs.outside)
        let copy = WorkingCopy(root: dirs.root)
        let through = copy.snapshot("link/f.txt")
        #expect(through.data == nil && through.kind == .unsupported)
        let missing = copy.snapshot("nothing/here.txt")
        #expect(missing.data == nil && missing.kind == .regular)
        let leaf = copy.snapshot("link")
        #expect(leaf.kind == .symlink && leaf.text == dirs.outside)
        #expect(throws: WorkingCopyError.unsupported("link/f.txt")) { try copy.apply([FileChangePlan(before: through, after: nil)]) }
        #expect(FileManager.default.fileExists(atPath: dirs.outside + "/f.txt"))
    }

    /// A14/N17: a submodule added after the checkpoint (gitlink only on the current side) refuses the plan.
    @Test func aSubmoduleAddedSinceTheCheckpointIsRefused() async throws {
        let repo = try await TempRepo.make(files: ["a.txt": "a\n"])
        defer { repo.remove() }
        let session = SessionID(rawValue: "ses_sub")
        let ref = GitCheckpoints.ref(session: session, message: MessageID(rawValue: "msg_1"))
        let checkpoint = try #require(try await GitCheckpoints.capture(directory: repo.path, ref: ref, runner: repo.runner))
        // The agent's turn: a nested repository appears (captured as a gitlink, mode 160000).
        let nested = repo.path + "/vendor/lib"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try await repo.git("init", "-q", "-b", "main", in: nested)
        try Data("x\n".utf8).write(to: URL(filePath: nested + "/x.txt"))
        try await repo.git("add", "-A", in: nested)
        try await repo.git("commit", "-q", "-m", "nested", in: nested)
        try repo.write("a.txt", "agent\n")
        let undoRef = GitCheckpoints.ref(session: session, message: MessageID(rawValue: "undo-msg_1"))
        await #expect(throws: GitCheckpoints.RestoreError.unsupportedEntry(path: "vendor/lib", mode: "160000")) {
            _ = try await GitCheckpoints.planRestore(directory: repo.path, checkpoint: checkpoint, undoRef: undoRef, runner: repo.runner)
        }
        #expect(try repo.read("a.txt") == "agent\n", "nothing was written")
    }

    /// N17: a file that became a directory (and the reverse) restores, and Undo returns the later state.
    @Test func fileAndDirectoryTransitionsRestoreBothWays() async throws {
        let repo = try await TempRepo.make(files: ["foo": "file\n", "dir/inner/bar.txt": "bar\n"])
        defer { repo.remove() }
        let fm = FileManager.default
        let session = SessionID(rawValue: "ses_fd")
        let ref = GitCheckpoints.ref(session: session, message: MessageID(rawValue: "msg_1"))
        let checkpoint = try #require(try await GitCheckpoints.capture(directory: repo.path, ref: ref, runner: repo.runner))
        // The agent's turn: `foo` becomes a directory, `dir` becomes a file.
        try fm.removeItem(atPath: repo.path + "/foo")
        try repo.write("foo/bar", "now a directory\n")
        try fm.removeItem(atPath: repo.path + "/dir")
        try repo.write("dir", "now a file\n")
        let undoRef = GitCheckpoints.ref(session: session, message: MessageID(rawValue: "undo-msg_1"))
        let plan = try await GitCheckpoints.planRestore(directory: repo.path, checkpoint: checkpoint, undoRef: undoRef, runner: repo.runner)
        #expect(Set(plan.paths) == ["foo", "foo/bar", "dir", "dir/inner/bar.txt"])
        let written = try await GitCheckpoints.apply(plan)
        #expect(try repo.read("foo") == "file\n")
        #expect(try repo.read("dir/inner/bar.txt") == "bar\n")
        #expect(try await repo.git("status", "--porcelain").isEmpty, "the tree matches the checkpoint exactly")
        try await GitCheckpoints.undo(written, directory: repo.path)
        #expect(try repo.read("foo/bar") == "now a directory\n")
        #expect(try repo.read("dir") == "now a file\n")
    }

    /// N17: a directory planned to become a file that gains a file meanwhile is not removed.
    @Test func aDirectoryThatGainsAFileIsNotRemoved() async throws {
        let repo = try await TempRepo.make(files: ["foo": "file\n"])
        defer { repo.remove() }
        let session = SessionID(rawValue: "ses_fd2")
        let ref = GitCheckpoints.ref(session: session, message: MessageID(rawValue: "msg_1"))
        let checkpoint = try #require(try await GitCheckpoints.capture(directory: repo.path, ref: ref, runner: repo.runner))
        try FileManager.default.removeItem(atPath: repo.path + "/foo")
        try repo.write("foo/bar", "agent\n")
        let undoRef = GitCheckpoints.ref(session: session, message: MessageID(rawValue: "undo-msg_1"))
        let plan = try await GitCheckpoints.planRestore(directory: repo.path, checkpoint: checkpoint, undoRef: undoRef, runner: repo.runner)
        let path = repo.path
        let racing = WorkingCopy(root: repo.path) { planned in
            if planned == "foo" { try? Data("user\n".utf8).write(to: URL(filePath: path + "/foo/new.txt")) }
        }
        #expect(throws: WorkingCopyError.changedOnDisk("foo")) { try racing.apply(plan.changes) }
        #expect(try repo.read("foo/new.txt") == "user\n")
        #expect(try repo.read("foo/bar") == "agent\n", "the deletion was rolled back")
    }
}

/// N17: opencode refuses the commit after the revert was staged: the revert is cleared and the files are put back.
@Suite("Rewind rollback", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct RewindRollbackTests {
    @Test func aRefusedCommitClearsTheStagedRevertAndPutsTheFilesBack() async throws {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let project = try #require(engine.root.projects.first)
        let session = try await engine.createThread(in: project.directory, title: "Rewind")

        let repo = try await TempRepo.make(files: ["a.txt": "one\n"])
        defer { repo.remove() }
        let ref = GitCheckpoints.ref(session: session.id, message: MessageID(rawValue: "msg_1"))
        let checkpoint = try #require(try await GitCheckpoints.capture(directory: repo.path, ref: ref, runner: repo.runner))
        try repo.write("a.txt", "agent\n")
        let undoRef = GitCheckpoints.ref(session: session.id, message: MessageID(rawValue: "undo-msg_1"))
        let files = try await GitCheckpoints.planRestore(directory: repo.path, checkpoint: checkpoint, undoRef: undoRef, runner: repo.runner)
        let plan = RewindPlan(sessionID: session.id, messageID: MessageID(rawValue: "msg_1"), directory: repo.path, files: files)

        await harness.server.injectHTTPFault(.status(500, method: "POST", pathPrefix: "/api/session/\(session.id.rawValue)/revert/commit"))
        await #expect(throws: (any Error).self) { _ = try await engine.rewind(plan) }
        #expect(await harness.server.stagedRevert(sessionID: session.id.rawValue) == nil, "the staged revert was cleared")
        #expect(try repo.read("a.txt") == "agent\n", "the files were put back")

        // When clearing fails too, the error says the revert is still staged.
        await harness.server.injectHTTPFault(.status(500, method: "POST", pathPrefix: "/api/session/\(session.id.rawValue)/revert/commit"))
        await harness.server.injectHTTPFault(.status(500, method: "DELETE", pathPrefix: "/api/session/\(session.id.rawValue)/revert"))
        let again = try await GitCheckpoints.planRestore(directory: repo.path, checkpoint: checkpoint, undoRef: undoRef, runner: repo.runner)
        do {
            _ = try await engine.rewind(RewindPlan(sessionID: session.id, messageID: MessageID(rawValue: "msg_1"), directory: repo.path, files: again))
            Issue.record("the rewind must fail")
        } catch let error as RewindRollbackError {
            #expect(error.revertStillStaged && error.filesNotRestored == nil)
        }
        #expect(try repo.read("a.txt") == "agent\n")
        await engine.stop()
    }
}
