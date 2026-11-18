import BelloCore
import ContainerKit
import Foundation
import Synchronization
import Testing

@testable import Engine

@Suite("Git parity: clone, publish, handoff, cleanup", .timeLimit(.minutes(3)))
@MainActor
struct GitProjectTests {
    final class Added: Sendable { let paths = Mutex<[String]>([]) }

    static func service(_ setup: GitCredentialTests.Setup, fake: FakeGitLabServer? = nil, added: Added) -> GitProjectService {
        let git = GitService(client: { throw GitError.launchFailed("no server") }, store: nil, runner: setup.runner)
        let vault = InMemorySecretVault()
        try? vault.store(account: setup.instance.baseURL, label: "t", value: SecretValue(GitCredentialTests.token))
        let provider = fake.map { GitLabProvider(transport: $0, tokens: vault) }
        return GitProjectService(git: git, provider: { provider }, addProject: { path in added.paths.withLock { $0.append(path) } })
    }

    /// Clone-while-typing: the clone starts at once, the composer's send waits on the job, and the project is added
    /// only when the files are in place.
    @Test func cloneRunsInTheBackgroundAndASendWaitsForIt() async throws {
        _ = try #require(HostGitIsolationTests.helper, "bellocode-exec is not built")
        let setup = try await GitCredentialTests.setup()
        defer { setup.cleanup() }
        try await GitRepository(directory: setup.repo.path, runner: setup.runner).push()
        let added = Added()
        let service = Self.service(setup, added: added)
        let destination = setup.repo.base.appending(path: "clones/group/project").path
        #expect(GitProjectService.defaultDestination(for: setup.remote, home: "/Users/x") == "/Users/x/BelloCode/127.0.0.1/group/project")
        let job = try service.clone(url: setup.remote, into: destination)
        #expect(job.state == .cloning)
        #expect(service.job(for: destination) === job)
        // The project is listed at once (the person can start typing).
        for _ in 0..<100 where added.paths.withLock(\.isEmpty) { await Task.yield() }
        #expect(added.paths.withLock { $0 } == [destination])
        // The person types and presses Send: the send waits here.
        let typed = "Explain the README"
        await job.waitUntilDone()
        #expect(job.state == .finished && !typed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: destination + "/README.md"))
        #expect(added.paths.withLock { $0 } == [destination])
        #expect(try GitCredentialTests.filesContaining(GitCredentialTests.token, under: destination).isEmpty)
        // A second clone into a non-empty folder is refused before anything starts.
        #expect(throws: GitError.self) { try service.clone(url: setup.remote, into: destination) }
    }

    @Test func aFailedCloneCanBeRetriedAndCancelledClonesLeaveNoFolder() async throws {
        _ = try #require(HostGitIsolationTests.helper, "bellocode-exec is not built")
        let setup = try await GitCredentialTests.setup()
        defer { setup.cleanup() }
        let added = Added()
        let service = Self.service(setup, added: added)
        let destination = setup.repo.base.appending(path: "clones/missing").path
        let job = try service.clone(url: setup.server.url + "/group/missing.git", into: destination)
        await job.waitUntilDone()
        guard case .failed = job.state else { Issue.record("expected failure, got \(job.state)"); return }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: destination)) ?? []).isEmpty)
        try setup.server.makeRepository("group/missing.git")
        _ = try await setup.runner.run(["push", "-q", setup.server.url + "/group/missing.git", "main"], in: setup.repo.path)
        let again = try service.retry(job)
        await again.waitUntilDone()
        #expect(again.state == .finished)
    }

    @Test func publishCreatesAPrivateProjectAddsOriginAndPushes() async throws {
        _ = try #require(HostGitIsolationTests.helper, "bellocode-exec is not built")
        let setup = try await GitCredentialTests.setup()
        defer { setup.cleanup() }
        try await setup.repo.git("remote", "remove", "origin")
        let fake = FakeGitLabServer(instance: setup.instance, token: GitCredentialTests.token)
        // GitLab creates the repository; the test server hosts it under the same path.
        try setup.server.makeRepository("me/pinball.git")
        let service = Self.service(setup, fake: fake, added: Added())
        let created = try await service.publish(directory: setup.repo.path, instance: setup.instance, name: "Pinball", path: "pinball", namespaceID: nil)
        #expect(created.path == "me/pinball" && created.httpURL == setup.server.url + "/me/pinball.git")
        let request = try #require(fake.requests.last { $0.method == "POST" })
        #expect(request.body?.contains("\"visibility\":\"private\"") == true)
        #expect(try await setup.repo.git("remote", "get-url", "origin").trimmingCharacters(in: .whitespacesAndNewlines) == created.httpURL)
        #expect(setup.server.recorded().contains { $0.authorized && $0.path.hasSuffix("git-receive-pack") })
        #expect(try await GitRepository(directory: setup.repo.path, runner: setup.runner).status().upstream == "origin/main")
        // Publishing again is refused (origin exists).
        await #expect(throws: GitError.self) { _ = try await service.publish(directory: setup.repo.path, instance: setup.instance, name: "P", path: "p", namespaceID: nil) }
        // Clone picker search goes through the same API.
        #expect(try await service.searchProjects(setup.instance, search: "pin").map(\.path) == ["me/pinball"])
    }

    @Test func handoffMovesUncommittedWorkIntoANewWorktree() async throws {
        let repo = try await TempRepo.make(files: ["a.txt": "one\n"])
        defer { repo.remove() }
        try repo.write("a.txt", "work in progress\n")
        try repo.write("new.txt", "untracked\n")
        let parent = repo.base.appending(path: "worktrees").path
        let service = WorktreeService(runner: repo.runner)
        let created = try await service.handoff(from: repo.path, branch: "bellocode/handoff", parent: parent)
        #expect(try String(contentsOfFile: created.directory + "/a.txt", encoding: .utf8) == "work in progress\n")
        #expect(try String(contentsOfFile: created.directory + "/new.txt", encoding: .utf8) == "untracked\n")
        #expect(try repo.read("a.txt") == "one\n" && !FileManager.default.fileExists(atPath: repo.path + "/new.txt"))
        #expect(try await repo.git("stash", "list").isEmpty)
        // A taken branch fails and leaves the source exactly as it was.
        try repo.write("a.txt", "second\n")
        await #expect(throws: (any Error).self) { _ = try await service.handoff(from: repo.path, branch: "bellocode/handoff", parent: parent) }
        #expect(try repo.read("a.txt") == "second\n")
        #expect(try await repo.git("stash", "list").isEmpty)
    }

    @Test func cleanupRemovesOnlyCleanPushedOrMergedWorktrees() async throws {
        let repo = try await TempRepo.make()
        defer { repo.remove() }
        let parent = repo.base.appending(path: "worktrees").path
        let service = WorktreeService(runner: repo.runner)
        let created = try await service.create(WorktreeCreation(projectDirectory: repo.path, branch: "bellocode/w", base: "main", parentDirectory: parent, copyOnWrite: false))
        func verdict(shared: Bool = false) async -> WorktreeCleanupVerdict {
            await service.cleanupVerdict(directory: created.directory, projectDirectory: repo.path, parent: parent, base: "main", sharedByOtherThreads: shared)
        }
        #expect(await verdict() == .remove)  // no commits beyond main: merged
        #expect(await verdict(shared: true) == .keep("another thread uses it"))
        try Data("x\n".utf8).write(to: URL(filePath: created.directory + "/x.txt"))
        guard case .keep(let reason) = await verdict() else { Issue.record("dirty worktree must be kept"); return }
        #expect(reason.contains("local files"))
        _ = try await repo.git("add", "-A", in: created.directory)
        _ = try await repo.git("commit", "-q", "-m", "work", in: created.directory)
        #expect(await verdict() == .keep("it has commits that are not pushed or merged"))
        try await repo.git("merge", "-q", "--ff-only", "bellocode/w")
        #expect(await verdict() == .remove)
        #expect(await service.cleanupVerdict(directory: repo.path, projectDirectory: repo.path, parent: parent, base: "main", sharedByOtherThreads: false)
            == .keep("not a BelloCode worktree"))
    }
}
