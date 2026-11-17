import BelloCore
import Darwin
import Foundation
import OpenCodeKit
import Testing

@testable import Engine

/// M2-C checks against the pinned opencode binary: the VCS, worktree, per-turn diff and revert endpoints as
/// `GitService` and the Changes panel use them, on a throwaway repository. No model prompt. Skipped without
/// `Vendor/` (run `Scripts/fetch-opencode.sh`). HOME and XDG directories live under a fresh temporary directory; the
/// server is stopped (and checked gone) before the test returns.
@MainActor
@Suite("Git real binary", .serialized, .enabled(if: EngineRepo.vendoredOpencode != nil, "run Scripts/fetch-opencode.sh"), .timeLimit(.minutes(10)))
struct GitRealBinaryTests {
    /// `confined`: opencode's git goes through the `git` shim (HostGit sandbox), as in the app.
    @Test(arguments: [false, true]) func vcsWorktreeDiffAndRevertEndpoints(confined: Bool) async throws {
        let executable = try #require(EngineRepo.vendoredOpencode)
        let repo = try await TempRepo.make("project", files: ["f.txt": "a\nb\nc\n", "keep.txt": "k\n"])
        defer { repo.remove() }
        let dataRoot = repo.base.appending(path: "server", directoryHint: .isDirectory)
        var configuration = ServerConfiguration(executableURL: executable, dataRoot: dataRoot, expectedVersion: EngineRepo.pinnedVersion)
        if confined {
            let helper = try #require(HostGitIsolationTests.helper, "bellocode-exec is not built")
            configuration.containerExecution = ContainerExecution(
                helperURL: URL(filePath: helper), execConfigURL: dataRoot.appending(path: "missing.json"),
                gitShimDirectory: dataRoot.appending(path: "git-shim", directoryHint: .isDirectory))
        }
        let supervisor = ServerSupervisor(configuration: configuration)
        await supervisor.start()
        var endpoint = await supervisor.endpoint
        let deadline = ContinuousClock.now + .seconds(30)
        while endpoint == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            endpoint = await supervisor.endpoint
        }
        let ready = try #require(endpoint, "server did not become ready")
        let client = OpenCodeClient(endpoint: ready)
        defer {
            Task {
                let pid = await supervisor.childPID
                await supervisor.stop()
                if let pid { #expect(kill(pid, 0) != 0, "server child \(pid) still running") }
            }
        }

        // VCS: base, branches, status (untracked as "added"), working and branch diffs.
        try repo.write("f.txt", "a\nB\nc\n")
        try repo.write("new.txt", "n\n")
        _ = try await client.vcsInfo(directory: repo.path)  // the branch may be empty on the first call
        let info = try await client.vcsInfo(directory: repo.path)
        #expect(info.branch.current == "main" || info.branch.current == nil)
        #expect(try await client.vcsBase(directory: repo.path)?.name == "main")
        #expect(try await client.vcsBranches(directory: repo.path) == ["main"])
        let status = try await client.vcsStatus(directory: repo.path)
        #expect(Dictionary(uniqueKeysWithValues: status.map { ($0.file, $0.status) }) == ["f.txt": .modified, "new.txt": .added])
        let working = try await client.vcsDiff(directory: repo.path, mode: .working, context: 3)
        let patch = try #require(working.first { $0.file == "f.txt" })
        #expect(UnifiedPatchParser.parse(patch.patch).first?.hunks.first?.newLines == ["a", "B", "c"])
        try await repo.git("checkout", "-q", "-b", "feature")
        try await repo.git("add", "-A")
        try await repo.git("commit", "-q", "-m", "feature work")
        let branch = try await client.vcsDiff(directory: repo.path, mode: .branch, base: "main", context: 3)
        #expect(Set(branch.map(\.file)) == ["f.txt", "new.txt"])

        // Worktrees: one created with git is adopted after a refresh; a session there belongs to the project.
        let projectID = try await client.location(directory: repo.path).project.id
        let service = GitService(client: { client }, store: nil, runner: repo.runner)
        service.worktrees = WorktreeService.holding(in: repo)
        let created = try await service.createWorktree(
            WorktreeCreation(projectDirectory: repo.path, branch: "bellocode/real", base: "main", parentDirectory: repo.base.appending(path: "wt").path),
            projectID: ProjectID(projectID))
        let listed = try await client.worktrees(projectID: projectID).map { URL(filePath: $0.directory).resolvingSymlinksInPath().path }
        #expect(listed.contains(URL(filePath: created.directory).resolvingSymlinksInPath().path), "refresh adopted the git worktree")
        let session = try await client.createSession(SessionCreateRequest(directory: created.directory, title: "in worktree"))
        #expect(session.projectID == projectID)

        // opencode's own worktree API: detached HEAD, and removal of a dirty one needs force (WorktreeError).
        let theirs = try await client.createWorktree(WorktreeCreateRequest(projectID: projectID, name: "theirs"))
        try "dirty\n".write(toFile: theirs.directory + "/f.txt", atomically: true, encoding: .utf8)
        do {
            try await client.removeWorktree(projectID: projectID, directory: theirs.directory, force: false)
            Issue.record("a dirty worktree was removed without force")
        } catch let error as OpenCodeError {
            #expect(error.worktreeError?.forceRequired == true)
        }
        try await client.removeWorktree(projectID: projectID, directory: theirs.directory, force: true)

        // Per-turn diff and revert on a session without turns.
        #expect(try await client.sessionDiff(sessionID: session.id) == [])
        try await client.clearRevert(sessionID: session.id)
        do {
            _ = try await client.stageRevert(sessionID: session.id, messageID: "msg_doesnotexist", files: false)
            Issue.record("staging a revert at an unknown message succeeded")
        } catch let error as OpenCodeError {
            #expect(error.status == 404 || error.status == 400)
        }

        // Cleanup through the service: removed, branch kept, opencode's inventory refreshed.
        _ = try await service.removeWorktree(
            directory: created.directory, projectDirectory: repo.path, projectID: ProjectID(projectID), deleteBranch: false, force: true)
        let after = try await client.worktrees(projectID: projectID).map { URL(filePath: $0.directory).resolvingSymlinksInPath().path }
        #expect(!after.contains(URL(filePath: created.directory).resolvingSymlinksInPath().path))
        service.shutdown()
    }
}
