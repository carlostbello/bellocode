import BelloCore
import Engine
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing
@testable import DiffKit

/// A throwaway repository plus a mock opencode with a session, for Changes panel tests.
@MainActor
struct ChangesFixture {
    let root: URL
    let repo: URL
    let server: MockOpenCodeServer
    let client: OpenCodeClient
    let git: GitService
    let sessionID: SessionID

    static func make(files: [String: String]) async throws -> ChangesFixture {
        let root = try TestGit.temporaryDirectory().resolvingSymlinksInPath()
        let repo = root.appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        var environment = TestGit.runner.environment
        for key in ["GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME"] { environment[key] = "Test" }
        for key in ["GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"] { environment[key] = "test@example.invalid" }
        let runner = GitRunner(environment: environment, writableRoots: [FileManager.default.temporaryDirectory.path], allowsLocalRemotes: true)
        _ = try await runner.run(["init", "-q", "-b", "main"], in: repo.path)
        for (path, text) in files { try write(repo, path, text) }
        _ = try await runner.run(["add", "-A"], in: repo.path)
        _ = try await runner.run(["commit", "-q", "-m", "initial"], in: repo.path)
        let server = MockOpenCodeServer(scenario: .empty(directory: repo.path), options: .testing)
        let endpoint = try await server.start()
        let client = OpenCodeClient(connection: ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? "")))
        let session = try await client.createSession(SessionCreateRequest(directory: repo.path, title: "t"))
        return ChangesFixture(root: root, repo: repo, server: server, client: client, git: GitService(client: { client }, store: nil, runner: runner), sessionID: SessionID(session.id))
    }

    static func write(_ repo: URL, _ path: String, _ text: String) throws {
        let url = repo.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func write(_ path: String, _ text: String) throws { try Self.write(repo, path, text) }
    func read(_ path: String) throws -> String { try String(contentsOf: repo.appending(path: path), encoding: .utf8) }

    func stop() async {
        git.shutdown()
        await server.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
func settled(_ model: ChangesModel) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while model.phase == .loading || model.phase == .idle {
        guard ContinuousClock.now < deadline else { Issue.record("model did not load"); return }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Suite("Changes model", .serialized, .timeLimit(.minutes(3)))
struct ChangesModelTests {
    @Test func turnScopeRebuildsFullTextsForExpansion() async throws {
        let fixture = try await ChangesFixture.make(files: ["a.swift": (1...30).map { "let v\($0) = \($0)" }.joined(separator: "\n") + "\n"])
        defer { Task { await fixture.stop() } }
        let old = (1...30).map { "let v\($0) = \($0)" }
        var new = old
        new[14] = "let v15 = 150"
        let hunks = LineDiff.hunks(old: old.map { Substring($0) }, new: new.map { Substring($0) }, context: 1_000)
        let patch = PatchFile(oldPath: "a.swift", newPath: "a.swift", hunks: hunks).render()
        await fixture.server.setTurnDiff(sessionID: fixture.sessionID.rawValue, files: [MockVCSRepository.fileDiff("a.swift", patch: patch)])
        let model = ChangesModel(git: fixture.git, directory: fixture.repo.path, sessionID: fixture.sessionID)
        model.load()
        try await settled(model)
        #expect(model.files.map(\.path) == ["a.swift"])
        let file = try #require(model.diffFiles.first)
        #expect(file.canExpandContext && file.hunks.count == 1 && file.hunks[0].oldStart == 12, "re-diffed with 3 lines of context")
        #expect(model.summary == "1 file · +1 −1")
    }

    @Test func uncommittedScopeStagesRevertsAndUndoes() async throws {
        let base = "a\nb\nc\nd\ne\nf\ng\nh\n1\n2\n3\n4\n5\n6\ni\nj\n"
        let fixture = try await ChangesFixture.make(files: ["f.txt": base, "g.txt": "keep\n"])
        defer { Task { await fixture.stop() } }
        let edited = "a\nB\nc\nd\ne\nf\ng\nh\n1\n2\n3\n4\n5\n6\nI\nj\n"
        try fixture.write("f.txt", edited)
        try fixture.write("new.txt", "fresh\n")
        let model = ChangesModel(git: fixture.git, directory: fixture.repo.path, sessionID: nil)
        #expect(model.scope == .uncommitted)
        var changes: [ReversibleChange] = []
        model.onReversibleChange = { changes.append($0) }
        model.load()
        try await settled(model)
        #expect(Set(model.files.map(\.path)) == ["f.txt", "new.txt"])
        #expect(model.files.first { $0.path == "new.txt" }?.statusLetter == "?")
        let file = try #require(model.diffFiles.first { $0.path == "f.txt" })
        #expect(file.hunks.count == 2 && file.canExpandContext)

        // Revert the second hunk only (I→i); the first stays.
        try await model.revertHunk(1, in: file)
        #expect(try fixture.read("f.txt") == edited.replacingOccurrences(of: "I\n", with: "i\n"))
        try #require(!changes.isEmpty)
        try await changes.last!.undo()
        #expect(try fixture.read("f.txt") == edited)

        // A stale hunk (the line changed since the diff was made) fails and changes nothing.
        try fixture.write("f.txt", edited.replacingOccurrences(of: "I\n", with: "I (user)\n"))
        await #expect(throws: WorkingCopyError.self) { try await model.revertHunk(1, in: file) }
        #expect(try fixture.read("f.txt").contains("I (user)"))

        // Stage, then Undo unstages.
        try await settled(model)
        await model.setStaged(["f.txt"], staged: true)
        try await settled(model)
        #expect(model.files.first { $0.path == "f.txt" }?.staged == .modified)
        try await changes.last!.undo()
        try await settled(model)
        #expect(model.files.first { $0.path == "f.txt" }?.staged == nil)

        // Discarding an untracked file deletes it; Undo brings it back.
        try await model.revertFile("new.txt")
        #expect(!FileManager.default.fileExists(atPath: fixture.repo.appending(path: "new.txt").path))
        try await changes.last!.undo()
        #expect(try fixture.read("new.txt") == "fresh\n")

        // Commit what is staged.
        await model.setStaged(["new.txt"], staged: true)
        try await settled(model)
        model.commitMessage = "Add new.txt"
        #expect(model.canCommit)
        #expect(await model.commit())
        try await settled(model)
        #expect(!model.files.contains { $0.path == "new.txt" })
    }

    @Test func workspaceDraftCreatesAWorktreeForTheFirstSend() async throws {
        let fixture = try await ChangesFixture.make(files: ["README.md": "hi\n"])
        defer { Task { await fixture.stop() } }
        var preferences = WorkspacePreferences()
        preferences.worktreeParent = fixture.root.appending(path: "worktrees").path
        preferences.setupScript = "touch .setup-ran"
        await fixture.git.setPreferences(preferences, projectDirectory: fixture.repo.path)
        let draft = WorkspaceDraft(git: fixture.git, projectDirectory: fixture.repo.path, projectID: nil)
        draft.load()
        let deadline = ContinuousClock.now + .seconds(5)
        while draft.preferences.worktreeParent == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(try await draft.prepare(prompt: "anything").directory == fixture.repo.path, "local mode uses the project")
        draft.mode = .newWorktree
        #expect(draft.branchLabel == "new branch from main")
        let prepared = try await draft.prepare(prompt: "Fix the login bug")
        #expect(prepared.created?.branch == "bellocode/fix-the-login-bug")
        #expect(prepared.directory.hasPrefix(fixture.root.path))
        #expect(FileManager.default.fileExists(atPath: prepared.directory + "/.setup-ran"))
        #expect(draft.worktrees.map(\.branch) == ["bellocode/fix-the-login-bug"])
        // The same prompt again gets a unique name.
        #expect(try await draft.prepare(prompt: "Fix the login bug").created?.branch == "bellocode/fix-the-login-bug-2")
        // Existing worktree mode uses that folder.
        draft.chooseWorktree(draft.worktrees[0])
        #expect(try await draft.prepare(prompt: "").directory == draft.worktrees[0].path)
    }

    @Test func fileTreeCompactsFolders() {
        func file(_ path: String) -> ChangedFile { ChangedFile(path: path, status: .modified, additions: 1, deletions: 0, isBinary: false) }
        let tree = FileTree.build([file("Sources/App/Auth/Login.swift"), file("Sources/App/Auth/Token.swift"), file("README.md"), file("Sources/Core/x.swift")])
        #expect(tree.map(\.name) == ["Sources", "README.md"])
        #expect(tree[0].children.map(\.name) == ["App/Auth", "Core"])
        #expect(tree[0].children[0].children.map(\.name) == ["Login.swift", "Token.swift"])
        #expect(tree[0].files.count == 3)
    }

    @Test func reviewCommentPromptText() {
        let comment = DiffReviewComment(path: "a.swift", side: .new, startLine: 3, endLine: 5, quoted: "let x = 1", text: "Use a constant.")
        #expect(comment.location == "a.swift:3–5")
        #expect(comment.promptText == "Review comment on a.swift:3–5 (new side):\n```\nlet x = 1\n```\nUse a constant.\n")
    }
}
