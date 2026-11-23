import BelloCore
import Foundation
import MockOpenCode
import Testing

@testable import Engine

/// AF19, AF20: a file restore is scoped and isolated by git working tree root, and its rollback and Undo act at that
/// root.
@Suite("Final check: rewind scope", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct FinalCheckRewindTests {
    func start() async throws -> (MockHarness, Engine) {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        return (harness, engine)
    }

    /// Waits until `session` is listed in its project's model (loaded as the sidebar loads it).
    func list(_ engine: Engine, _ session: Session) async throws {
        let project = await engine.project(session.projectID)
        try await waitUntil("\(session.id.rawValue) listed") { project.sessionIDs.contains(session.id) }
    }

    /// AF19: threads in sibling directories of one checkout share every checkpoint: the restore is refused when
    /// planned, and a plan made before the second thread appeared is refused when applied, with nothing written.
    @Test func aThreadInASiblingDirectoryBlocksAFileRestore() async throws {
        let (_, engine) = try await start()
        defer { Task { await engine.stop() } }
        let repo = try await TempRepo.make(files: ["a/f.txt": "one\n", "b/g.txt": "two\n"])
        defer { repo.remove() }
        let first = try await engine.createThread(in: repo.path + "/a", title: "A")
        try await list(engine, first)
        let message = MessageID(rawValue: "msg_1")
        _ = try #require(try await GitCheckpoints.capture(
            directory: repo.path + "/a", ref: GitCheckpoints.ref(session: first.id, message: message), runner: repo.runner))
        try repo.write("a/f.txt", "agent\n")
        try repo.write("b/g.txt", "second thread's edit\n")
        let early = try await engine.planRewind(first.id, to: message, directory: repo.path + "/a", revertFiles: true)
        #expect(early.files?.paths.sorted() == ["a/f.txt", "b/g.txt"], "\(early.filesUnavailable ?? "")")

        let second = try await engine.createThread(in: repo.path + "/b", title: "B")
        try await list(engine, second)
        await #expect(throws: GitError.self) { _ = try await engine.rewind(early) }
        #expect(try repo.read("b/g.txt") == "second thread's edit\n")
        #expect(try repo.read("a/f.txt") == "agent\n")
        let plan = try await engine.planRewind(first.id, to: message, directory: repo.path + "/a", revertFiles: true)
        #expect(plan.files == nil)
        #expect(plan.filesUnavailable?.contains("1 other thread") == true)
    }

    /// AF19 (second round): a delegated child is not a sidebar row of its own when its parent is listed, but it edits
    /// the same checkout. A child that already existed before the checkpoint refuses the parent's file restore (planned
    /// and applied), and the parent refuses the child's. A settled child created by the rewound turns themselves is part
    /// of what the rewind undoes and does not block it.
    @Test func aDelegatedChildBlocksItsParentsFileRestore() async throws {
        let (_, engine) = try await start()
        defer { Task { await engine.stop() } }
        let repo = try await TempRepo.make(files: ["a/f.txt": "one\n", "b/g.txt": "two\n"])
        defer { repo.remove() }
        let parent = try await engine.createThread(in: repo.path + "/a", title: "Parent")
        try await list(engine, parent)
        let message = MessageID(rawValue: "msg_1")
        // A turn of the parent: checkpoint first; it then delegates a child, which edits files and settles.
        var earlier = repo.runner
        earlier.environment["GIT_COMMITTER_DATE"] = "\(Int(Date().timeIntervalSince1970) - 60) +0000"
        _ = try #require(try await GitCheckpoints.capture(
            directory: repo.path + "/a", ref: GitCheckpoints.ref(session: parent.id, message: message), runner: earlier))
        let ownChild = try await engine.createThread(in: repo.path + "/a", title: "Delegated by the rewound turn", parent: parent.id)
        try repo.write("b/g.txt", "child's edit\n")
        let project = await engine.project(parent.projectID)
        try await waitUntil("child known") { project.row(ownChild.id) != nil }
        try await waitUntil("child settled") { project.row(ownChild.id)?.status?.status == .idle }
        #expect(!project.sessionIDs.contains(ownChild.id), "a child is not a top-level row")
        let allowed = try await engine.planRewind(parent.id, to: message, directory: repo.path + "/a", revertFiles: true)
        #expect(allowed.files?.paths == ["b/g.txt"], "\(allowed.filesUnavailable ?? "")")

        // A plan made before another thread's child appeared is refused when applied, with nothing written. That child's
        // parent is archived, so the child is not a sidebar row anywhere.
        let other = try await engine.createThread(in: repo.path + "/a", title: "Other")
        let otherChild = try await engine.createThread(in: repo.path + "/a", title: "Other's child", parent: other.id)
        try await engine.setArchived(other.id, true)
        try await waitUntil("other archived") { project.archivedSessionIDs.contains(other.id) && project.row(otherChild.id) != nil }
        #expect(!project.sessionIDs.contains(otherChild.id))
        await #expect(throws: GitError.self) { _ = try await engine.rewind(allowed) }
        #expect(try repo.read("b/g.txt") == "child's edit\n")

        // A child that existed before the checkpoint (delegated in an earlier turn, working on its own).
        let second = MessageID(rawValue: "msg_2")
        let independent = try await engine.createThread(in: repo.path + "/a", title: "Delegated earlier", parent: parent.id)
        try await waitUntil("independent known") { project.row(independent.id) != nil }
        _ = try #require(try await GitCheckpoints.capture(
            directory: repo.path + "/a", ref: GitCheckpoints.ref(session: parent.id, message: second), runner: repo.runner))
        try repo.write("b/g.txt", "independent child's edit\n")
        let refused = try await engine.planRewind(parent.id, to: second, directory: repo.path + "/a", revertFiles: true)
        #expect(refused.files == nil)
        #expect(refused.filesUnavailable?.contains("3 other threads") == true, "\(refused.filesUnavailable ?? "")")
        // The child's own restore is refused by its parent (and its sibling).
        _ = try #require(try await GitCheckpoints.capture(
            directory: repo.path + "/a", ref: GitCheckpoints.ref(session: independent.id, message: message), runner: repo.runner))
        let child = try await engine.planRewind(independent.id, to: message, directory: repo.path + "/a", revertFiles: true)
        #expect(child.files == nil && child.filesUnavailable?.contains("other thread") == true)
    }

    /// AF20: a session opened in a subdirectory restores worktree-relative paths at the root; a refused rewind puts
    /// them back there, and Undo returns the exact earlier bytes there.
    @Test func aSubdirectorySessionRollsBackAndUndoesAtTheRoot() async throws {
        let (harness, engine) = try await start()
        defer { Task { await engine.stop() } }
        let repo = try await TempRepo.make(files: ["sub/f.txt": "before\n"])
        defer { repo.remove() }
        let directory = repo.path + "/sub"
        let thread = try await engine.createThread(in: directory, title: "Sub")
        // A file at the worktree-relative path below the session directory, holding what the restore writes: resolving
        // paths against the session directory would change it instead of the restored file.
        try repo.write("sub/sub/f.txt", "before\n")
        let message = MessageID(rawValue: "msg_1")
        _ = try #require(try await GitCheckpoints.capture(
            directory: directory, ref: GitCheckpoints.ref(session: thread.id, message: message), runner: repo.runner))
        try repo.write("sub/f.txt", "agent\n")

        var plan = try await engine.planRewind(thread.id, to: message, directory: directory, revertFiles: true)
        #expect(plan.files.map { HostGitPaths.real($0.directory) } == HostGitPaths.real(repo.path))
        #expect(plan.files?.paths == ["sub/f.txt"])
        await harness.server.injectHTTPFault(.status(500, method: "POST", pathPrefix: "/api/session/\(thread.id.rawValue)/revert/commit"))
        do {
            _ = try await engine.rewind(plan)
            Issue.record("the rewind must fail")
        } catch let error as RewindRollbackError {
            Issue.record("the files must be put back: \(error)")
        } catch {}
        #expect(try repo.read("sub/f.txt") == "agent\n", "rolled back at the root")
        #expect(try repo.read("sub/sub/f.txt") == "before\n")

        plan = try await engine.planRewind(thread.id, to: message, directory: directory, revertFiles: true)
        let applied = try await engine.rewind(plan)
        #expect(HostGitPaths.real(applied.root) == HostGitPaths.real(repo.path))
        #expect(try repo.read("sub/f.txt") == "before\n")
        try await engine.undoRewindFiles(applied)
        #expect(try repo.read("sub/f.txt") == "agent\n", "Undo at the root")
        #expect(try repo.read("sub/sub/f.txt") == "before\n")
    }
}
