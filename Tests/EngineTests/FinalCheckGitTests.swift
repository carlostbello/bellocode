import BelloCore
import Foundation
import Testing

@testable import Engine

/// v1.0.1 final-check findings on git (docs/reviews/v1.0.1-*-final-check.md): commit-message context stays inside the
/// checkout (AF01), Restore Stashed Changes keeps the staged version (AF05), and a push sends exactly what was
/// approved or confirmed (AF06, AF21).
@Suite("Final check: git", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct FinalCheckGitTests {
    /// AF01: an untracked link to a file outside the checkout is quoted as its link text (what git commits), never as
    /// the outside file's contents; a link in an ancestor is not followed either; a large file is not quoted.
    @Test func commitContextNeverReadsThroughALink() async throws {
        let repo = try await TempRepo.make(files: ["README.md": "hello\n"])
        defer { repo.remove() }
        let outside = repo.base.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("OUTSIDE-SECRET-MARKER\n".utf8).write(to: outside.appending(path: "private.conf"))
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/local.conf", withDestinationPath: outside.appending(path: "private.conf").path)
        try repo.write("notes.txt", "INSIDE-MARKER\n")
        try repo.write("big.txt", String(repeating: "x", count: 70 << 10) + "BIG-MARKER")
        let context = try await repo.repository.commitContext()
        #expect(context.stat.contains("local.conf"))
        #expect(!context.patch.contains("OUTSIDE-SECRET-MARKER"))
        #expect(context.patch.contains("(symbolic link to \(outside.appending(path: "private.conf").path))"))
        #expect(context.patch.contains("INSIDE-MARKER"), "a small regular file is still quoted")
        #expect(!context.patch.contains("BIG-MARKER"))
        // An ancestor that is a link is refused, not followed (git lists no path through a link, but the read must
        // not depend on that).
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/linked", withDestinationPath: outside.path)
        #expect(GitRepository.untrackedExcerpt("linked/private.conf", in: repo.path) == nil)
        #expect(GitRepository.untrackedExcerpt("notes.txt", in: repo.path) == "INSIDE-MARKER\n")
    }

    /// AF05: committed, staged and unstaged versions of one file survive Stash and Switch, then Restore Stashed
    /// Changes: the index holds the staged version again and the working file the unstaged one.
    @Test func restoreStashedChangesKeepsTheStagedVersion() async throws {
        let repo = try await TempRepo.make(files: ["a.txt": "committed\n"])
        defer { repo.remove() }
        let service = GitService(client: { throw CancellationError() }, store: nil, runner: repo.runner)
        let model = service.repository(for: repo.path)
        try await waitUntil { model.phase == .ready }
        try repo.write("a.txt", "staged\n")
        try await repo.git("add", "a.txt")
        try repo.write("a.txt", "unstaged\n")
        let hash = try #require(try await model.stashAndSwitch(to: "other", create: true))
        model.parkStash(hash, for: "main")
        try await model.switchBranch("main", create: false)
        try await model.restoreStash(hash)
        #expect(try await repo.git("show", ":a.txt") == "staged\n", "the staged version is back in the index")
        #expect(try repo.read("a.txt") == "unstaged\n")
        #expect(model.parkedStashes.isEmpty)
        #expect(try await repo.git("stash", "list").isEmpty, "dropped only after the verified restore")
        #expect(try await repo.git("for-each-ref", "refs/bellocode/recovery/").isEmpty)
    }

    /// AF05: a restore that cannot be completed keeps the stash parked and in the list, with a recovery ref, and says
    /// how to recover (StashRecoveryError, never a transient "failed").
    @Test func aFailedRestoreKeepsTheStashParkedWithRecovery() async throws {
        let repo = try await TempRepo.make(files: ["a.txt": "one\n"])
        defer { repo.remove() }
        let service = GitService(client: { throw CancellationError() }, store: nil, runner: repo.runner)
        let model = service.repository(for: repo.path)
        try await waitUntil { model.phase == .ready }
        try repo.write("a.txt", "parked work\n")
        try repo.write("new.txt", "untracked\n")
        let hash = try #require(try await model.stashAndSwitch(to: "other", create: true))
        model.parkStash(hash, for: "main")
        try await model.switchBranch("main", create: false)
        try repo.write("new.txt", "in the way\n")
        do {
            try await model.restoreStash(hash)
            Issue.record("the restore must fail")
        } catch let recovery as StashRecoveryError {
            #expect(recovery.stash == hash && recovery.unresolved == ["new.txt"])
            #expect(try await repo.git("rev-parse", recovery.ref).trimmingCharacters(in: .whitespacesAndNewlines) == hash)
        }
        #expect(model.parkedStashes["main"] == hash)
        #expect(try await repo.git("stash", "list", "--format=%H").contains(hash))
        try FileManager.default.removeItem(atPath: repo.path + "/new.txt")
        try await model.restoreStash(hash)
        #expect(try repo.read("a.txt") == "parked work\n" && repo.read("new.txt") == "untracked\n")
        #expect(try await repo.git("for-each-ref", "refs/bellocode/recovery/").isEmpty, "the recovery ref goes with the stash")
    }

    /// Two bare repositories: `origin` points at the first.
    func remotes(_ repo: TempRepo) async throws -> (first: String, second: String) {
        let first = repo.base.appending(path: "first.git").path
        let second = repo.base.appending(path: "second.git").path
        try await repo.git("init", "-q", "--bare", "-b", "main", first, in: repo.base.path)
        try await repo.git("init", "-q", "--bare", "-b", "main", second, in: repo.base.path)
        try await repo.git("remote", "add", "origin", first)
        try await repo.git("push", "-q", "-u", "origin", "main")
        return (first, second)
    }

    /// AF06: a remote repointed after the plan (the agent's card, or the person's confirmation) invalidates it: nothing
    /// reaches either repository. A plan read afterwards pushes to the destination it shows.
    @Test func aPushGoesOnlyToTheApprovedDestination() async throws {
        let repo = try await TempRepo.make(files: ["a.txt": "one\n"])
        defer { repo.remove() }
        let (first, second) = try await remotes(repo)
        try await repo.git("switch", "-q", "-c", "feature")
        try repo.write("b.txt", "b\n")
        try await repo.repository.commitAll(message: "b")
        let plan = try #require(try await repo.repository.pushPlan())
        #expect(plan.remoteURL == first)
        try await repo.git("remote", "set-url", "origin", second)
        await #expect(throws: GitPushPlanError.destinationChanged) { try await repo.repository.push(plan, force: false) }
        #expect(try await repo.git("--git-dir=" + first, "branch", "--list", "feature", in: repo.base.path).isEmpty)
        #expect(try await repo.git("--git-dir=" + second, "branch", "--list", "feature", in: repo.base.path).isEmpty)
        // A new HEAD after the plan invalidates it too.
        let fresh = try #require(try await repo.repository.pushPlan())
        try repo.write("c.txt", "c\n")
        try await repo.repository.commitAll(message: "c")
        await #expect(throws: GitPushPlanError.branchChanged) { try await repo.repository.push(fresh, force: false) }
        // The plan read now sends its own commit to its own destination, and records the upstream.
        let current = try #require(try await repo.repository.pushPlan())
        try await repo.repository.push(current, force: false)
        #expect(try await repo.git("--git-dir=" + second, "rev-parse", "feature", in: repo.base.path).trimmingCharacters(in: .whitespacesAndNewlines) == current.localHead)
        #expect(try await repo.git("rev-parse", "origin/feature").trimmingCharacters(in: .whitespacesAndNewlines) == current.localHead)
        #expect(try await repo.repository.status(limit: 1).upstream == "origin/feature")
        // Several push URLs: one push would reach all of them, more than a plan shows.
        try await repo.git("remote", "set-url", "--add", "--push", "origin", first)
        try await repo.git("remote", "set-url", "--add", "--push", "origin", second)
        await #expect(throws: GitPushPlanError.severalPushURLs("origin")) { _ = try await repo.repository.pushPlan() }
    }

    /// AF06 (second round): the URL a plan shows is already rewritten by `url.<base>.insteadOf`; handing it back to git
    /// as a repository argument would rewrite it again. With a rule matching the rewritten URL, the push must still
    /// reach the approved repository and nothing else.
    @Test func aPushIsNotRewrittenASecondTime() async throws {
        let repo = try await TempRepo.make(files: ["a.txt": "one\n"])
        defer { repo.remove() }
        let (first, second) = try await remotes(repo)
        try await repo.git("remote", "set-url", "origin", "approved-alias:")
        try await repo.git("config", "url.\(first).insteadOf", "approved-alias:")
        try await repo.git("config", "url.\(second).insteadOf", first)
        try await repo.git("switch", "-q", "-c", "feature")
        try repo.write("b.txt", "b\n")
        try await repo.repository.commitAll(message: "b")
        let plan = try #require(try await repo.repository.pushPlan())
        #expect(plan.remoteURL == first, "the card shows the first repository")
        try await repo.repository.push(plan, force: false)
        #expect(try await repo.git("--git-dir=" + first, "rev-parse", "feature", in: repo.base.path).trimmingCharacters(in: .whitespacesAndNewlines) == plan.localHead)
        #expect(try await repo.git("--git-dir=" + second, "branch", "--list", "feature", in: repo.base.path).isEmpty, "never the second")
    }

    /// GV10: the approved push goes to the remote by name, so settings scoped to that name apply as in a terminal
    /// (here `remote.origin.receivepack`, which a push to a bare URL ignores).
    @Test func aPushHonoursSettingsScopedToTheRemoteName() async throws {
        let repo = try await TempRepo.make(files: ["a.txt": "one\n"])
        defer { repo.remove() }
        let (first, _) = try await remotes(repo)
        try await repo.git("switch", "-q", "-c", "feature")
        try repo.write("b.txt", "b\n")
        try await repo.repository.commitAll(message: "b")
        try await repo.git("config", "remote.origin.receivepack", "git-receive-pack-that-does-not-exist")
        let plan = try #require(try await repo.repository.pushPlan())
        await #expect(throws: GitError.self) { try await repo.repository.push(plan, force: false) }
        try await repo.git("config", "--unset", "remote.origin.receivepack")
        try await repo.repository.push(plan, force: false)
        #expect(try await repo.git("--git-dir=" + first, "rev-parse", "feature", in: repo.base.path).trimmingCharacters(in: .whitespacesAndNewlines) == plan.localHead)
    }

    /// AV08: an approved branch push publishes that branch only, even with `push.followTags` on and an annotated tag
    /// on the outgoing commit (a tag the card never showed, which could start a release pipeline).
    @Test func anApprovedPushPublishesNoTags() async throws {
        let repo = try await TempRepo.make(files: ["a.txt": "one\n"])
        defer { repo.remove() }
        let (first, _) = try await remotes(repo)
        try await repo.git("config", "push.followTags", "true")
        try await repo.git("switch", "-q", "-c", "feature")
        try repo.write("b.txt", "b\n")
        try await repo.repository.commitAll(message: "b")
        try await repo.git("tag", "-a", "-m", "release", "v9.9.9")
        let plan = try #require(try await repo.repository.pushPlan())
        try await repo.repository.push(plan, force: false)
        #expect(try await repo.git("--git-dir=" + first, "rev-parse", "feature", in: repo.base.path).trimmingCharacters(in: .whitespacesAndNewlines) == plan.localHead)
        #expect(try await repo.git("--git-dir=" + first, "tag", "--list", in: repo.base.path).isEmpty, "no tag reached the remote")
        // Configured push options are not sent either (GitLab acts on some, e.g. `merge_request.create`); this receiving
        // end advertises none, so sending one would fail the push.
        try await repo.git("config", "push.pushOption", "merge_request.create")
        try repo.write("c.txt", "c\n")
        try await repo.repository.commitAll(message: "c")
        let next = try #require(try await repo.repository.pushPlan())
        try await repo.repository.push(next, force: false)
        #expect(try await repo.git("--git-dir=" + first, "rev-parse", "feature", in: repo.base.path).trimmingCharacters(in: .whitespacesAndNewlines) == next.localHead)
    }

    /// AF21: a force push leases on the remote head the confirmation showed. A commit someone else pushed meanwhile is
    /// not overwritten even after a fetch advanced the tracking ref (git would otherwise lease on the new value).
    @Test func aForcePushLeasesOnTheConfirmedRemoteHead() async throws {
        let repo = try await TempRepo.make(files: ["a.txt": "one\n"])
        defer { repo.remove() }
        let (first, _) = try await remotes(repo)
        try repo.write("mine.txt", "mine\n")
        try await repo.repository.commitAll(message: "mine")
        try await repo.git("push", "-q", "origin", "main")
        try await repo.git("commit", "-q", "--amend", "-m", "mine, amended")
        let plan = try #require(try await repo.repository.pushPlan())
        #expect(plan.needsForce && plan.remoteHead != nil)
        // Someone else pushes to main, and a background fetch updates origin/main while the dialog is open.
        let other = repo.base.appending(path: "other").path
        try await repo.git("clone", "-q", first, other, in: repo.base.path)
        try Data("theirs\n".utf8).write(to: URL(filePath: other + "/theirs.txt"))
        try await repo.git("add", "-A", in: other)
        try await repo.git("commit", "-q", "-m", "theirs", in: other)
        try await repo.git("push", "-q", "origin", "main", in: other)
        let theirs = try await repo.git("rev-parse", "HEAD", in: other).trimmingCharacters(in: .whitespacesAndNewlines)
        try await repo.repository.fetch(remote: "origin")
        await #expect(throws: GitError.self) { try await repo.repository.push(plan, force: true) }
        #expect(try await repo.git("--git-dir=" + first, "rev-parse", "main", in: repo.base.path).trimmingCharacters(in: .whitespacesAndNewlines) == theirs)
    }
}
