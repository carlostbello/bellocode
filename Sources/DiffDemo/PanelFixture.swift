import AppKit
import BelloCore
import DiffKit
import Engine
import MockOpenCode
import OpenCodeKit

/// A throwaway git repository with the sample files, a mock opencode with one session whose turn changed them, and
/// a `GitService` for both. Removed with `stop()`.
@MainActor
final class PanelFixture {
    let root: URL
    let repo: URL
    let server: MockOpenCodeServer
    let client: OpenCodeClient
    let git: GitService
    let sessionID: SessionID
    let runner: GitRunner

    static func make() async throws -> PanelFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-diffdemo-\(UUID().uuidString)", directoryHint: .isDirectory)
        let repo = root.appending(path: "acme-app", directoryHint: .isDirectory).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        var environment = GitRunner.defaultEnvironment()
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        for key in ["GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME"] { environment[key] = "Demo" }
        for key in ["GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"] { environment[key] = "demo@example.invalid" }
        let runner = GitRunner(environment: environment, writableRoots: [FileManager.default.temporaryDirectory.path], allowsLocalRemotes: true)
        func git(_ arguments: String...) async throws { _ = try await runner.run(arguments, in: repo.path) }
        func write(_ path: String, _ text: String) throws {
            let url = repo.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try await git("init", "-q", "-b", "main")
        try write("Sources/Auth/LoginService.swift", Samples.loginOld)
        try write("web/src/config.ts", Samples.configOld)
        try write("Sources/Auth/LegacyLogin.swift", "// Deprecated.\nstruct LegacyLogin {}\n")
        try await git("add", "-A")
        try await git("commit", "-q", "-m", "Initial")
        try await git("checkout", "-q", "-b", "feature/login")
        // The agent's turn.
        try write("Sources/Auth/LoginService.swift", Samples.loginNew)
        try write("web/src/config.ts", Samples.configNew)
        try write("docs/LOGIN.md", "# Login\n\nPasswords are hashed with SHA-256 before comparison.\n")
        try FileManager.default.removeItem(at: repo.appending(path: "Sources/Auth/LegacyLogin.swift"))
        try await git("add", "web/src/config.ts")

        let server = MockOpenCodeServer(scenario: .empty(directory: repo.path), options: .testing)
        let endpoint = try await server.start()
        let client = OpenCodeClient(connection: ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? "")))
        let session = try await client.createSession(SessionCreateRequest(directory: repo.path, title: "Hash passwords"))
        func full(_ path: String, _ old: String?, _ new: String?) -> MockOpenCode.JSONValue {
            let hunks = LineDiff.hunks(old: LineDiff.lines(old ?? ""), new: LineDiff.lines(new ?? ""), context: 1_000_000)
            let patch = PatchFile(oldPath: old == nil ? nil : path, newPath: new == nil ? nil : path, hunks: hunks).render()
            return MockVCSRepository.fileDiff(path, status: old == nil ? "added" : new == nil ? "deleted" : "modified", patch: patch)
        }
        await server.setTurnDiff(
            sessionID: session.id,
            files: [
                full("Sources/Auth/LoginService.swift", Samples.loginOld, Samples.loginNew), full("web/src/config.ts", Samples.configOld, Samples.configNew),
                full("docs/LOGIN.md", nil, "# Login\n\nPasswords are hashed with SHA-256 before comparison.\n"),
            ])
        let git = GitService(client: { client }, store: nil, runner: runner)
        return PanelFixture(root: root, repo: repo, server: server, client: client, git: git, sessionID: SessionID(session.id), runner: runner)
    }

    init(root: URL, repo: URL, server: MockOpenCodeServer, client: OpenCodeClient, git: GitService, sessionID: SessionID, runner: GitRunner) {
        self.root = root
        self.repo = repo
        self.server = server
        self.client = client
        self.git = git
        self.sessionID = sessionID
        self.runner = runner
    }

    func model(scope: ChangesScope) -> ChangesModel {
        let model = ChangesModel(git: git, directory: repo.path, sessionID: sessionID, scope: scope)
        model.turns = { [ChangesTurn(id: "msg_1", title: "Hash passwords and lock after five failures", index: 0)] }
        return model
    }

    func stop() async {
        git.shutdown()
        await server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    /// Waits until a panel's model is loaded and its diff shows.
    static func settle(_ panel: ChangesPanelController) async {
        for _ in 0..<300 {
            if let model = panel.model, model.phase == .ready, model.repository.phase != .loading, !panel.diff.isBuilding { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await Snapshots.settle(panel.diff)
    }
}
