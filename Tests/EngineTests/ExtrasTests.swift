import BelloCore
import Darwin
import Foundation
import GRDB
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

// Orchestration extras (docs/features/orchestration-extras.md): PR model and poller rules with recorded GitHub fixtures
// (no network), secret delivery and non-leakage, app-tool routing and scoping, against MockOpenCode.

// MARK: - Pull-request model

struct PullRequestModelTests {
    @Test func parsesAndFindsPullRequestURLs() {
        #expect(PullRequestRef.parse("https://github.com/acme/rocket/pull/42") == PullRequestRef(owner: "acme", repo: "rocket", number: 42))
        #expect(PullRequestRef.parse("github.com/acme/rocket.js/pull/7/files#diff") == PullRequestRef(owner: "acme", repo: "rocket.js", number: 7))
        #expect(PullRequestRef.parse("https://github.com/acme/rocket/issues/42") == nil)
        let text = "Created https://github.com/a/b/pull/1 and see https://github.com/a/b/pull/1 plus https://github.com/c/d/pull/22."
        #expect(PullRequestRef.find(in: text).map(\.description) == ["a/b#1", "c/d#22"])
        #expect(GitHubRemote.parse("git@github.com:acme/rocket.git")! == ("acme", "rocket"))
        #expect(GitHubRemote.parse("https://github.com/acme/rocket")! == ("acme", "rocket"))
        #expect(GitHubRemote.parse("https://gitlab.com/acme/rocket") == nil)
    }

    @Test func linksRoundTripThroughMetadataKeepingOtherKeys() {
        let raw = RawJSON(#"{"bellocode":{"kind":"delegated"},"other":1}"#)
        let link = LinkedPullRequest(ref: PullRequestRef(owner: "a", repo: "b", number: 3), source: .agent, watching: true, linked: Date(timeIntervalSince1970: 1_000))
        let object = LinkedPullRequest.encode([link], intoMetadata: raw)
        #expect(object["other"] as? Int == 1)
        #expect((object["bellocode"] as? [String: Any])?["kind"] as? String == "delegated")
        let data = try! JSONSerialization.data(withJSONObject: object)
        #expect(LinkedPullRequest.decode(fromMetadata: RawJSON(String(decoding: data, as: UTF8.self))) == [link])
    }

    @Test func checksSummaryReadsWithoutColour() {
        let pending = ChecksSummary([CheckRun(id: 1, name: "build", status: .inProgress), CheckRun(id: 2, name: "lint", status: .completed, conclusion: .success)])
        #expect(pending == .pending(done: 1, total: 2))
        #expect(pending.text == "Checks 1/2")
        let failing = ChecksSummary([CheckRun(id: 1, name: "build", status: .completed, conclusion: .failure)])
        #expect(failing.text == "1 check failed")
        #expect(failing.glyph == "✕")
        #expect(ChecksSummary([]).text == "No checks")
    }

    @Test func ghOutputParsing() throws {
        let raw = "HTTP/2.0 304 Not Modified\r\nEtag: W/\"abc\"\r\nX-Other: 1\r\n\r\n"
        let response = try GHCLITransport.parse(Data(raw.utf8))
        #expect(response.status == 304)
        #expect(response.etag == "W/\"abc\"")
        let ok = try GHCLITransport.parse(Data("HTTP/2.0 200 OK\nETag: \"x\"\n\n{\"a\":1}".utf8))
        #expect(ok.status == 200)
        #expect(String(decoding: ok.body, as: UTF8.self) == "{\"a\":1}")
    }

    @Test func baselineFiresEachEventOnce() {
        let ref = PullRequestRef(owner: "a", repo: "b", number: 1)
        var snapshot = PullRequestSnapshot(
            ref: ref, title: "T", state: .open, headSHA: "sha1", checks: [CheckRun(id: 1, name: "build", status: .inProgress)], fetched: .now)
        var baseline = PullRequestWakeBaseline.initial(snapshot)
        #expect(baseline.diff(snapshot).events.isEmpty)
        snapshot.checks = [CheckRun(id: 1, name: "build", status: .completed, conclusion: .failure)]
        var (events, next) = baseline.diff(snapshot)
        #expect(events == [.checksFinished(sha: "sha1", summary: .failing(failed: 1, total: 1), failed: ["build"])])
        baseline = next
        #expect(baseline.diff(snapshot).events.isEmpty, "the same finished checks never wake twice")
        // A new push: checks run again and finish again → one more wake.
        snapshot.headSHA = "sha2"
        snapshot.checks = [CheckRun(id: 2, name: "build", status: .completed, conclusion: .success)]
        (events, next) = baseline.diff(snapshot)
        #expect(events.count == 1)
        baseline = next
        // A review with its comments is one event; plain comments are another.
        snapshot.reviews = [PullRequestReview(id: 10, author: "rev", state: "CHANGES_REQUESTED")]
        snapshot.reviewComments = 2
        (events, next) = baseline.diff(snapshot)
        #expect(events == [.reviewSubmitted(authors: ["rev"], decision: .changesRequested)])
        baseline = next
        snapshot.comments = 1
        (events, next) = baseline.diff(snapshot)
        #expect(events == [.newComments(1)])
        baseline = next
        snapshot.state = .merged
        (events, next) = baseline.diff(snapshot)
        #expect(events == [.closed(.merged)])
        #expect(next.diff(snapshot).events.isEmpty)
        #expect(PullRequestWakeText.message(snapshot, events: events).hasPrefix("[BelloCode PR watch] a/b#1"))
    }
}

// MARK: - GitHub fixtures

enum GitHubFixtures {
    static let ref = PullRequestRef(owner: "acme", repo: "rocket", number: 42)

    static func pull(state: String = "open", merged: Bool = false, sha: String = "abc123", comments: Int = 0, reviewComments: Int = 0) -> String {
        """
        {"number":42,"title":"Add launch checklist","state":"\(state)","merged":\(merged),"draft":false,
         "head":{"sha":"\(sha)","ref":"feature/checklist"},"base":{"ref":"main"},"user":{"login":"octo"},
         "comments":\(comments),"review_comments":\(reviewComments),"mergeable":true}
        """
    }

    static func checks(_ runs: [(String, String, String?)]) -> String {
        let items = runs.enumerated().map { index, run in
            #"{"id":\#(index + 1),"name":"\#(run.0)","status":"\#(run.1)","conclusion":\#(run.2.map { "\"\($0)\"" } ?? "null"),"html_url":"https://github.com/acme/rocket/runs/\#(index + 1)"}"#
        }
        return #"{"total_count":\#(runs.count),"check_runs":[\#(items.joined(separator: ","))]}"#
    }

    static func reviews(_ items: [(Int, String, String)]) -> String {
        "[" + items.map { #"{"id":\#($0.0),"user":{"login":"\#($0.1)"},"state":"\#($0.2)"}"# }.joined(separator: ",") + "]"
    }

    static func install(_ transport: FixtureGitHubTransport, pull: String, checks: String, reviews: String = "[]", sha: String = "abc123", etag: String? = nil) {
        transport.setJSON("repos/acme/rocket/pulls/42", pull, etag: etag)
        transport.setJSON("repos/acme/rocket/commits/\(sha)/check-runs?per_page=100", checks)
        transport.setJSON("repos/acme/rocket/pulls/42/reviews?per_page=100", reviews)
    }
}

@MainActor
final class FakePullRequestHost: PullRequestHost {
    var links: [SessionID: [LinkedPullRequest]] = [:]
    var wakes: [(SessionID, String)] = []
    var pauses: [SessionID: PullRequestPause] = [:]
    var failWakes = false

    func allSessions() async -> [Session] { [] }

    func writeLinks(_ sessionID: SessionID, _ transform: @escaping @Sendable ([LinkedPullRequest]) -> [LinkedPullRequest]) async throws -> [LinkedPullRequest] {
        let updated = transform(links[sessionID] ?? [])
        links[sessionID] = updated
        return updated
    }

    func wake(_ sessionID: SessionID, text: String, url: String) async throws {
        if failWakes { throw ExtrasError("offline") }
        wakes.append((sessionID, text))
    }

    func pause(_ sessionID: SessionID) -> PullRequestPause { pauses[sessionID] ?? .none }
    func branch(of sessionID: SessionID) async -> (owner: String, repo: String, branch: String)? { ("acme", "rocket", "feature/checklist") }
}

@MainActor
struct PullRequestServiceTests {
    let thread = SessionID("ses_pr")

    func make(store: ProjectionStore? = nil, transport: FixtureGitHubTransport = FixtureGitHubTransport()) throws -> (PullRequestService, ManualWallClock, FakePullRequestHost, FixtureGitHubTransport) {
        let clock = ManualWallClock(Date(timeIntervalSince1970: 1_800_000_000))
        let service = PullRequestService(store: try store ?? ProjectionStore(location: .inMemory), clock: clock, provider: transport, baseInterval: 120, maxBackoff: 1_800, autoPoll: false)
        let host = FakePullRequestHost()
        service.host = host
        return (service, clock, host, transport)
    }

    @Test func watchWakesOncePerEventAndStopsWhenMerged() async throws {
        let (service, clock, host, transport) = try make()
        GitHubFixtures.install(transport, pull: GitHubFixtures.pull(), checks: GitHubFixtures.checks([("build", "in_progress", nil)]))
        try await service.setWatching(GitHubFixtures.ref, for: thread, true)
        await service.waitForFetches()
        #expect(host.links[thread]?.first?.watching == true)
        await service.pollDue()  // baseline: checks running
        #expect(host.wakes.isEmpty)
        #expect(service.snapshots[GitHubFixtures.ref.url]?.checksSummary == .pending(done: 0, total: 1))

        GitHubFixtures.install(transport, pull: GitHubFixtures.pull(), checks: GitHubFixtures.checks([("build", "completed", "failure")]))
        clock.advance(by: 120)
        await service.pollDue()
        try #require(host.wakes.count == 1)
        #expect(host.wakes[0].1.contains("1 check failed"))
        clock.advance(by: 120)
        await service.pollDue()
        #expect(host.wakes.count == 1, "no second wake for the same checks")

        GitHubFixtures.install(
            transport, pull: GitHubFixtures.pull(state: "closed", merged: true), checks: GitHubFixtures.checks([("build", "completed", "failure")]),
            reviews: GitHubFixtures.reviews([(5, "reviewer", "APPROVED")]))
        clock.advance(by: 120)
        await service.pollDue()
        #expect(host.wakes.count == 2)
        #expect(host.wakes[1].1.contains("merged"))
        #expect(service.watch(thread, GitHubFixtures.ref.url)?.stoppedReason == "merged")
        #expect(service.nextPollDate(thread, GitHubFixtures.ref.url) == nil)
        #expect(host.links[thread]?.first?.watching == false)
        service.shutdown()
    }

    @Test func relaunchDoesNotRepeatAWake() async throws {
        let store = try ProjectionStore(location: .inMemory)
        do {
            let (service, clock, host, transport) = try make(store: store)
            GitHubFixtures.install(transport, pull: GitHubFixtures.pull(), checks: GitHubFixtures.checks([("build", "in_progress", nil)]))
            try await service.setWatching(GitHubFixtures.ref, for: thread, true)
        await service.waitForFetches()
            await service.pollDue()
            GitHubFixtures.install(transport, pull: GitHubFixtures.pull(), checks: GitHubFixtures.checks([("build", "completed", "success")]))
            clock.advance(by: 120)
            await service.pollDue()
            #expect(host.wakes.count == 1)
            service.shutdown()
        }
        let (service, _, host, transport) = try make(store: store)
        GitHubFixtures.install(transport, pull: GitHubFixtures.pull(), checks: GitHubFixtures.checks([("build", "completed", "success")]))
        await service.start()
        await service.pollDue()
        #expect(host.wakes.isEmpty, "the baseline was persisted")
        service.shutdown()
    }

    @Test func settledThreadsAbsorbEventsAndArchivedThreadsAreNotPolled() async throws {
        let (service, clock, host, transport) = try make()
        GitHubFixtures.install(transport, pull: GitHubFixtures.pull(), checks: GitHubFixtures.checks([("build", "in_progress", nil)]))
        try await service.setWatching(GitHubFixtures.ref, for: thread, true)
        await service.waitForFetches()
        await service.pollDue()
        host.pauses[thread] = .settled
        GitHubFixtures.install(transport, pull: GitHubFixtures.pull(), checks: GitHubFixtures.checks([("build", "completed", "success")]))
        clock.advance(by: 120)
        await service.pollDue()
        #expect(host.wakes.isEmpty)
        host.pauses[thread] = .none
        clock.advance(by: 120)
        await service.pollDue()
        #expect(host.wakes.isEmpty, "unsettling does not replay absorbed events")
        host.pauses[thread] = .archived
        let before = transport.requests.count
        clock.advance(by: 120)
        await service.pollDue()
        #expect(transport.requests.count == before, "archived: no requests")
        service.shutdown()
    }

    @Test func failuresBackOffThenStopTheWatch() async throws {
        let (service, clock, host, transport) = try make()
        transport.set("repos/acme/rocket/pulls/42", [GitHubResponse(status: 599)])
        try await service.setWatching(GitHubFixtures.ref, for: thread, true)
        await service.waitForFetches()
        var gaps: [TimeInterval] = []
        for _ in 0..<PullRequestService.maxFailures {
            let now = clock.now()
            await service.pollDue()
            guard let next = service.nextPollDate(thread, GitHubFixtures.ref.url) else { break }
            gaps.append(next.timeIntervalSince(now))
            clock.advance(to: next)
        }
        #expect(gaps.prefix(5) == [240, 480, 960, 1_800, 1_800])
        #expect(service.watch(thread, GitHubFixtures.ref.url)?.stoppedReason?.contains("could not be reached") == true)
        #expect(host.wakes.isEmpty)
        #expect(service.problems[GitHubFixtures.ref.url] != nil)
        service.shutdown()
    }

    @Test func etagsMakeUnchangedPollsCheap() async throws {
        let (service, _, _, transport) = try make()
        GitHubFixtures.install(transport, pull: GitHubFixtures.pull(), checks: GitHubFixtures.checks([]), etag: "\"v1\"")
        _ = await service.refresh(GitHubFixtures.ref)
        _ = await service.refresh(GitHubFixtures.ref)
        let pulls = transport.requests.filter { $0.path == "repos/acme/rocket/pulls/42" }
        #expect(pulls.count == 2)
        #expect(pulls[0].etag == nil)
        #expect(pulls[1].etag == "\"v1\"")
        #expect(service.snapshots[GitHubFixtures.ref.url]?.title == "Add launch checklist", "a 304 reuses the cached body")
    }

    @Test func autoLinksFromGhPrCreateOutputAndFromTheBranch() async throws {
        let (service, _, host, transport) = try make()
        GitHubFixtures.install(transport, pull: GitHubFixtures.pull(), checks: GitHubFixtures.checks([]))
        await service.noticeCommand(partID: "prt_1", sessionID: thread, command: "git status", output: "https://github.com/acme/rocket/pull/42")
        #expect(host.links[thread] == nil, "only PR commands link")
        await service.noticeCommand(partID: "prt_2", sessionID: thread, command: "gh pr create --fill", output: "https://github.com/acme/rocket/pull/42\n")
        #expect(host.links[thread]?.map(\.source) == [.output])
        let other = SessionID("ses_branch")
        transport.setJSON("repos/acme/rocket/pulls?state=open&head=acme:feature/checklist", #"[{"number":42}]"#)
        await service.autoLinkBranch(other)
        #expect(host.links[other]?.map(\.ref) == [GitHubFixtures.ref])
        #expect(host.links[other]?.first?.source == .branch)
    }

    @Test func publicAPIWithoutAccessSaysHowToConnect() async throws {
        let transport = FixtureGitHubTransport(access: .publicAPI)
        let (service, _, _, _) = try make(transport: transport)
        _ = await service.refresh(GitHubFixtures.ref)
        #expect(service.problems[GitHubFixtures.ref.url]?.contains("gh auth login") == true)
    }
}

// MARK: - Secrets

@MainActor
struct SecretPipeTests {
    /// Reads a named pipe on a plain thread (opening a pipe for reading blocks until the writer opens it).
    static func readPipe(_ path: String) async -> String? {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let fd = open(path, O_RDONLY)
                guard fd >= 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 256)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer[0..<count])
                }
                close(fd)
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    @Test func pipeYieldsTheValueOnceThenDisappears() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bc-secret-test-\(UUID().uuidString)")
        let vault = InMemorySecretVault()
        let service = SecretService(vault: vault, store: try ProjectionStore(location: .inMemory), clock: SystemWallClock(), directory: directory)
        let account = try await service.save(label: "npm token", value: SecretValue("s3cr3t-pipe-value"))
        let reference = service.issueReference(account: account, label: "npm token", for: SessionID("ses_a"))
        #expect(throws: ExtrasError.self) { try service.redeem(reference, by: SessionID("ses_other")) }
        let (path, label) = try service.redeem(reference, by: SessionID("ses_a"))
        #expect(label == "npm token")
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(await Self.readPipe(path) == "s3cr3t-pipe-value")
        try await waitUntil("pipe removed") { !FileManager.default.fileExists(atPath: path) }
        #expect(open(path, O_RDONLY | O_NONBLOCK) == -1, "a second reader gets nothing")
        #expect(throws: ExtrasError.self) { try service.redeem(reference, by: SessionID("ses_a")) }
        service.shutdown()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func unreadPipeExpires() async throws {
        let clock = ManualWallClock(Date(timeIntervalSince1970: 1_800_000_000))
        let directory = FileManager.default.temporaryDirectory.appending(path: "bc-secret-test-\(UUID().uuidString)")
        let service = SecretService(vault: InMemorySecretVault(), store: try ProjectionStore(location: .inMemory), clock: clock, directory: directory)
        let account = try await service.save(label: "x", value: SecretValue("v"))
        let path = try service.deliverFile(account: account)
        #expect(FileManager.default.fileExists(atPath: path))
        clock.advance(by: SecretService.fileLifetime + 1)
        try await waitUntil("expired pipe removed") { !FileManager.default.fileExists(atPath: path) && service.pendingPipeCount == 0 }
        service.shutdown()
    }

    @Test func secretValueNeverPrints() {
        let value = SecretValue("hunter2")
        #expect("\(value)" == "<secret>")
        #expect(String(reflecting: value) == "<secret>")
    }
}

// MARK: - App tools end to end (MockOpenCode)

@MainActor
final class FakeRenderer: HTMLVisualRendering {
    var requests: [HTMLRenderRequest] = []
    func render(_ request: HTMLRenderRequest) async throws -> HTMLRenderOutput {
        requests.append(request)
        return HTMLRenderOutput(contentHeight: 310, png: Data([0x89, 0x50, 0x4E, 0x47]), console: [], blocked: request.allowedHosts.isEmpty ? ["https://cdn.example.com/x.js"] : [])
    }
}

@MainActor
struct ExtrasToolTests {
    @MainActor struct Fixture {
        let harness: MockHarness
        let engine: Engine
        let vault: InMemorySecretVault
        let gitHub: FixtureGitHubTransport

        static func start() async throws -> Fixture {
            let harness = try await MockHarness.start(.empty(directory: "/tmp/mock-extras"))
            var configuration = EngineConfiguration(server: .fixed(harness.connection), store: .inMemory)
            configuration.eventBackoff = BackoffPolicy(initial: .milliseconds(20), maximum: .milliseconds(200))
            configuration.writeInterval = .milliseconds(20)
            let vault = InMemorySecretVault()
            let gitHub = FixtureGitHubTransport()
            configuration.secretVault = vault
            configuration.gitHub = gitHub
            configuration.wallClock = ManualWallClock(Date(timeIntervalSince1970: 1_800_000_000))
            let engine = try Engine(configuration: configuration)
            await engine.start()
            try await waitUntil("live") { engine.root.connection == .live }
            return Fixture(harness: harness, engine: engine, vault: vault, gitHub: gitHub)
        }

        func stop() async {
            await engine.stop()
            await harness.stop()
        }

        func call(_ tool: String, _ arguments: [String: OpenCodeKit.JSONValue], session: SessionID?) async -> ClientMCPResult {
            await engine.orchestration.handleAppTool(
                ClientMCPCall(tool: tool, arguments: .object(arguments), sessionID: session?.rawValue, directory: "/tmp/mock-extras"))
        }

        /// Every text and blob in the local store, for leak checks.
        func storeDump() async throws -> String {
            try await engine.store.writer.read { db in
                var out = ""
                for table in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'message_fts%'") {
                    for row in try Row.fetchAll(db, sql: "SELECT * FROM \(table)") {
                        for value in row.databaseValues {
                            if let text = String.fromDatabaseValue(value) { out += text + "\n" }
                            if let data = Data.fromDatabaseValue(value) { out += String(decoding: data, as: UTF8.self) + "\n" }
                        }
                    }
                }
                return out
            }
        }
    }

    @Test func secretRequestCardSaveAndRedeemNeverLeaksTheValue() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        let engine = fixture.engine
        let session = try await engine.createThread(in: "/tmp/mock-extras", title: "deploy")
        try await waitUntil("graph") { engine.orchestration.node(session.id) != nil }
        let thread = engine.openThread(session.id)
        let asked = await fixture.call("request_secret", ["label": "Deploy token", "reason": "To publish the site.", "url": "https://example.com/tokens"], session: session.id)
        #expect(!asked.isError)
        try await waitUntil("card pinned") { thread.pendingRequests.contains { $0.isApp } }
        guard case .app(let request) = thread.pendingRequests.first(where: \.isApp)!, case .secret(let prompt) = request.kind else {
            Issue.record("not a secret card")
            return
        }
        #expect(prompt.setupURL == "https://example.com/tokens")
        try await waitUntil("counted in Needs You") { engine.root.attention.counts.questions == 1 }

        let sentinel = "zz-SENTINEL-\(UUID().uuidString)"
        try await engine.extras.respond(to: request.id, .saveSecret(SecretValue(sentinel)))
        try await waitUntil("card resolved") { !thread.pendingRequests.contains { $0.isApp } }
        #expect(fixture.vault.count == 1)
        #expect(engine.extras.secrets.labels.map(\.label) == ["Deploy token"])
        let wakes = await fixture.harness.server.syntheticTexts
        let wake = try #require(wakes.last)
        #expect(wake.hasPrefix("[BelloCode secret]"))
        let reference = try #require(wake.split(separator: " ").first { $0.hasPrefix(SecretService.referencePrefix) }.map(String.init))

        let file = await fixture.call("secret_file", ["secretRef": .string(reference)], session: session.id)
        #expect(!file.isError)
        let path = try #require(file.text.split(separator: "\n").first?.split(separator: " ").last.map(String.init))
        #expect(await SecretPipeTests.readPipe(path) == sentinel)
        let again = await fixture.call("secret_file", ["secretRef": .string(reference)], session: session.id)
        #expect(again.isError, "one use")

        // The value is nowhere: tool results, wake messages, the server's messages and metadata, events, the store.
        await engine.flush()
        for text in [asked.text, file.text, again.text] + wakes { #expect(!text.contains(sentinel)) }
        #expect(!(await fixture.harness.server.allMessageText()).contains(sentinel))
        let events = await fixture.harness.server.publishedEvents().map(\.serialized).joined()
        #expect(!events.contains(sentinel))
        #expect(!(try await fixture.storeDump()).contains(sentinel))
        thread.close()
    }

    @Test func declinedSecretTellsTheAgent() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        let engine = fixture.engine
        let session = try await engine.createThread(in: "/tmp/mock-extras", title: "decline")
        try await waitUntil("graph") { engine.orchestration.node(session.id) != nil }
        _ = await fixture.call("request_secret", ["label": "API key", "reason": "r"], session: session.id)
        let id = try #require(await engine.core.appRequests().first?.id)
        try await engine.extras.respond(to: id, .decline)
        #expect((await fixture.harness.server.syntheticTexts).last?.contains("declined") == true)
        #expect(fixture.vault.count == 0)
    }

    @Test func agentScheduleNeedsApprovalOncePerProject() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        let engine = fixture.engine
        let session = try await engine.createThread(in: "/tmp/mock-extras", title: "scheduler")
        try await waitUntil("graph") { engine.orchestration.node(session.id) != nil }
        let first = await fixture.call(
            "schedule_task", ["name": "Nightly triage", "prompt": "Triage new issues", "time": "09:00", "weekdays": .array(["mon", "fri"])],
            session: session.id)
        #expect(!first.isError, "\(first.text)")
        #expect(first.text.contains("paused until the user approves"))
        let task = try #require(engine.extras.schedules.tasks.first)
        #expect(task.approval == .pending)
        #expect(task.rule == .daily(hour: 9, minute: 0, weekdays: [2, 6]))
        let request = try #require(await engine.core.appRequests().first)
        #expect(request.isApproval)
        try await engine.extras.respond(to: request.id, .approve(always: true))
        #expect(engine.extras.schedules.task(task.id)?.approval == .approved)
        // Second task in the same project: no card.
        let second = await fixture.call("schedule_task", ["name": "Ping", "prompt": "p", "everyMinutes": 30], session: session.id)
        #expect(second.text.hasPrefix("Scheduled “Ping”"))
        #expect(await engine.core.appRequests().isEmpty)
        // A broader permission mode than the caller's is refused; a bad weekday too.
        let broad = await fixture.call("schedule_task", ["name": "X", "prompt": "p", "everyMinutes": 30, "permissionMode": "fullAccess"], session: session.id)
        #expect(broad.isError)
        let list = await fixture.call("list_scheduled_tasks", [:], session: session.id)
        #expect(list.text.contains("Nightly triage") && list.text.contains("Ping"))
        // Run now through the mock: a new thread with the labelled prompt.
        let ran = await fixture.call("run_scheduled_task_now", ["taskID": .string(task.id)], session: session.id)
        #expect(ran.text.contains("Started"), "\(ran.text)")
        let deleted = await fixture.call("delete_scheduled_task", ["taskID": .string(task.id)], session: session.id)
        #expect(!deleted.isError)
        #expect(engine.extras.schedules.task(task.id) == nil)
        // Unattributed calls are refused.
        #expect(await fixture.call("list_scheduled_tasks", [:], session: nil).isError)
    }

    @Test func linkPullRequestsWritesSessionMetadata() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        let engine = fixture.engine
        GitHubFixtures.install(fixture.gitHub, pull: GitHubFixtures.pull(), checks: GitHubFixtures.checks([("build", "completed", "success")]))
        let session = try await engine.createThread(in: "/tmp/mock-extras", title: "pr")
        try await waitUntil("graph") { engine.orchestration.node(session.id) != nil }
        let linked = await fixture.call("link_pull_requests", ["urls": .array([.string(GitHubFixtures.ref.url)])], session: session.id)
        #expect(!linked.isError, "\(linked.text)")
        let stored = try await fixture.harness.client.session(session.id.rawValue)
        #expect(String(describing: stored.metadata ?? .null).contains("bellocode_prs"))
        let list = await fixture.call("list_thread_pull_requests", [:], session: session.id)
        #expect(list.text.contains("Add launch checklist") && list.text.contains("Check passed"))
        let bad = await fixture.call("link_pull_requests", ["urls": .array(["https://example.com/x"])], session: session.id)
        #expect(bad.isError)
        // The wake path posts a labelled synthetic message through the mock.
        try await engine.extras.wake(session.id, text: "[BelloCode PR watch] acme/rocket#42: checks finished", url: GitHubFixtures.ref.url)
        #expect((await fixture.harness.server.syntheticTexts).last?.hasPrefix("[BelloCode PR watch]") == true)
    }

    @Test func htmlRenderStoresTheVisualAndAsksForNetwork() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        let engine = fixture.engine
        let directory = FileManager.default.temporaryDirectory.appending(path: "bc-visuals-\(UUID().uuidString)")
        let visuals = VisualService(store: engine.store, directory: directory)
        await visuals.load()
        let renderer = FakeRenderer()
        engine.extras.visuals.renderer = renderer
        let session = try await engine.createThread(in: "/tmp/mock-extras", title: "chart")
        try await waitUntil("graph") { engine.orchestration.node(session.id) != nil }
        let html = "<html><body><h1>Chart</h1></body></html>"
        let rendered = await fixture.call(
            "html_render", ["html": .string(html), "title": "Weekly", "allowNetwork": .array(["cdn.jsdelivr.net"])], session: session.id)
        #expect(!rendered.isError, "\(rendered.text)")
        #expect(rendered.text.hasPrefix("visualID: v_"))
        #expect(rendered.text.contains("height: 310"))
        #expect(rendered.text.contains("note: Network blocked"))
        #expect(renderer.requests.first?.allowedHosts == [], "no network before approval")
        let id = try #require(rendered.text.split(separator: "\n").first?.split(separator: " ").last.map(String.init))
        #expect(engine.extras.visuals.html(id) == html)
        let request = try #require(await engine.core.appRequests().first)
        try await engine.extras.respond(to: request.id, .approve(always: false))
        #expect(engine.extras.visuals.allowedHosts(id) == ["cdn.jsdelivr.net"])
        let preview = await fixture.call("html_preview", ["html": .string(html)], session: session.id)
        #expect(preview.text.contains("contentHeight: 310"))
        #expect(preview.text.contains("png: "))
        #expect(preview.text.contains("blocked"))
        let local = await fixture.call("html_render", ["html": .string(html), "title": "x", "allowNetwork": .array(["127.0.0.1"])], session: session.id)
        #expect(local.isError)
        let missing = await fixture.call("html_render", ["title": "x"], session: session.id)
        #expect(missing.isError)
        try? FileManager.default.removeItem(at: directory)
    }
}
