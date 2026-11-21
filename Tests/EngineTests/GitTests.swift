import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// A throwaway repository under the temporary directory. Git runs with no global or system config (the user's hooks,
/// signing and aliases never apply) and a fixed identity.
struct TempRepo {
    let root: URL
    let runner: GitRunner

    static let testRunner: GitRunner = {
        var environment = GitRunner.defaultEnvironment()
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_AUTHOR_NAME"] = "Test"
        environment["GIT_AUTHOR_EMAIL"] = "test@example.invalid"
        environment["GIT_COMMITTER_NAME"] = "Test"
        environment["GIT_COMMITTER_EMAIL"] = "test@example.invalid"
        return GitRunner(environment: environment, writableRoots: [FileManager.default.temporaryDirectory.path], allowsLocalRemotes: true)
    }()

    static func make(_ name: String = "repo", files: [String: String] = ["README.md": "hello\n"]) async throws -> TempRepo {
        let base = FileManager.default.temporaryDirectory.appending(path: "bellocode-git-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = base.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = TempRepo(root: root.resolvingSymlinksInPath(), runner: testRunner)
        try await repo.git("init", "-q", "-b", "main")
        for (path, text) in files { try repo.write(path, text) }
        try await repo.git("add", "-A")
        try await repo.git("commit", "-q", "-m", "initial")
        return repo
    }

    var path: String { root.path }
    var base: URL { root.deletingLastPathComponent() }

    @discardableResult
    func git(_ arguments: String..., in directory: String? = nil) async throws -> String {
        try await runner.run(arguments, in: directory ?? path).text
    }

    func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) throws -> String { try String(contentsOf: root.appending(path: path), encoding: .utf8) }

    var repository: GitRepository { GitRepository(directory: path, runner: runner) }

    func remove() { try? FileManager.default.removeItem(at: base) }
}

@Suite("Git status, patches and hunks", .timeLimit(.minutes(3)))
struct GitParsingTests {
    @Test func parsesPorcelainV2() {
        let sample = [
            "# branch.oid 1234567890abcdef", "# branch.head feature/x", "# branch.upstream origin/feature/x", "# branch.ab +2 -1",
            "1 M. N... 100644 100644 100644 aaa bbb staged.swift", "1 .M N... 100644 100644 100644 aaa bbb dir with space/unstaged.txt",
            "1 MM N... 100644 100644 100644 aaa bbb both.md", "2 R. N... 100644 100644 100644 aaa bbb R100 new name.txt", "old name.txt",
            "u UU N... 100644 100644 100644 100644 a b c conflict.c", "? untracked é.txt",
        ].joined(separator: "\0") + "\0"
        let status = GitStatusParser.parse(Data(sample.utf8))
        #expect(status.branch == "feature/x" && status.upstream == "origin/feature/x" && status.ahead == 2 && status.behind == 1)
        #expect(status.files.map(\.path) == ["staged.swift", "dir with space/unstaged.txt", "both.md", "new name.txt", "conflict.c", "untracked é.txt"])
        #expect(status.files[0].staged == .modified && status.files[0].unstaged == nil)
        #expect(status.files[1].staged == nil && status.files[1].unstaged == .modified)
        #expect(status.files[2].staged == .modified && status.files[2].unstaged == .modified)
        #expect(status.files[3].staged == .renamed && status.files[3].originalPath == "old name.txt")
        #expect(status.files[4].isConflicted)
        #expect(status.files[5].isUntracked)
        #expect(status.stagedFiles.count == 4 && status.unstagedFiles.count == 4)
        let detached = GitStatusParser.parse(Data("# branch.oid abc\0# branch.head (detached)\0".utf8))
        #expect(detached.isDetached)
        #expect(GitStatusParser.parse(Data("? a\0? b\0? c\0".utf8), limit: 2).truncated)
    }

    @Test func parsesNumstatWithRenamesAndBinaries() {
        let sample = "3\t1\ta.swift\0-\t-\timage.png\0" + "2\t0\t\0old.txt\0new.txt\0"
        let stats = GitStatusParser.parseNumstat(Data(sample.utf8))
        #expect(stats["a.swift"] == LineStats(additions: 3, deletions: 1))
        #expect(stats["image.png"]?.isBinary == true)
        #expect(stats["new.txt"] == LineStats(additions: 2, deletions: 0))
    }

    static let patch = """
        diff --git a/f.txt b/f.txt
        index 80e96c1..1cf4df5 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,4 +1,5 @@ func top()
         a
        -b
        +B
         c
         changed
        +done
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index 3e75765..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        \\ No newline at end of file
        diff --git a/img.png b/img.png
        Binary files a/img.png and b/img.png differ

        """

    @Test func parsesAndRendersUnifiedPatches() {
        let files = UnifiedPatchParser.parse(Self.patch)
        #expect(files.map(\.path) == ["f.txt", "gone.txt", "img.png"])
        #expect(files[0].hunks.count == 1 && files[0].hunks[0].section == "func top()")
        #expect(files[0].additions == 2 && files[0].deletions == 1)
        #expect(files[0].hunks[0].oldLines == ["a", "b", "c", "changed"])
        #expect(files[0].hunks[0].newLines == ["a", "B", "c", "changed", "done"])
        #expect(files[1].status == .deleted && files[1].hunks[0].lines[0].noNewlineAtEnd)
        #expect(files[2].isBinary && files[2].hunks.isEmpty)
        let reparsed = UnifiedPatchParser.parse(files[0].render())
        #expect(reparsed.first?.hunks == files[0].hunks)
    }

    @Test func revertsHunksAndRefusesStaleOnes() throws {
        let hunk = try #require(UnifiedPatchParser.parse(Self.patch).first?.hunks.first)
        let current = "a\nB\nc\nchanged\ndone\n"
        #expect(try HunkApplier.revert(hunk, in: current) == "a\nb\nc\nchanged\n")
        // Lines inserted above: the hunk is found at its new offset and the user's line is kept.
        let shifted = "user 1\nuser 2\na\nB\nc\nchanged\ndone\nuser tail\n"
        #expect(try HunkApplier.revert(hunk, in: shifted) == "user 1\nuser 2\na\nb\nc\nchanged\nuser tail\n")
        // A line inside the hunk changed since the diff: stale, nothing patched.
        #expect(throws: HunkApplyError.stale(hunkHeader: hunk.inverted.header)) { try HunkApplier.revert(hunk, in: "a\nB\nC-user\nchanged\ndone\n") }
        // The same block twice at equal distance: ambiguous.
        let shiftedHunk = PatchHunk(oldStart: 3, oldCount: 1, newStart: 3, newCount: 1, lines: [PatchLine(.removed, "x"), PatchLine(.added, "y")])
        #expect(throws: HunkApplyError.ambiguous(hunkHeader: shiftedHunk.inverted.header)) { try HunkApplier.revert(shiftedHunk, in: "y\nq\nz\nq\ny\n") }
        // No newline at end of file is kept.
        let eof = PatchHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, lines: [PatchLine(.removed, "old", noNewlineAtEnd: true), PatchLine(.added, "new", noNewlineAtEnd: true)])
        #expect(try HunkApplier.revert(eof, in: "new") == "old")
    }

    @Test func branchSlugs() {
        #expect(WorktreeService.slug("Fix the login bug!") == "bellocode/fix-the-login-bug")
        #expect(WorktreeService.slug("  Ünïcödé — résumé  ", prefix: "") == "unicode-resume")
        #expect(WorktreeService.slug("") == "bellocode/work")
        #expect(WorktreeService.slug(String(repeating: "word ", count: 40), prefix: "").count <= 48)
    }
}

@Suite("Git repositories and worktrees (throwaway repos)", .serialized, .timeLimit(.minutes(3)))
struct GitRepositoryTests {
    @Test func statusStageCommitAndDiffs() async throws {
        let repo = try await TempRepo.make(files: ["a.txt": "1\n2\n3\n", "b.txt": "b\n"])
        defer { repo.remove() }
        try repo.write("a.txt", "1\ntwo\n3\n")
        try repo.write("new.txt", "x\ny\n")
        try await repo.git("rm", "-q", "b.txt")
        var status = try await repo.repository.status()
        #expect(status.branch == "main" && status.upstream == nil)
        let byPath = Dictionary(uniqueKeysWithValues: status.files.map { ($0.path, $0) })
        #expect(byPath["a.txt"]?.unstaged == .modified && byPath["a.txt"]?.unstagedStats == LineStats(additions: 1, deletions: 1))
        #expect(byPath["b.txt"]?.staged == .deleted)
        #expect(byPath["new.txt"]?.isUntracked == true && byPath["new.txt"]?.unstagedStats?.additions == 2)

        let unstaged = UnifiedPatchParser.parse(try await repo.repository.diff(.unstaged))
        #expect(Set(unstaged.map(\.path)) == ["a.txt", "new.txt"])
        try await repo.repository.stage(["a.txt", "new.txt"])
        status = try await repo.repository.status()
        #expect(status.unstagedFiles.isEmpty && status.stagedFiles.count == 3)
        try await repo.repository.unstage(["new.txt"])
        #expect(try await repo.repository.status().files.first { $0.path == "new.txt" }?.isUntracked == true)
        let hash = try await repo.repository.commit(message: "Change a, remove b")
        #expect(hash.count == 40)
        let commits = try await repo.repository.commits()
        #expect(commits.first?.subject == "Change a, remove b" && commits.count == 2)
        let shown = UnifiedPatchParser.parse(try await repo.repository.diff(.commit(hash)))
        #expect(Set(shown.map(\.path)) == ["a.txt", "b.txt"])
        #expect(try await repo.repository.content(at: "HEAD~1", path: "b.txt") == Data("b\n".utf8))
        #expect(try await repo.repository.content(at: "HEAD", path: "b.txt") == nil)
    }

    @Test func pushPublishesToABareOrigin() async throws {
        let repo = try await TempRepo.make()
        defer { repo.remove() }
        let origin = repo.base.appending(path: "origin.git").path
        try await repo.git("init", "-q", "--bare", "-b", "main", origin)
        try await repo.git("remote", "add", "origin", origin)
        try await repo.git("checkout", "-q", "-b", "feature")
        try repo.write("f.txt", "f\n")
        try await repo.repository.stage(["f.txt"])
        try await repo.repository.commit(message: "f")
        try await repo.repository.push()
        let status = try await repo.repository.status()
        #expect(status.upstream == "origin/feature" && status.ahead == 0)
        let branches = try await repo.repository.branches()
        #expect(branches.contains { $0.isRemote && $0.name == "origin/feature" })
        #expect(branches.first { $0.name == "feature" }?.upstream == "origin/feature")
    }

    @Test func worktreeLifecycleWithCopyOnWriteAndUndo() async throws {
        var files: [String: String] = [:]
        for index in 0..<300 { files["src/dir\(index % 7)/file\(index).swift"] = "let value\(index) = \(index)\n" }
        files[".gitignore"] = "build/\n"
        let repo = try await TempRepo.make(files: files)
        defer { repo.remove() }
        try repo.write("src/dir0/file0.swift", "let value0 = -1 // local edit\n")
        var service = WorktreeService.holding(in: repo)
        let parent = repo.base.appending(path: "worktrees").path
        // S1: without a container runner a setup script is refused before anything is created (never run on the host).
        await #expect(throws: WorktreeError.setupNeedsContainer) {
            try await service.create(
                WorktreeCreation(projectDirectory: repo.path, branch: "bellocode/feature", base: "main", parentDirectory: parent, setupScript: "echo ready > setup.txt"))
        }
        #expect(!FileManager.default.fileExists(atPath: WorktreeService.folder(for: "bellocode/feature", in: parent)))
        await #expect(throws: WorktreeError.setupNeedsContainer) { try await service.runSetup("touch ran", in: repo.path, projectDirectory: repo.path) }
        #expect(!FileManager.default.fileExists(atPath: repo.path + "/ran"))
        // The container runner (here a stand-in that writes the file the script would) runs in the new worktree.
        service.setupRunner = { script, worktree, _ in
            try Data("ready\n".utf8).write(to: URL(filePath: worktree + "/setup.txt"))
            return WorktreeSetupResult(exitCode: script.contains("ready") ? 0 : 1, output: "", duration: .zero)
        }
        let created = try await service.create(
            WorktreeCreation(projectDirectory: repo.path, branch: "bellocode/feature", base: "main", parentDirectory: parent, setupScript: "echo ready > setup.txt"))
        #expect(created.clonedFiles == 300, "every clean file cloned (the dirty one checked out)")
        #expect(created.setup?.succeeded == true)
        let worktree = GitRepository(directory: created.directory, runner: repo.runner)
        let status = try await worktree.status()
        #expect(status.branch == "bellocode/feature")
        #expect(status.files.map(\.path) == ["setup.txt"], "a clean checkout apart from the setup script's file")
        #expect(try String(contentsOfFile: created.directory + "/src/dir0/file0.swift", encoding: .utf8) == "let value0 = 0\n")
        #expect(try await worktree.location()?.kind == .worktree)

        // Normal checkout when copy-on-write is off.
        let plain = try await service.create(
            WorktreeCreation(projectDirectory: repo.path, branch: "plain", base: "main", parentDirectory: parent, copyOnWrite: false))
        #expect(plain.clonedFiles == 0)
        #expect(try await GitRepository(directory: plain.directory, runner: repo.runner).status().files.isEmpty)
        await #expect(throws: WorktreeError.branchExists("plain")) {
            try await service.create(WorktreeCreation(projectDirectory: repo.path, branch: "plain", base: "main", parentDirectory: parent + "2"))
        }
        #expect(try await service.uniqueBranchName("plain", in: repo.path) == "plain-2")

        // Dirty worktree: refused without force; nothing touched.
        await #expect(throws: WorktreeError.filesAtRisk(WorktreeContents(uncommitted: 1, ignored: 0, examples: ["setup.txt"]))) {
            try await service.remove(directory: created.directory, projectDirectory: repo.path, deleteBranch: true, force: false)
        }
        #expect(FileManager.default.fileExists(atPath: created.directory))

        // Clean removal with branch deletion, then Undo brings both back.
        let removed = try await service.remove(directory: plain.directory, projectDirectory: repo.path, deleteBranch: true, force: false)
        #expect(!FileManager.default.fileExists(atPath: plain.directory))
        #expect(try await repo.repository.resolves("refs/heads/plain") == false)
        try await service.restore(removed)
        #expect(try await GitRepository(directory: plain.directory, runner: repo.runner).status().branch == "plain")

        let forced = try await service.remove(directory: created.directory, projectDirectory: repo.path, deleteBranch: false, force: true)
        #expect(forced.branch == "bellocode/feature" && !forced.branchDeleted)
        #expect(try await repo.repository.worktrees().count == 2)
    }

    @Test func startFromOriginFetchesTheBase() async throws {
        let repo = try await TempRepo.make()
        defer { repo.remove() }
        let origin = repo.base.appending(path: "origin.git").path
        try await repo.git("init", "-q", "--bare", "-b", "main", origin)
        try await repo.git("remote", "add", "origin", origin)
        try await repo.git("push", "-q", "origin", "main")
        // Someone else pushes a commit the local main does not have.
        let other = repo.base.appending(path: "other").path
        try await repo.git("clone", "-q", origin, other)
        try "upstream\n".write(toFile: other + "/up.txt", atomically: true, encoding: .utf8)
        try await repo.git("add", "up.txt", in: other)
        try await repo.git("commit", "-q", "-m", "up", in: other)
        try await repo.git("push", "-q", "origin", "main", in: other)
        let created = try await WorktreeService(runner: repo.runner).create(
            WorktreeCreation(projectDirectory: repo.path, branch: "from-origin", base: "main", startFromOrigin: true, parentDirectory: repo.base.appending(path: "wt").path))
        #expect(created.baseRef == "origin/main" && created.clonedFiles == 0)
        #expect(FileManager.default.fileExists(atPath: created.directory + "/up.txt"))
    }

    @Test func workingCopyRefusesConcurrentEditsAndUndoes() async throws {
        let repo = try await TempRepo.make(files: ["f.txt": "a\nB\nc\nchanged\ndone\n"])
        defer { repo.remove() }
        let hunk = try #require(UnifiedPatchParser.parse(GitParsingTests.patch).first?.hunks.first)
        let copy = WorkingCopy(root: repo.path)
        let plan = try copy.planHunkRevert(path: "f.txt", hunks: [hunk])
        try repo.write("f.txt", "a\nB\nc\nchanged\ndone\nuser line\n")
        #expect(throws: WorkingCopyError.changedOnDisk("f.txt")) { try copy.apply([plan]) }
        #expect(try repo.read("f.txt").hasSuffix("user line\n"), "nothing overwritten")
        let fresh = try copy.planHunkRevert(path: "f.txt", hunks: [hunk])
        let written = try copy.apply([fresh])
        #expect(try repo.read("f.txt") == "a\nb\nc\nchanged\nuser line\n")
        try copy.undo(written)
        #expect(try repo.read("f.txt") == "a\nB\nc\nchanged\ndone\nuser line\n")
    }

    /// A20: a child that ignores SIGTERM after its deadline is killed, and the run completes as timed out.
    @Test func runnerKillsAChildThatIgnoresTerminate() async throws {
        let runner = TempRepo.testRunner
        await #expect(throws: GitError.timedOut(command: "sh")) {
            try await runner.runProgram(URL(filePath: "/bin/sh"), ["-c", "trap '' TERM; while :; do /bin/sleep 0.2; done"], in: "/tmp", timeout: .milliseconds(200))
        }
        // Cancellation escalates the same way.
        let task = Task { try await runner.runProgram(URL(filePath: "/bin/sh"), ["-c", "trap '' TERM; while :; do /bin/sleep 0.2; done"], in: "/tmp", timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// A20: the child exits but a process it left behind keeps stdout open; the run completes with what the child
    /// wrote instead of waiting for that process.
    @Test func runnerCompletesWhenALeftoverProcessHoldsThePipe() async throws {
        let runner = TempRepo.testRunner
        let base = FileManager.default.temporaryDirectory.appending(path: "bellocode-pipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let pidFile = base.appending(path: "pid").path
        let output = try await runner.runProgram(
            URL(filePath: "/bin/sh"), ["-c", "/bin/sleep 600 & echo $! > '\(pidFile)'; echo done"], in: base.path, timeout: .seconds(60))
        #expect(output.status == 0 && output.text == "done\n")
        // Clean up the leftover we started (only it).
        if let pid = Int32((try? String(contentsOfFile: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
            kill(pid, SIGKILL)
        }
    }

    @Test func runnerCancelsTimesOutAndBoundsOutput() async throws {
        let runner = TempRepo.testRunner
        let task = Task { try await runner.runProgram(URL(filePath: "/bin/sleep"), ["20"], in: "/tmp", timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(3))
        await #expect(throws: GitError.timedOut(command: "sleep")) {
            try await runner.runProgram(URL(filePath: "/bin/sleep"), ["20"], in: "/tmp", timeout: .milliseconds(200))
        }
        await #expect(throws: GitError.outputTooLarge(command: "yes")) {
            try await runner.runProgram(URL(filePath: "/usr/bin/yes"), [], in: "/tmp", timeout: .seconds(10), outputLimit: 1 << 20)
        }
        await #expect(throws: GitError.notARepository("/")) { try await runner.run(["status"], in: "/") }
    }
}

@MainActor
@Suite("GitService and repository model", .serialized, .timeLimit(.minutes(3)))
struct GitServiceTests {
    @Test func modelRefreshesOnFileSystemChanges() async throws {
        let repo = try await TempRepo.make()
        defer { repo.remove() }
        let service = GitService(client: { throw CancellationError() }, store: nil, runner: repo.runner)
        let model = service.repository(for: repo.path)
        try await waitUntil { model.phase == .ready }
        #expect(model.status?.isDirty == false)
        #expect(model.workspaceKind == .mainCheckout)
        model.beginWatching()
        try await waitUntil { model.isWatching }
        let revision = model.revision
        try repo.write("edited.txt", "new\n")
        try await waitUntil(timeout: .seconds(5)) { model.revision > revision && model.status?.files.count == 1 }
        model.endWatching()
        #expect(!model.isWatching)
        model.loadBranches()
        try await waitUntil { model.branches.map(\.name) == ["main"] }
        service.shutdown()

        let plain = FileManager.default.temporaryDirectory.appending(path: "bellocode-plain-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: plain) }
        let other = GitService(client: { throw CancellationError() }, store: nil, runner: repo.runner).repository(for: plain)
        try await waitUntil { other.phase == .notRepository }
    }

    @Test func turnRevertDistinguishesAgentAndUserEdits() async throws {
        let repo = try await TempRepo.make(files: ["f.txt": "a\nb\nc\nchanged\n", "g.txt": "u1\nu2\nu3\nu4\ng1\ng2\n"])
        defer { repo.remove() }
        let harness = try await MockHarness.start(.empty(directory: repo.path))
        defer { Task { await harness.stop() } }
        let client = harness.client
        let session = try await client.createSession(SessionCreateRequest(directory: repo.path, title: "t"))
        // The agent's turn: f.txt b→B and +done; g.txt +g3. Full-file patches (no context) and 3-line patches.
        try repo.write("f.txt", "a\nB\nc\nchanged\ndone\n")
        try repo.write("g.txt", "u1\nu2\nu3\nu4\ng1\ng2\ng3\n")
        let fPatch = "diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -1,4 +1,5 @@\n a\n-b\n+B\n c\n changed\n+done\n"
        let gFull = "diff --git a/g.txt b/g.txt\n--- a/g.txt\n+++ b/g.txt\n@@ -1,6 +1,7 @@\n u1\n u2\n u3\n u4\n g1\n g2\n+g3\n"
        let gContext = "diff --git a/g.txt b/g.txt\n--- a/g.txt\n+++ b/g.txt\n@@ -4,3 +4,4 @@\n u4\n g1\n g2\n+g3\n"
        await harness.server.setTurnDiff(
            sessionID: session.id, from: "msg_turn",
            files: [MockVCSRepository.fileDiff("f.txt", patch: fPatch), MockVCSRepository.fileDiff("g.txt", patch: gFull)],
            withContext: [MockVCSRepository.fileDiff("f.txt", patch: fPatch), MockVCSRepository.fileDiff("g.txt", patch: gContext)])
        // The user edits g.txt after the turn, outside the turn's hunk.
        try repo.write("g.txt", "u1 (user)\nu2\nu3\nu4\ng1\ng2\ng3\n")

        let service = GitService(client: { client }, store: nil, runner: repo.runner)
        let plan = try await service.planTurnRevert(sessionID: SessionID(session.id), messageID: "msg_turn", directory: repo.path)
        #expect(plan.agentOnly == ["f.txt"])
        #expect(plan.editedSince == ["g.txt"])

        // Agent changes only: the user's line stays.
        let applied = try await service.revertTurnAgentChanges(plan)
        #expect(try repo.read("f.txt") == "a\nb\nc\nchanged\n")
        #expect(try repo.read("g.txt") == "u1 (user)\nu2\nu3\nu4\ng1\ng2\n")
        try await service.undoTurnRevert(applied)
        #expect(try repo.read("g.txt") == "u1 (user)\nu2\nu3\nu4\ng1\ng2\ng3\n")

        // A stale hunk (the user changed a line the turn touched) fails and writes nothing.
        try repo.write("f.txt", "a\nB (user)\nc\nchanged\ndone\n")
        let stalePlan = try await service.planTurnRevert(sessionID: SessionID(session.id), messageID: "msg_turn", directory: repo.path)
        await #expect(throws: WorkingCopyError.self) { try await service.revertTurnAgentChanges(stalePlan) }
        #expect(try repo.read("f.txt") == "a\nB (user)\nc\nchanged\ndone\n")
        #expect(try repo.read("g.txt") == "u1 (user)\nu2\nu3\nu4\ng1\ng2\ng3\n", "all or nothing")

        // The opencode snapshot route stages a revert; Undo clears it and restores the exact bytes.
        let snapshot = try await service.revertTurnWithSnapshot(stalePlan)
        #expect(await harness.server.stagedRevert(sessionID: session.id) != nil)
        try repo.write("g.txt", "server restored this\n")
        try await service.undoTurnRevert(snapshot)
        #expect(await harness.server.stagedRevert(sessionID: session.id) == nil)
        #expect(try repo.read("g.txt") == "u1 (user)\nu2\nu3\nu4\ng1\ng2\ng3\n")
    }
}
