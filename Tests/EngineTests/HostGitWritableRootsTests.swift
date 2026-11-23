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
        process.standardInput = FileHandle.nullDevice
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
    /// AV03: a link named `.git` to another checkout's real `.git` directory is not that metadata's owner. git follows
    /// the link, but the sandbox does not let it write there: staging in the project leaves the other index unchanged.
    /// A link to another checkout's `.git` file (a linked worktree pointer) is refused the same way.
    @Test func aLinkNamedDotGitNeverReachesTheOtherCheckout() async throws {
        defer { remove() }
        let victim = try repository("victim")
        let index = try Data(contentsOf: URL(filePath: victim + "/.git/index"))
        let project = base + "/project"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: project + "/.git", withDestinationPath: victim + "/.git")
        try "planted\n".write(toFile: project + "/new.txt", atomically: true, encoding: .utf8)
        let roots = HostGit.writableRoots(directory: project, environment: [:], extra: [], mode: .local)
        #expect(!roots.contains { $0.hasPrefix(HostGit.canonical(victim)) }, "\(roots)")
        _ = try? await runner.run(["add", "new.txt"], in: project, allowFailure: true)
        _ = try? await runner.run(["update-ref", "refs/heads/pwned", "HEAD"], in: project, allowFailure: true)
        #expect(try Data(contentsOf: URL(filePath: victim + "/.git/index")) == index, "the other checkout's index is unchanged")
        #expect(!FileManager.default.fileExists(atPath: victim + "/.git/refs/heads/pwned"))
        // A link to another checkout's linked-worktree `.git` file.
        let victimWorktree = base + "/victim-wt"
        try plain(["worktree", "add", "-q", "-b", "vfeature", victimWorktree], in: victim)
        let other = base + "/other"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: other + "/.git", withDestinationPath: victimWorktree + "/.git")
        #expect(!HostGit.writableRoots(directory: other, environment: [:], extra: [], mode: .local).contains { $0.hasPrefix(HostGit.canonical(victim)) })
        // The checkout's own `.git` directory is still a root.
        #expect(HostGit.writableRoots(directory: victim, environment: [:], extra: [], mode: .local).contains(HostGit.canonical(victim + "/.git")))
    }
    /// AV03, the race: `.git` is a real directory when it is examined and is replaced by a link to another checkout's
    /// `.git` before the grant is derived. The grant comes from the folder that was opened, which is no longer
    /// `<project>/.git`, so nothing is granted; the other checkout's metadata never becomes a root. The same swap for a
    /// `.git` file, and a hard link to another checkout's worktree `.git` file, are refused too.
    @Test func aDotGitSwappedForALinkAfterInspectionNeverReachesTheOtherCheckout() throws {
        defer { remove() }
        let victim = try repository("victim")
        let project = try repository("project")
        let swap = {
            try? FileManager.default.moveItem(atPath: project + "/.git", toPath: project + "/.git-moved")
            try? FileManager.default.createSymbolicLink(atPath: project + "/.git", withDestinationPath: victim + "/.git")
        }
        let roots = HostGit.gitDirectories(from: project, afterOpening: swap)
        #expect(!roots.contains { $0.hasPrefix(HostGit.canonical(victim)) }, "\(roots)")
        #expect(roots.isEmpty, "the opened folder is no longer the checkout's .git: \(roots)")
        // Untouched, the checkout's own `.git` is granted (by the path of the opened folder).
        #expect(HostGit.gitDirectories(from: victim) == [HostGit.canonical(victim + "/.git")])

        // A linked worktree's `.git` file swapped for a link to the victim's worktree `.git` file.
        let victimWorktree = base + "/victim-wt"
        try plain(["worktree", "add", "-q", "-b", "vfeature", victimWorktree], in: victim)
        let own = try repository("own")
        let worktree = base + "/wt"
        try plain(["worktree", "add", "-q", "-b", "feature", worktree], in: own)
        #expect(HostGit.gitDirectories(from: worktree).contains(HostGit.canonical(own + "/.git")), "the untouched worktree keeps its metadata")
        let swapFile = {
            try? FileManager.default.removeItem(atPath: worktree + "/.git")
            try? FileManager.default.createSymbolicLink(atPath: worktree + "/.git", withDestinationPath: victimWorktree + "/.git")
        }
        let fileRoots = HostGit.gitDirectories(from: worktree, afterOpening: swapFile)
        #expect(!fileRoots.contains { $0.hasPrefix(HostGit.canonical(victim)) }, "\(fileRoots)")

        // A hard link to the victim worktree's `.git` file passes a back-reference check by identity: refused.
        let linked = base + "/hardlinked"
        try FileManager.default.createDirectory(atPath: linked, withIntermediateDirectories: true)
        #expect(link(victimWorktree + "/.git", linked + "/.git") == 0)
        #expect(!HostGit.gitDirectories(from: linked).contains { $0.hasPrefix(HostGit.canonical(victim)) })
        #expect(!HostGit.writableRoots(directory: linked, environment: [:], extra: [], mode: .local).contains { $0.hasPrefix(HostGit.canonical(victim)) })
    }
}
