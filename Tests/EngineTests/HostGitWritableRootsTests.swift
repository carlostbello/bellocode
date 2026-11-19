import ContainerKit
import Foundation
import Testing

@testable import ContainerKit
@testable import Engine

/// R27 (docs/reviews/release-1.0-review.md): the host git sandbox may write only the repository's own metadata. A
/// linked-worktree or submodule pointer copied from another checkout must not extend it into that checkout's index and
/// refs. Repositories live under /private/tmp (outside TMPDIR, which is a writable root by itself).
@Suite("Host git writable roots", .timeLimit(.minutes(3)))
struct HostGitWritableRootsTests {
    let base: String

    init() throws {
        base = "/private/tmp/bellocode-r27-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(atPath: base) }

    /// Unconfined git for fixtures only (fixed identity, no user configuration).
    @discardableResult
    func plain(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(filePath: directory)
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": base, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                               "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.invalid", "GIT_COMMITTER_NAME": "T",
                               "GIT_COMMITTER_EMAIL": "t@example.invalid"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus != 0 { throw GitError.failed(command: arguments.first ?? "git", status: process.terminationStatus, message: output) }
        return output
    }

    func repository(_ name: String) throws -> String {
        let path = base + "/" + name
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try plain(["init", "-q", "-b", "main"], in: path)
        try "x\n".write(toFile: path + "/README.md", atomically: true, encoding: .utf8)
        try plain(["add", "-A"], in: path)
        try plain(["commit", "-q", "-m", "initial"], in: path)
        return path
    }

    /// The confined runner with no extra roots (and no TMPDIR root covering /private/tmp).
    var runner: GitRunner {
        var environment = TempRepo.testRunner.environment
        environment["TMPDIR"] = base + "/tmp"
        return GitRunner(environment: environment)
    }

    @Test func aLinkedWorktreeOfTheSameRepositoryStillWritesItsMetadata() async throws {
        defer { remove() }
        let main = try repository("main")
        let worktree = base + "/wt"
        try plain(["worktree", "add", "-q", "-b", "feature", worktree], in: main)
        let roots = HostGit.writableRoots(directory: worktree, environment: [:], extra: [], mode: .local)
        #expect(roots.contains(HostGit.canonical(main + "/.git")), "\(roots)")
        #expect(roots.contains(HostGit.canonical(main + "/.git/worktrees/wt")), "\(roots)")
        _ = try await runner.run(["commit", "-q", "--allow-empty", "-m", "in the worktree"], in: worktree)
        #expect(try plain(["log", "-1", "--format=%s", "feature"], in: main).contains("in the worktree"))
    }

    @Test func aCopiedWorktreePointerNeverReachesTheOtherCheckout() async throws {
        defer { remove() }
        let victim = try repository("victim")
        let victimWorktree = base + "/victim-wt"
        try plain(["worktree", "add", "-q", "-b", "vfeature", victimWorktree], in: victim)
        // The project: a folder whose `.git` file was copied from the victim's worktree (stale or planted).
        let project = base + "/project"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: victimWorktree + "/.git", toPath: project + "/.git")
        let roots = HostGit.writableRoots(directory: project, environment: [:], extra: [], mode: .local)
        #expect(!roots.contains { $0.hasPrefix(HostGit.canonical(victim)) }, "\(roots)")
        // git follows the pointer, but the sandbox refuses to write the victim's refs.
        _ = try? await runner.run(["update-ref", "refs/heads/pwned", "HEAD"], in: project, allowFailure: true)
        #expect(!FileManager.default.fileExists(atPath: victim + "/.git/refs/heads/pwned"))
        #expect(!(try plain(["branch", "--list", "pwned"], in: victim)).contains("pwned"))
    }

    @Test func aPlantedCommondirOrForeignSubmoduleDirIsNotWritable() throws {
        defer { remove() }
        let victim = try repository("victim")
        let project = try repository("project")
        // A `commondir` written into the project's own .git directory.
        try (victim + "/.git\n").write(toFile: project + "/.git/commondir", atomically: true, encoding: .utf8)
        let roots = HostGit.writableRoots(directory: project, environment: [:], extra: [], mode: .local)
        #expect(roots.contains(HostGit.canonical(project + "/.git")))
        #expect(!roots.contains(HostGit.canonical(victim + "/.git")), "\(roots)")
        // A submodule-style pointer into another superproject's modules.
        try FileManager.default.createDirectory(atPath: victim + "/.git/modules/lib", withIntermediateDirectories: true)
        let planted = base + "/planted"
        try FileManager.default.createDirectory(atPath: planted, withIntermediateDirectories: true)
        try "gitdir: \(victim)/.git/modules/lib\n".write(toFile: planted + "/.git", atomically: true, encoding: .utf8)
        #expect(!HostGit.writableRoots(directory: planted, environment: [:], extra: [], mode: .local).contains { $0.hasPrefix(HostGit.canonical(victim)) })
        // Its own superproject's modules folder is fine.
        try FileManager.default.createDirectory(atPath: project + "/.git/modules/lib", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: project + "/lib", withIntermediateDirectories: true)
        try "gitdir: ../.git/modules/lib\n".write(toFile: project + "/lib/.git", atomically: true, encoding: .utf8)
        #expect(HostGit.writableRoots(directory: project + "/lib", environment: [:], extra: [], mode: .local)
            .contains(HostGit.canonical(project + "/.git/modules/lib")))
    }
}
