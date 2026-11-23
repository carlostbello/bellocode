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
        let (harness, engine) = try await start()
        defer { Task { await engine.stop() } }
        let repo = try await TempRepo.make(files: ["a/f.txt": "one\n", "b/g.txt": "two\n"])
        defer { repo.remove() }
        let parent = try await engine.createThread(in: repo.path + "/a", title: "Parent")
        try await list(engine, parent)
        // A turn of the parent: checkpoint first; it then delegates a child (on the server), which edits files and settles.
        await harness.server.enqueueScript(TurnScript(steps: [
            .subagent(agent: "explore", description: "Edit", prompt: "Edit the file") { TurnStep.text("Edited.") },
        ]), for: parent.id.rawValue)
        let message = try await engine.send("go", to: parent.id)
        await harness.server.waitUntilAllIdle()
        _ = try #require(try await GitCheckpoints.capture(
            directory: repo.path + "/a", ref: GitCheckpoints.ref(session: parent.id, message: message), runner: repo.runner))
        let ownChild = try #require(await engine.threadsSharingWorktree(of: repo.path + "/a", except: parent.id).first { $0.parentID == parent.id })
        try repo.write("b/g.txt", "child's edit\n")
        let project = await engine.project(parent.projectID)
        try await waitUntil("child known") { project.row(ownChild.id) != nil }
        try await waitUntil("child settled") { [.idle, .finishedUnread].contains(project.row(ownChild.id)?.status?.status) }
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
            directory: repo.path + "/a", ref: GitCheckpoints.ref(session: independent.id, message: second), runner: repo.runner))
        let child = try await engine.planRewind(independent.id, to: second, directory: repo.path + "/a", revertFiles: true)
        #expect(child.files == nil && child.filesUnavailable?.contains("other thread") == true)
    }

    /// AF19 (third round): whether a child was created by the rewound turns is read from the server's own record (the
    /// first assistant message after the rewound user message), never from a git timestamp mapped through an estimated
    /// clock offset. Here the checkpoint is stamped an hour early (a lagging clock, a delayed event): a settled child
    /// delegated before the turn still blocks the restore, at plan and at apply. The child the turn itself delegated
    /// (on the server, during the turn) does not, once the older one is out of the way. With no history to read,
    /// nothing is exempt.
    @Test func aChildFromAnEarlierTurnBlocksHoweverTheCheckpointIsStamped() async throws {
        let (harness, engine) = try await start()
        defer { Task { await engine.stop() } }
        let repo = try await TempRepo.make(files: ["a/f.txt": "one\n", "b/g.txt": "two\n"])
        defer { repo.remove() }
        let parent = try await engine.createThread(in: repo.path + "/a", title: "Parent")
        try await list(engine, parent)
        let project = await engine.project(parent.projectID)
        let older = try await engine.createThread(in: repo.path + "/a", title: "Delegated by an earlier turn", parent: parent.id)
        try await waitUntil("older settled") { project.row(older.id)?.status?.status == .idle }

        await harness.server.enqueueScript(TurnScript(steps: [
            .text("Delegating."),
            .subagent(agent: "explore", description: "Edit", prompt: "Edit the file") { TurnStep.text("Edited.") },
        ]), for: parent.id.rawValue)
        let message = try await engine.send("go", to: parent.id)
        await harness.server.waitUntilAllIdle()
        var early = repo.runner
        early.environment["GIT_COMMITTER_DATE"] = "\(Int(Date().timeIntervalSince1970) - 3600) +0000"
        _ = try #require(try await GitCheckpoints.capture(
            directory: repo.path + "/a", ref: GitCheckpoints.ref(session: parent.id, message: message), runner: early))
        try repo.write("b/g.txt", "the turn's child edited this\n")
        let own = try #require(await engine.threadsSharingWorktree(of: repo.path + "/a", except: parent.id)
            .first { $0.parentID == parent.id && $0.id != older.id }, "the turn delegated a child on the server")
        try await waitUntil("own child settled") { [.idle, .finishedUnread].contains(project.row(own.id)?.status?.status) }
        let cutoff = try #require(await engine.rewoundTurnsStart(parent.id, from: message))
        let olderCreated = try #require(project.row(older.id)?.session.created)
        #expect(olderCreated < cutoff && own.created > cutoff, "the server's order separates the two children")

        let refused = try await engine.planRewind(parent.id, to: message, directory: repo.path + "/a", revertFiles: true)
        #expect(refused.files == nil)
        #expect(refused.filesUnavailable?.contains("1 other thread") == true, "\(refused.filesUnavailable ?? "")")

        // Without the older child the turn's own child is part of what is rewound; a plan made then is still refused at
        // apply if the older child comes back meanwhile.
        try await engine.setArchived(older.id, true)
        try await waitUntil("older archived") { project.row(older.id)?.session.isArchived == true }
        let allowed = try await engine.planRewind(parent.id, to: message, directory: repo.path + "/a", revertFiles: true)
        #expect(allowed.files?.paths == ["b/g.txt"], "\(allowed.filesUnavailable ?? "")")
        try await engine.setArchived(older.id, false)
        try await waitUntil("older restored") { project.row(older.id)?.session.isArchived == false }
        await #expect(throws: GitError.self) { _ = try await engine.rewind(allowed) }
        #expect(try repo.read("b/g.txt") == "the turn's child edited this\n")

        // A message the server does not list: nothing to order by, so no child is exempt.
        #expect(await engine.rewoundTurnsStart(parent.id, from: MessageID(rawValue: "msg_unknown")) == nil)
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
