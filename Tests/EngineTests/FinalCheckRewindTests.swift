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
