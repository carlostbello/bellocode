import BelloCore
import ContainerKit
import Foundation
import Synchronization
import Testing

@testable import Engine

/// C1 (docs/reviews/M3-M6-review.md): host git must never run a program a repository's configuration names. Every
/// vector in `HostileRepository` creates a marker if executed; every operation BelloCode runs on the host (and
/// opencode's, through the `git` shim) must leave the marker folder empty. A control run with unconfined git proves
/// the vectors are live.
@Suite("Host git isolation (hostile repositories)", .timeLimit(.minutes(3)))
struct HostGitIsolationTests {
    /// The production runner, plus the fixture's empty user configuration and identity.
    static func strictRunner(_ repository: HostileRepository) -> GitRunner { GitRunner(environment: repository.environment) }

    /// Local remotes allowed and the whole fixture writable: the most permissive configuration still runs no program.
    static func permissiveRunner(_ repository: HostileRepository) -> GitRunner {
        GitRunner(environment: repository.environment, writableRoots: [repository.base], allowsLocalRemotes: true)
    }

    /// `.build/<configuration>/bellocode-exec`, which `swift build`/`swift test` builds.
    static var helper: String? {
        var url = URL(filePath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let candidates = ["debug", "release"].flatMap { configuration in
            [".build/\(configuration)/bellocode-exec", ".build/arm64-apple-macosx/\(configuration)/bellocode-exec"]
        }
        return candidates.map { url.appending(path: $0).path }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Every host operation BelloCode performs, through its public API.
    /// Returns how many worktrees were created and removed (proves those paths ran, not just failed early).
    @discardableResult
    static func exerciseBelloCode(_ repository: HostileRepository, runner: GitRunner) async -> Int {
        var worktreeRoundTrips = 0
        let git = GitRepository(directory: repository.root, runner: runner)
        _ = try? await git.location()
        _ = try? await git.status()
        _ = try? await git.diff(.unstaged)
        _ = try? await git.diff(.staged)
        _ = try? await git.diff(.commit("HEAD"))
        _ = try? await git.diff(.workingTree(from: "HEAD"))
        _ = try? await git.diff(.range(from: "HEAD", to: "HEAD"))
        _ = try? await git.content(at: "HEAD", path: "README.md")
        _ = try? await git.content(at: "", path: "README.md")
        try? await git.stage(["README.md", "untracked.txt", "data.bin"])
        try? await git.unstage(["untracked.txt"])
        try? await git.stage(["untracked.txt"])
        _ = try? await git.commit(message: "hostile commit")
        _ = try? await git.branches()
        _ = try? await git.commits()
        _ = try? await git.worktrees()
        _ = try? await git.remoteURL()
        _ = try? await git.mergeBase("HEAD", "main")
        try? await git.push()
        _ = try? await runner.run(["fetch", "origin"], in: repository.root, timeout: .seconds(30), allowFailure: true)
        _ = try? await runner.run(["fetch", "sshremote"], in: repository.root, timeout: .seconds(30), allowFailure: true)
        _ = try? await runner.run(["fetch", "gitremote"], in: repository.root, timeout: .seconds(30), allowFailure: true)
        _ = try? await runner.run(["fetch", "extremote"], in: repository.root, timeout: .seconds(30), allowFailure: true)
        _ = try? await runner.run(["fetch", "https://example.invalid/x.git"], in: repository.root, timeout: .seconds(30), allowFailure: true)
        _ = try? await runner.run(["push", "sshremote", "main"], in: repository.root, timeout: .seconds(30), allowFailure: true)
        _ = try? await runner.run(
            ["credential", "fill"], in: repository.root, input: Data("protocol=https\nhost=example.invalid\n\n".utf8), timeout: .seconds(10),
            allowFailure: true)
        // Worktrees: create (normal checkout and copy-on-write), remove, restore.
        let service = WorktreeService(runner: runner, recycle: { url in url })
        for (index, copyOnWrite) in [false, true].enumerated() {
            let request = WorktreeCreation(
                projectDirectory: repository.root, branch: "hostile-\(index)", base: "main", parentDirectory: repository.base + "/worktrees",
                copyOnWrite: copyOnWrite)
            if let created = try? await service.create(request) {
                let worktree = GitRepository(directory: created.directory, runner: runner)
                _ = try? await worktree.status()
                _ = try? await worktree.diff(.unstaged)
                if let removed = try? await service.remove(directory: created.directory, projectDirectory: repository.root, deleteBranch: true, force: true) {
                    if (try? await service.restore(removed)) != nil { worktreeRoundTrips += 1 }
                }
            }
        }
        _ = try? await WorktreeService(runner: runner).create(
            WorktreeCreation(projectDirectory: repository.root, branch: "from-origin", base: "main", startFromOrigin: true, parentDirectory: repository.base + "/worktrees"))
        return worktreeRoundTrips
    }

    /// N31: building the fixture awaits each git process instead of blocking its thread. On a one-thread executor,
    /// another task runs while the build is still in progress (a blocking wait would hold the only thread to the end).
    @Test func buildingTheFixtureNeverBlocksItsThread() async throws {
        let executor = OneThreadExecutor()
        let state = Mutex((building: false, observed: false))
        let build = Task(executorPreference: executor) { () async throws -> HostileRepository in
            state.withLock { $0.building = true }
            defer { state.withLock { $0.building = false } }
            return try await HostileRepository.make()
        }
        let probe = Task(executorPreference: executor) {
            for _ in 0..<100_000 {
                if state.withLock({ $0.building }) {
                    state.withLock { $0.observed = true }
                    return
                }
                await Task.yield()
            }
        }
        await probe.value
        let repository = try await build.value
        repository.remove()
        #expect(state.withLock { $0.observed }, "the build held the executor's only thread until it finished")
    }

    @Test func belloCodesHostGitRunsNoRepositoryProgram() async throws {
        for strict in [true, false] {
            let repository = try await HostileRepository.make()
            defer { repository.remove() }
            let roundTrips = await Self.exerciseBelloCode(repository, runner: strict ? Self.strictRunner(repository) : Self.permissiveRunner(repository))
            #expect(roundTrips == 2, "worktree create/remove/restore did not complete under the sandbox")
            #expect(repository.fired.isEmpty, "\(strict ? "strict" : "permissive") runner executed: \(repository.fired)")
        }
    }

    /// Git parity: the same matrix with BelloCode's credential helper configured for the repository's remotes (an
    /// HTTPS GitLab remote is added, so every network operation runs with the helper allowed in the sandbox). Nothing
    /// a repository names may run, and the helper never answers (no grant matches an unreachable host).
    @Test func hostGitRunsNoRepositoryProgramWithTheCredentialHelperPresent() async throws {
        let helper = try #require(Self.helper, "bellocode-exec is not built")
        let repository = try await HostileRepository.make()
        defer { repository.remove() }
        try await repository.plain(["remote", "add", "gitlab", "https://gitlab.example.invalid/group/project.git"], in: repository.root)
        let vault = InMemorySecretVault()
        try vault.store(account: "https://gitlab.example.invalid", label: "t", value: SecretValue("glpat-never"))
        let broker = try GitCredentialBroker(tokens: vault)
        broker.setInstances([GitLabInstance(baseURL: "https://gitlab.example.invalid")!])
        for strict in [true, false] {
            var runner = strict ? Self.strictRunner(repository) : Self.permissiveRunner(repository)
            runner.credentials = GitCredentials(broker: broker, helperPath: helper)
            _ = await Self.exerciseBelloCode(repository, runner: runner)
            _ = try? await runner.run(["fetch", "gitlab"], in: repository.root, timeout: .seconds(30), allowFailure: true)
            _ = try? await runner.run(["push", "gitlab", "main"], in: repository.root, timeout: .seconds(30), allowFailure: true)
            #expect(repository.fired.isEmpty, "\(strict ? "strict" : "permissive") runner with the helper executed: \(repository.fired)")
        }
        #expect(broker.inspect { $0.grants.isEmpty })
    }

    @Test func belloCodesGitStillWorksInAHostileRepository() async throws {
        let repository = try await HostileRepository.make()
        defer { repository.remove() }
        let git = GitRepository(directory: repository.root, runner: Self.permissiveRunner(repository))
        let status = try await git.status()
        #expect(status.files.contains { $0.path == "README.md" })
        try await git.stage(["README.md"])
        let hash = try await git.commit(message: "works")
        #expect(!hash.isEmpty)
        #expect(repository.fired.isEmpty)
    }

    @Test func opencodesGitThroughTheShimRunsNoRepositoryProgram() async throws {
        let helper = try #require(Self.helper, "bellocode-exec is not built")
        let repository = try await HostileRepository.make()
        defer { repository.remove() }
        let shimDirectory = repository.base + "/shim"
        try FileManager.default.createDirectory(atPath: shimDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: shimDirectory + "/git", withDestinationPath: helper)
        // What opencode runs on the host (snapshots with its own git dir, diffs, status, revert, reset, worktrees, fetch).
        let snapshot = repository.base + "/snapshot.git"
        let commands: [[String]] = [
            ["rev-parse", "--git-dir", "--git-common-dir", "--show-toplevel"],
            ["status", "--porcelain=v1", "--untracked-files=all", "--no-renames", "-z", "--", "."],
            ["diff", "--no-ext-diff", "--no-renames", "--numstat", "-z"],
            ["diff", "--no-renames", "HEAD"],
            ["diff-files", "--name-only", "-z"],
            ["ls-files", "--others", "--exclude-standard", "-z"],
            ["log", "-1"],
            ["show", "HEAD"],
            ["add", "-A"],
            ["commit", "-q", "-m", "shim"],
            ["checkout", "HEAD", "--", "README.md"],
            ["reset", "--hard", "HEAD"],
            ["init", "-q", snapshot],
            ["--git-dir", snapshot, "--work-tree", repository.root, "add", "."],
            ["--git-dir", snapshot, "--work-tree", repository.root, "write-tree"],
            ["worktree", "add", "--detach", "--", repository.base + "/shim-worktree", "HEAD"],
            ["worktree", "list", "--porcelain"],
            ["worktree", "remove", "--force", repository.base + "/shim-worktree"],
            ["fetch", "--all", "--prune"],
            ["fetch", "extremote"],
            ["push", "origin", "main"],
        ]
        var environment = repository.environment
        environment["XDG_DATA_HOME"] = repository.base
        environment["GIT_EXTERNAL_DIFF"] = repository.script("diff-external")
        environment["GIT_SSH_COMMAND"] = repository.script("ssh-command")
        environment["GIT_PAGER"] = repository.script("pager")
        environment["PATH"] = shimDirectory + ":" + HostGit.fixedPath
        for arguments in commands {
            _ = try? await GitRunner(environment: environment).runProgram(
                URL(filePath: shimDirectory + "/git"), arguments, in: repository.root, environment: environment, timeout: .seconds(30))
        }
        #expect(repository.fired.isEmpty, "opencode's git executed: \(repository.fired)")
        // The shim really ran git: the commit landed.
        let log = try await GitRunner(environment: environment).runProgram(
            URL(filePath: shimDirectory + "/git"), ["log", "-1", "--format=%s"], in: repository.root, environment: environment, timeout: .seconds(30))
        #expect(String(decoding: log.stdout, as: UTF8.self).contains("shim"))
    }

    @Test func aRepositoryCannotRedirectWritesOutsideItself() async throws {
        let helper = try #require(Self.helper, "bellocode-exec is not built")
        let repository = try await HostileRepository.make()
        defer { repository.remove() }
        // Outside every writable root (not under TMPDIR): core.worktree points git's checkout there.
        let outside = "/private/tmp/bellocode-escape-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        let shim = repository.base + "/git"
        try FileManager.default.createSymbolicLink(atPath: shim, withDestinationPath: helper)
        try await repository.plain(["config", "core.worktree", outside], in: repository.root)
        for arguments in [["reset", "--hard", "HEAD"], ["checkout", "HEAD", "--", "."]] {
            _ = try? await GitRunner(environment: repository.environment).runProgram(
                URL(filePath: shim), arguments, in: repository.root, environment: repository.environment, timeout: .seconds(30))
        }
        _ = try? await Self.strictRunner(repository).run(["checkout", "HEAD", "--", "."], in: repository.root, allowFailure: true)
        #expect((try FileManager.default.contentsOfDirectory(atPath: outside)).isEmpty)
        // Control: unconfined git does write there.
        try await repository.plain(["checkout", "HEAD", "--", "README.md"], in: repository.root)
        #expect(FileManager.default.fileExists(atPath: outside + "/README.md"))
    }

    @Test func aSubmoduleConfigurationRunsNothing() async throws {
        let repository = try await HostileRepository.make()
        defer { repository.remove() }
        let sub = repository.root + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        try await repository.plain(["init", "-q", "-b", "main"], in: sub)
        try Data("s\n".utf8).write(to: URL(filePath: sub + "/s.txt"))
        try await repository.plain(["add", "-A"], in: sub)
        try await repository.plain(["commit", "-q", "-m", "sub"], in: sub)
        try await repository.plain(["config", "core.fsmonitor", repository.script("submodule-fsmonitor")], in: sub)
        try await repository.plain(["-c", "core.fsmonitor=false", "add", "sub"], in: repository.root)
        try Data("s2\n".utf8).write(to: URL(filePath: sub + "/s.txt"))
        // The fixture's own unconfined `add` above ran the hostile filters: start from an empty marker folder.
        for name in repository.fired { try FileManager.default.removeItem(atPath: repository.markers + "/" + name) }
        let git = GitRepository(directory: repository.root, runner: Self.strictRunner(repository))
        _ = try? await git.status()
        _ = try? await git.diff(.unstaged)
        #expect(repository.fired.isEmpty, "\(repository.fired)")
    }

    @Test func networkOperationsUseOnlyTheUsersOwnHelpers() throws {
        // Repository and URL-scoped helpers are reset; only system/global ones are added back.
        let local = Data("local\u{0}credential.helper\n!evil\u{0}global\u{0}credential.helper\nosxkeychain\u{0}unknown\u{0}core.sshcommand\nssh -i k\u{0}command\u{0}credential.helper\n!cmd\u{0}".utf8)
        let trusted = HostGit.parseTrusted(local)
        #expect(trusted.credentialHelpers == ["osxkeychain"])
        #expect(trusted.sshCommand == "ssh -i k")
        let invocation = try #require(HostGit.invocation(arguments: ["push"], directory: NSTemporaryDirectory(), mode: .network, environment: [:], trusted: trusted))
        let pairs = (0..<(Int(invocation.environment["GIT_CONFIG_COUNT"] ?? "0") ?? 0)).map {
            (invocation.environment["GIT_CONFIG_KEY_\($0)"] ?? "", invocation.environment["GIT_CONFIG_VALUE_\($0)"] ?? "")
        }
        let helpers = pairs.filter { $0.0 == "credential.helper" }.map(\.1)
        #expect(helpers == ["", "osxkeychain"])
        #expect(pairs.contains { $0 == ("protocol.allow", "never") })
        #expect(pairs.contains { $0 == ("core.fsmonitor", "false") })
        #expect(invocation.environment["SSH_AUTH_SOCK"] == nil)
        // Local operations: no helpers at all, no agent, no network in the profile.
        let localInvocation = try #require(HostGit.invocation(
            arguments: ["status"], directory: NSTemporaryDirectory(), mode: .local, environment: ["SSH_AUTH_SOCK": "/tmp/agent"], trusted: trusted))
        #expect(localInvocation.environment["SSH_AUTH_SOCK"] == nil)
        #expect(localInvocation.arguments[1].contains("(deny network*)"))
    }

    @Test func controlUnconfinedGitRunsTheVectors() async throws {
        // Proves the fixture is live: plain git (no sandbox, no overrides) executes repository programs.
        let repository = try await HostileRepository.make()
        defer { repository.remove() }
        let process = Process()
        process.standardInput = FileHandle.nullDevice
        process.executableURL = URL(filePath: HostGit.realGit() ?? "/usr/bin/git")
        process.arguments = ["add", "-A"]
        process.currentDirectoryURL = URL(filePath: repository.root)
        process.environment = ["HOME": repository.base, "PATH": HostGit.fixedPath, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(repository.fired.contains("fsmonitor") || repository.fired.contains("include-if"))
        #expect(repository.fired.contains("filter-clean"))
    }

    @Test func theSelfCheckProbeReportsConfined() async throws {
        let outcome = await HostGitProbe.run(shim: nil)
        guard case .confined = outcome else {
            Issue.record("host git probe: \(outcome.word) \(outcome.detail)")
            return
        }
    }
}

/// M3 (docs/reviews/M3-M6-review.md): a report is "Isolated" only when every applicable check ran and held.
@Suite("Isolation verdict")
struct IsolationVerdictTests {
    func report(_ outcomes: [IsolationReport.Outcome]) -> IsolationReport {
        IsolationReport(date: Date(), directory: "/p", full: true, checks: outcomes.enumerated().map { .init("check \($0.offset)", $0.element) })
    }

    @Test func skippedChecksAreNotVerifiedNeverIsolated() {
        let skipped = report([.confined("git"), .container("shell"), .skipped("no project")])
        #expect(skipped.verdict == .notVerified)
        #expect(!skipped.passed)
        #expect(skipped.summary.hasPrefix("Not verified"))
        // Only "off" and confined checks, nothing exercised in a container: not verified either.
        let nothingRan = report([.confined("git"), .off("formatters off")])
        #expect(nothingRan.verdict == .notVerified)
        // The server offline (the only other check): not verified.
        #expect(report([.confined("git"), .skipped("opencode is not running")]).verdict == .notVerified)
    }

    @Test func problemsWinAndAFullRunIsIsolated() {
        #expect(report([.container("shell"), .skipped("x"), .host("pty ran on this Mac")]).verdict == .problem)
        #expect(report([.container("shell"), .failed("no answer")]).verdict == .problem)
        let full = report([.confined("git"), .container("shell"), .container("pty"), .off("formatters off")])
        #expect(full.verdict == .isolated)
        #expect(full.passed)
        #expect(full.summary.hasPrefix("Isolated"))
    }
}

/// M6: a setup script's output keeps its beginning (where the first error usually is) and marks the cut.
@Suite
struct SetupOutputTests {
    @Test func headAndTailMarkTheCut() {
        let text = "fatal: npm ERR! first\n" + String(repeating: "progress line\n", count: 5_000) + "exit summary\n"
        let (kept, omitted) = WorktreeSetupResult.headAndTail(text, limit: 1_000)
        #expect(kept.hasPrefix("fatal: npm ERR! first"))
        #expect(kept.hasSuffix("exit summary\n"))
        #expect(omitted == text.utf8.count - 1_000)
        #expect(kept.contains("[… \(omitted) bytes of output omitted …]"))
        #expect(WorktreeSetupResult.headAndTail("short", limit: 1_000).omitted == 0)
    }
}

/// A task executor with exactly one thread (a serial queue).
final class OneThreadExecutor: TaskExecutor {
    let queue = DispatchQueue(label: "bellocode.tests.one-thread")

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}
