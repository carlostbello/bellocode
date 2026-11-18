import BelloCore
@testable import Engine
import Foundation
import Synchronization
import Testing
@testable import DiffKit

/// The git actions control's model (docs/features/git-parity.md): confirmations before pushing to the default branch
/// and before a force push, the commit form with a generated message, and the planner wiring.
@Suite("Git actions model", .timeLimit(.minutes(3)), .serialized)
@MainActor
struct GitActionsModelTests {
    final class Log: Sendable {
        let confirms = Mutex<[String]>([])
        let notices = Mutex<[String]>([])
        let mergeRequests = Mutex(0)
    }

    static func fixture(answer: Bool) async throws -> (ChangesFixture, GitActionsModel, Log, String) {
        let fixture = try await ChangesFixture.make(files: ["a.txt": "one\n"])
        let origin = fixture.root.appending(path: "origin.git").path
        _ = try await fixture.git.runner.run(["init", "-q", "--bare", "-b", "main", origin], in: fixture.root.path)
        _ = try await fixture.git.runner.run(["remote", "add", "origin", origin], in: fixture.repo.path)
        _ = try await fixture.git.runner.run(["push", "-q", "-u", "origin", "main"], in: fixture.repo.path)
        let repository = fixture.git.repository(for: fixture.repo.path)
        try await waitFor { repository.status != nil }
        let log = Log()
        let host = GitActionHost(
            createMergeRequest: { log.mergeRequests.withLock { $0 += 1 } }, openMergeRequest: {},
            generate: { _ in "```\nAdd b\n```" }, confirm: { title, _, _ in log.confirms.withLock { $0.append(title) }; return answer },
            notice: { text in log.notices.withLock { $0.append(text) } }, publish: {})
        let model = GitActionsModel(repository: repository, host: host)
        await model.reload()
        return (fixture, model, log, origin)
    }

    static func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test func pushingTheDefaultBranchAsksFirstAndCancelSendsNothing() async throws {
        let (fixture, model, log, origin) = try await Self.fixture(answer: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try ChangesFixture.write(fixture.repo, "b.txt", "b\n")
        model.repository.refresh()
        try await Self.waitFor { model.repository.status?.isDirty == true && !model.repository.isRefreshing }
        // The commit form generates a message; committing and pushing to main asks, and "Cancel" pushes nothing.
        await model.perform(.commitAndPush)
        let form = try #require(model.commit)
        await form.generateMessage()
        #expect(form.message == "Add b")
        await model.finishCommit(form, as: .commitAndPush)
        #expect(log.confirms.withLock { $0 } == ["Push to main?"])
        let remote = try await fixture.git.runner.run(["--git-dir=" + origin, "rev-parse", "main"], in: fixture.root.path).text
        let local = try await fixture.git.runner.run(["rev-parse", "HEAD^"], in: fixture.repo.path).text
        #expect(remote == local, "nothing was pushed")
    }

    @Test func aForcePushNeedsItsOwnConfirmation() async throws {
        let (fixture, model, log, origin) = try await Self.fixture(answer: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.git.runner.run(["switch", "-q", "-c", "feat/x"], in: fixture.repo.path)
        try ChangesFixture.write(fixture.repo, "x.txt", "x\n")
        _ = try await fixture.git.runner.run(["add", "-A"], in: fixture.repo.path)
        _ = try await fixture.git.runner.run(["commit", "-q", "-m", "x"], in: fixture.repo.path)
        model.repository.refresh()
        try await Self.waitFor { model.repository.status?.branch == "feat/x" && !model.repository.isRefreshing }
        await model.perform(.pushAndCreateMergeRequest)
        #expect(log.confirms.withLock { $0 }.isEmpty, "a feature branch pushes without asking")
        #expect(log.mergeRequests.withLock { $0 } == 1)
        _ = try await fixture.git.runner.run(["commit", "-q", "--amend", "-m", "x amended"], in: fixture.repo.path)
        model.repository.refresh()
        try await Self.waitFor { !model.repository.isRefreshing }
        await model.perform(.push)
        #expect(log.confirms.withLock { $0 } == ["Force push feat/x?"])
        let remote = try await fixture.git.runner.run(["--git-dir=" + origin, "log", "-1", "--format=%s", "feat/x"], in: fixture.root.path).text
        #expect(remote.contains("x amended"))
    }
}
