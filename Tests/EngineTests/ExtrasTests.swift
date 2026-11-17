import BelloCore
import Darwin
import Foundation
import GRDB
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

// Orchestration extras (docs/features/orchestration-extras.md): GitLab merge-request model and poller rules with
// recorded GitLab API fixtures (no network), secret delivery and non-leakage, app-tool routing and scoping, against
// MockOpenCode.

// MARK: - Merge-request model

struct MergeRequestModelTests {
    static let root = GitLabInstance(baseURL: "https://gitlab.example.com/")!
    static let prefixed = GitLabInstance(baseURL: "https://code.corp.test:8443/gitlab")!

    @Test func instancesNormalise() {
        #expect(Self.root.baseURL == "https://gitlab.example.com")
        #expect(Self.prefixed.baseURL == "https://code.corp.test:8443/gitlab")
        #expect(Self.prefixed.pathPrefix == "gitlab")
        #expect(Self.prefixed.apiBase == "https://code.corp.test:8443/gitlab/api/v4")
        #expect(GitLabInstance(baseURL: "gitlab.example.com") == nil)
        #expect(GitLabInstance(baseURL: "ftp://x.y") == nil)
    }

    @Test func parsesMergeRequestURLsOnConfiguredInstancesOnly() {
        let instances = [Self.root, Self.prefixed]
        #expect(MergeRequestRef.parse("https://gitlab.example.com/team/sub/app/-/merge_requests/42/diffs", instances: instances)
            == MergeRequestRef(instance: Self.root.baseURL, projectPath: "team/sub/app", iid: 42))
        #expect(MergeRequestRef.parse("https://code.corp.test:8443/gitlab/platform/rocket/-/merge_requests/7", instances: instances)
            == MergeRequestRef(instance: Self.prefixed.baseURL, projectPath: "platform/rocket", iid: 7))
        #expect(MergeRequestRef.parse("https://other.example.org/a/b/-/merge_requests/1", instances: instances) == nil, "unknown host")
        #expect(MergeRequestRef.parse("https://gitlab.example.com/a/b/-/merge_requests/new?x=1", instances: instances) == nil, "the new-MR page")
        let output = "remote:\nremote: View merge request for parser:\nremote:   https://gitlab.example.com/team/app/-/merge_requests/12\nremote:\n"
        #expect(MergeRequestRef.find(in: output, instances: instances).map(\.description) == ["team/app!12"])
    }

    @Test func remotesResolveAgainstConfiguredHostsWithPathPrefixes() {
        let instances = [Self.root, Self.prefixed]
        #expect(ForgeProject.resolve(remote: "git@gitlab.example.com:team/sub/app.git", instances: instances)?.projectPath == "team/sub/app")
        #expect(ForgeProject.resolve(remote: "ssh://git@code.corp.test:2222/platform/rocket.git", instances: instances)
            == ForgeProject(instance: Self.prefixed, projectPath: "platform/rocket"))
        #expect(ForgeProject.resolve(remote: "https://code.corp.test:8443/gitlab/platform/rocket.git", instances: instances)?.projectPath == "platform/rocket")
        #expect(ForgeProject.resolve(remote: "https://code.corp.test:8443/platform/rocket.git", instances: instances) == nil, "HTTPS without the prefix")
        #expect(ForgeProject.resolve(remote: "git@github.com:acme/app.git", instances: instances) == nil)
        #expect(ForgeProject.resolve(remote: "/tmp/origin.git", instances: instances) == nil)
        let project = ForgeProject(instance: Self.prefixed, projectPath: "platform/rocket")
        #expect(project.newMergeRequestURL(branch: "feat/x", target: "main")?.absoluteString
            == "https://code.corp.test:8443/gitlab/platform/rocket/-/merge_requests/new?merge_request%5Bsource_branch%5D=feat/x&merge_request%5Btarget_branch%5D=main")
    }

    @Test func linksRoundTripThroughMetadataKeepingOtherKeys() {
        let raw = RawJSON(#"{"bellocode":{"kind":"delegated"},"other":1}"#)
        let link = LinkedMergeRequest(ref: MergeRequestRef(instance: Self.root.baseURL, projectPath: "a/b", iid: 3), source: .agent, watching: true, linked: Date(timeIntervalSince1970: 1_000))
        let object = LinkedMergeRequest.encode([link], intoMetadata: raw)
        #expect(object["other"] as? Int == 1)
        #expect((object["bellocode"] as? [String: Any])?["kind"] as? String == "delegated")
        let data = try! JSONSerialization.data(withJSONObject: object)
        #expect(LinkedMergeRequest.decode(fromMetadata: RawJSON(String(decoding: data, as: UTF8.self))) == [link])
    }

    @Test func pipelineSummaryReadsWithoutColour() {
        #expect(PipelineSummary(Pipeline(id: 1, status: "running", jobs: [PipelineJob(id: 1, name: "a", status: "success"), PipelineJob(id: 2, name: "b", status: "running")])).text == "Pipeline running 1/2")
        let failed = PipelineSummary(Pipeline(id: 1, status: "failed", jobs: [PipelineJob(id: 1, name: "a", status: "failed")]))
        #expect(failed.text == "Pipeline failed (1 job)")
        #expect(failed.glyph == "✕")
        #expect(PipelineSummary(nil).text == "No pipeline")
        #expect(MergeRequestApprovals(approved: false, required: 2, left: 1, approvedBy: ["mara"]).label == "1 of 2 approvals")
    }

    @Test func baselineFiresEachEventOnce() {
        let ref = MergeRequestRef(instance: Self.root.baseURL, projectPath: "team/app", iid: 1)
        var snapshot = MergeRequestSnapshot(ref: ref, title: "T", state: .opened, pipeline: Pipeline(id: 9, status: "running"), fetched: .now)
        var baseline = MergeRequestWakeBaseline.initial(snapshot)
        #expect(baseline.diff(snapshot).events.isEmpty)
        snapshot.pipeline = Pipeline(id: 9, status: "failed", jobs: [PipelineJob(id: 1, name: "unit", status: "failed")])
        var (events, next) = baseline.diff(snapshot)
        #expect(events == [.pipelineFinished(id: 9, summary: .failed(jobs: 1), failedJobs: ["unit"])])
        baseline = next
        #expect(baseline.diff(snapshot).events.isEmpty, "the same pipeline never wakes twice")
        snapshot.pipeline = Pipeline(id: 10, status: "success")
        (events, next) = baseline.diff(snapshot)
        #expect(events.count == 1, "a new pipeline finishing wakes again")
        baseline = next
        snapshot.approvals = MergeRequestApprovals(approved: true, required: 1, left: 0, approvedBy: ["mara"])
        (events, next) = baseline.diff(snapshot)
        #expect(events == [.approved(by: ["mara"])])
        baseline = next
        snapshot.approvals = MergeRequestApprovals()
        (events, next) = baseline.diff(snapshot)
        #expect(events == [.approvalRevoked(by: ["mara"])])
        baseline = next
        snapshot.userNotes = 2
        (events, next) = baseline.diff(snapshot)
        #expect(events == [.newNotes(2)])
        baseline = next
        snapshot.state = .merged
        (events, next) = baseline.diff(snapshot)
        #expect(events == [.closed(.merged)])
        #expect(next.diff(snapshot).events.isEmpty)
        #expect(MergeRequestWakeText.message(snapshot, events: events).hasPrefix("[BelloCode MR watch] team/app!1: The merge request was merged."))
    }
}

// MARK: - GitLab fixtures

enum GitLabFixtures {
    static let instance = GitLabInstance(baseURL: "https://code.corp.test/gitlab")!
    static let ref = MergeRequestRef(instance: instance.baseURL, projectPath: "platform/rocket", iid: 42)
    static let api = "https://code.corp.test/gitlab/api/v4/projects/platform%2Frocket"

    static func mr(state: String = "opened", pipeline: Int = 900, pipelineStatus: String = "running", notes: Int = 0) -> String {
        #"{"iid":42,"title":"Add launch checklist","state":"\#(state)","draft":true,"source_branch":"feat/checklist","target_branch":"main","author":{"username":"octo"},"sha":"abc123","web_url":"https://code.corp.test/gitlab/platform/rocket/-/merge_requests/42","user_notes_count":\#(notes),"head_pipeline":{"id":\#(pipeline),"status":"\#(pipelineStatus)","web_url":"https://code.corp.test/gitlab/platform/rocket/-/pipelines/\#(pipeline)"}}"#
    }

    static func jobs(_ items: [(String, String)], from: Int = 0) -> String {
        "[" + items.enumerated().map { #"{"id":\#(from + $0.offset + 1),"name":"\#($0.element.0)","stage":"test","status":"\#($0.element.1)","web_url":"https://code.corp.test/gitlab/platform/rocket/-/jobs/\#(from + $0.offset + 1)"}"# }.joined(separator: ",") + "]"
    }

    static func approvals(_ by: [String], required: Int = 1) -> String {
        #"{"approved":\#(by.count >= required),"approvals_required":\#(required),"approvals_left":\#(max(0, required - by.count)),"approved_by":[\#(by.map { #"{"user":{"username":"\#($0)"}}"# }.joined(separator: ","))]}"#
    }

    static func install(
        _ transport: FixtureForgeTransport, mr: String, jobs: String = "[]", approvals: String = GitLabFixtures.approvals([]), pipeline: Int = 900,
        discussions: String = "[]", etag: String? = nil
    ) {
        transport.setJSON("\(api)/merge_requests/42", mr, etag: etag)
        transport.setJSON("\(api)/merge_requests/42/approvals", approvals)
        transport.setJSON("\(api)/pipelines/\(pipeline)/jobs?per_page=100", jobs)
        transport.setJSON("\(api)/merge_requests/42/discussions?per_page=100", discussions)
    }

    static func tokens() -> InMemorySecretVault {
        let vault = InMemorySecretVault()
        try? vault.store(account: instance.baseURL, label: "test", value: SecretValue("glpat-TEST-TOKEN-SENTINEL"))
        return vault
    }
}

struct GitLabProviderTests {
    @Test func readsAnMRWithPaginationApprovalsAndDiscussions() async throws {
        let transport = FixtureForgeTransport()
        let provider = GitLabProvider(transport: transport, tokens: GitLabFixtures.tokens())
        GitLabFixtures.install(transport, mr: GitLabFixtures.mr(pipelineStatus: "failed", notes: 5), approvals: GitLabFixtures.approvals(["mara"], required: 2))
        // Jobs over two pages (X-Next-Page), discussions with one unresolved thread.
        transport.setJSON("\(GitLabFixtures.api)/pipelines/900/jobs?per_page=100", GitLabFixtures.jobs([("build", "success")]), headers: ["X-Next-Page": "2"])
        transport.setJSON("\(GitLabFixtures.api)/pipelines/900/jobs?per_page=100&page=2", GitLabFixtures.jobs([("unit", "failed")], from: 1))
        transport.setJSON(
            "\(GitLabFixtures.api)/merge_requests/42/discussions?per_page=100",
            #"[{"id":"a","notes":[{"id":1,"resolvable":true,"resolved":false}]},{"id":"b","notes":[{"id":2,"resolvable":true,"resolved":true}]},{"id":"c","notes":[{"id":3,"resolvable":false}]}]"#)
        let snapshot = try await provider.mergeRequest(GitLabFixtures.ref, now: .now)
        #expect(snapshot.title == "Add launch checklist")
        #expect(snapshot.stateLabel == "Draft")
        #expect(snapshot.pipeline?.jobs.map(\.name) == ["build", "unit"])
        #expect(snapshot.pipelineSummary == .failed(jobs: 1))
        #expect(snapshot.approvals.label == "1 of 2 approvals")
        #expect(snapshot.unresolvedDiscussions == 1)
        #expect(snapshot.userNotes == 5)
        let requests = transport.requests
        #expect(requests.allSatisfy { $0.hadToken }, "every call carries the token header")
        #expect(transport.requests.allSatisfy { $0.url.hasPrefix("https://code.corp.test/gitlab/api/v4/") }, "the path prefix is kept")
    }

    @Test func conditionalRequestsReuseTheCachedBody() async throws {
        let transport = FixtureForgeTransport()
        let provider = GitLabProvider(transport: transport, tokens: GitLabFixtures.tokens())
        GitLabFixtures.install(transport, mr: GitLabFixtures.mr(), etag: "W/\"v1\"")
        _ = try await provider.mergeRequest(GitLabFixtures.ref, now: .now)
        let second = try await provider.mergeRequest(GitLabFixtures.ref, now: .now)
        let mrs = transport.requests.filter { $0.url == "\(GitLabFixtures.api)/merge_requests/42" }
        #expect(mrs.map(\.etag) == [nil, "W/\"v1\""])
        #expect(second.title == "Add launch checklist", "a 304 reuses the cached body")
    }

    @Test func failuresAreTyped() async throws {
        let transport = FixtureForgeTransport()
        let provider = GitLabProvider(transport: transport, tokens: GitLabFixtures.tokens())
        transport.set("\(GitLabFixtures.api)/merge_requests/42", [ForgeResponse(status: 401, body: Data(#"{"message":"401 Unauthorized"}"#.utf8))])
        await #expect(throws: ForgeError.tokenInvalid(GitLabFixtures.instance.baseURL)) { try await provider.mergeRequest(GitLabFixtures.ref, now: .now) }
        #expect(ForgeError.tokenInvalid("x").description.contains("invalid or expired"))
        transport.set("\(GitLabFixtures.api)/merge_requests/42", [ForgeResponse(status: 429, headers: ["Retry-After": "90"])])
        await #expect(throws: ForgeError.rateLimited(retryAfter: 90)) { try await provider.mergeRequest(GitLabFixtures.ref, now: .now) }
        let noToken = GitLabProvider(transport: transport, tokens: InMemorySecretVault())
        await #expect(throws: ForgeError.noToken(GitLabFixtures.instance.baseURL)) { try await noToken.mergeRequest(GitLabFixtures.ref, now: .now) }
        #expect(!transport.requests.contains { !$0.hadToken }, "nothing is sent without a token")
    }

    @Test func openMRsForABranch() async throws {
        let transport = FixtureForgeTransport()
        let provider = GitLabProvider(transport: transport, tokens: GitLabFixtures.tokens())
        transport.setJSON("\(GitLabFixtures.api)/merge_requests?state=opened&source_branch=feat%2Fchecklist&per_page=20", #"[{"iid":42}]"#)
        let refs = try await provider.openMergeRequests(ForgeProject(instance: GitLabFixtures.instance, projectPath: "platform/rocket"), sourceBranch: "feat/checklist")
        #expect(refs == [GitLabFixtures.ref])
    }
}

@MainActor
final class FakeMergeRequestHost: MergeRequestHost {
    var links: [SessionID: [LinkedMergeRequest]] = [:]
    var wakes: [(SessionID, String)] = []
    var pauses: [SessionID: MergeRequestPause] = [:]
    var remote = "git@code.corp.test:platform/rocket.git"

    func allSessions() async -> [Session] { [] }

    func writeLinks(_ sessionID: SessionID, _ transform: @escaping @Sendable ([LinkedMergeRequest]) -> [LinkedMergeRequest]) async throws -> [LinkedMergeRequest] {
        let updated = transform(links[sessionID] ?? [])
        links[sessionID] = updated
        return updated
    }

    func wake(_ sessionID: SessionID, text: String, url: String) async throws { wakes.append((sessionID, text)) }
    func pause(_ sessionID: SessionID) -> MergeRequestPause { pauses[sessionID] ?? .none }
    func checkout(of sessionID: SessionID) async -> (remote: String, branch: String)? { (remote, "feat/checklist") }
}

@MainActor
struct MergeRequestServiceTests {
    let thread = SessionID("ses_mr")

    func make(store: ProjectionStore? = nil, tokens: InMemorySecretVault = GitLabFixtures.tokens()) async throws
        -> (MergeRequestService, ManualWallClock, FakeMergeRequestHost, FixtureForgeTransport)
    {
        let clock = ManualWallClock(Date(timeIntervalSince1970: 1_800_000_000))
        let transport = FixtureForgeTransport()
        let service = MergeRequestService(
            store: try store ?? ProjectionStore(location: .inMemory), clock: clock, transport: transport, tokens: tokens, baseInterval: 120,
            maxBackoff: 1_800, autoPoll: false)
        let host = FakeMergeRequestHost()
        service.host = host
        await service.start()
        _ = try await service.saveInstance(baseURL: GitLabFixtures.instance.baseURL, token: nil)
        return (service, clock, host, transport)
    }

    @Test func watchWakesOncePerEventAndStopsWhenMerged() async throws {
        let (service, clock, host, transport) = try await make()
        GitLabFixtures.install(transport, mr: GitLabFixtures.mr(), jobs: GitLabFixtures.jobs([("unit", "running")]))
        try await service.setWatching(GitLabFixtures.ref, for: thread, true)
        await service.waitForFetches()
        await service.pollDue()
        #expect(host.wakes.isEmpty)
        GitLabFixtures.install(transport, mr: GitLabFixtures.mr(pipelineStatus: "failed"), jobs: GitLabFixtures.jobs([("unit", "failed")]))
        clock.advance(by: 120)
        await service.pollDue()
        try #require(host.wakes.count == 1)
        #expect(host.wakes[0].1.contains("Pipeline failed (1 job)"))
        clock.advance(by: 120)
        await service.pollDue()
        #expect(host.wakes.count == 1, "no second wake for the same pipeline")
        GitLabFixtures.install(transport, mr: GitLabFixtures.mr(pipelineStatus: "failed"), jobs: GitLabFixtures.jobs([("unit", "failed")]), approvals: GitLabFixtures.approvals(["mara"]))
        clock.advance(by: 120)
        await service.pollDue()
        #expect(host.wakes.count == 2)
        #expect(host.wakes[1].1.contains("Approved by mara"))
        GitLabFixtures.install(transport, mr: GitLabFixtures.mr(state: "merged", pipelineStatus: "failed"), jobs: GitLabFixtures.jobs([("unit", "failed")]), approvals: GitLabFixtures.approvals(["mara"]))
        clock.advance(by: 120)
        await service.pollDue()
        #expect(host.wakes.count == 3)
        #expect(service.watch(thread, GitLabFixtures.ref.url)?.stoppedReason == "merged")
        #expect(service.nextPollDate(thread, GitLabFixtures.ref.url) == nil)
        #expect(host.links[thread]?.first?.watching == false)
        for (_, text) in host.wakes { #expect(!text.contains("SENTINEL"), "the token never reaches a wake") }
        service.shutdown()
    }

    @Test func relaunchDoesNotRepeatAWake() async throws {
        let store = try ProjectionStore(location: .inMemory)
        do {
            let (service, clock, host, transport) = try await make(store: store)
            GitLabFixtures.install(transport, mr: GitLabFixtures.mr())
            try await service.setWatching(GitLabFixtures.ref, for: thread, true)
            await service.waitForFetches()
            await service.pollDue()
            GitLabFixtures.install(transport, mr: GitLabFixtures.mr(pipelineStatus: "success"))
            clock.advance(by: 120)
            await service.pollDue()
            #expect(host.wakes.count == 1)
            service.shutdown()
        }
        let (service, _, host, transport) = try await make(store: store)
        GitLabFixtures.install(transport, mr: GitLabFixtures.mr(pipelineStatus: "success"))
        await service.pollDue()
        #expect(host.wakes.isEmpty, "the baseline was persisted")
        service.shutdown()
    }

    @Test func settledAbsorbsAndArchivedIsNotPolled() async throws {
        let (service, clock, host, transport) = try await make()
        GitLabFixtures.install(transport, mr: GitLabFixtures.mr())
        try await service.setWatching(GitLabFixtures.ref, for: thread, true)
        await service.waitForFetches()
        await service.pollDue()
        host.pauses[thread] = .settled
        GitLabFixtures.install(transport, mr: GitLabFixtures.mr(pipelineStatus: "success"))
        clock.advance(by: 120)
        await service.pollDue()
        #expect(host.wakes.isEmpty)
        host.pauses[thread] = MergeRequestPause.none
        clock.advance(by: 120)
        await service.pollDue()
        #expect(host.wakes.isEmpty, "unsettling does not replay absorbed events")
        host.pauses[thread] = .archived
        let before = transport.requests.count
        clock.advance(by: 120)
        await service.pollDue()
        #expect(transport.requests.count == before)
        service.shutdown()
    }

    @Test func rateLimitWaitsForRetryAfterAndFailuresBackOff() async throws {
        let (service, clock, host, transport) = try await make()
        defer { withExtendedLifetime(host) {} }
        transport.set("\(GitLabFixtures.api)/merge_requests/42", [ForgeResponse(status: 429, headers: ["Retry-After": "600"])])
        try await service.setWatching(GitLabFixtures.ref, for: thread, true)
        await service.waitForFetches()
        var now = clock.now()
        await service.pollDue()
        #expect(service.nextPollDate(thread, GitLabFixtures.ref.url)?.timeIntervalSince(now) == 600)
        transport.set("\(GitLabFixtures.api)/merge_requests/42", [ForgeResponse(status: 599)])
        var gaps: [TimeInterval] = []
        for _ in 0..<MergeRequestService.maxFailures {
            clock.advance(to: service.nextPollDate(thread, GitLabFixtures.ref.url) ?? clock.now())
            now = clock.now()
            await service.pollDue()
            guard let next = service.nextPollDate(thread, GitLabFixtures.ref.url) else { break }
            gaps.append(next.timeIntervalSince(now))
        }
        #expect(gaps.prefix(3) == [1_200, 1_800, 1_800])
        #expect(service.watch(thread, GitLabFixtures.ref.url)?.stoppedReason?.contains("could not be reached") == true)
        service.shutdown()
    }

    @Test func invalidTokenHoldsTheWatchUntilReplaced() async throws {
        let (service, clock, host, transport) = try await make()
        transport.set("\(GitLabFixtures.api)/merge_requests/42", [ForgeResponse(status: 401)])
        try await service.setWatching(GitLabFixtures.ref, for: thread, true)
        await service.waitForFetches()
        await service.pollDue()
        #expect(service.instanceProblems[GitLabFixtures.instance.baseURL]?.contains("invalid or expired") == true)
        #expect(service.watch(thread, GitLabFixtures.ref.url)?.stoppedReason == nil, "held, not stopped")
        #expect((service.nextPollDate(thread, GitLabFixtures.ref.url)?.timeIntervalSince(clock.now()) ?? 0) >= 1_800)
        GitLabFixtures.install(transport, mr: GitLabFixtures.mr())
        _ = try await service.saveInstance(baseURL: GitLabFixtures.instance.baseURL, token: SecretValue("glpat-NEW"))
        #expect(service.instanceProblems.isEmpty)
        #expect(service.nextPollDate(thread, GitLabFixtures.ref.url) == clock.now(), "re-armed at once")
        await service.pollDue()
        #expect(service.watch(thread, GitLabFixtures.ref.url)?.baseline != nil)
        #expect(host.wakes.isEmpty)
        service.shutdown()
    }

    @Test func resolvesBangIIDAndAutoLinks() async throws {
        let (service, _, host, transport) = try await make()
        #expect(try await service.resolve("!42", for: thread) == GitLabFixtures.ref)
        await #expect(throws: ExtrasError.self) { try await service.resolve("https://elsewhere.test/a/b/-/merge_requests/1", for: thread) }
        GitLabFixtures.install(transport, mr: GitLabFixtures.mr())
        await service.noticeCommand(partID: "p1", sessionID: thread, command: "git status", output: GitLabFixtures.ref.url)
        #expect(host.links[thread] == nil, "only git push output links")
        await service.noticeCommand(partID: "p2", sessionID: thread, command: "git push -u origin feat/checklist", output: "remote: View merge request for feat/checklist:\nremote:   \(GitLabFixtures.ref.url)\n")
        #expect(host.links[thread]?.map(\.source) == [.output])
        let other = SessionID("ses_branch")
        transport.setJSON("\(GitLabFixtures.api)/merge_requests?state=opened&source_branch=feat%2Fchecklist&per_page=20", #"[{"iid":42}]"#)
        await service.autoLinkBranch(other)
        #expect(host.links[other]?.map(\.ref) == [GitLabFixtures.ref])
        #expect(host.links[other]?.first?.source == .branch)
    }

    @Test func instancesPersistAndTokensStayInTheVault() async throws {
        let store = try ProjectionStore(location: .inMemory)
        let tokens = InMemorySecretVault()
        let (service, _, host, transport) = try await make(store: store, tokens: tokens)
        defer { withExtendedLifetime(host) {} }
        transport.setJSON("\(GitLabFixtures.instance.apiBase)/user", #"{"username":"mara"}"#)
        _ = try await service.saveInstance(baseURL: "https://code.corp.test/gitlab/", token: SecretValue("glpat-SENTINEL-VALUE"))
        #expect(service.instancesWithToken == [GitLabFixtures.instance.baseURL])
        #expect(try await service.testConnection(GitLabFixtures.instance).get() == "mara")
        let saved = try await store.preference(MergeRequestService.instancesKey, as: [String].self)
        #expect(saved == [GitLabFixtures.instance.baseURL])
        let dump = try await store.writer.read { db in try String.fetchAll(db, sql: "SELECT CAST(json AS TEXT) FROM app_preference").joined() }
        #expect(!dump.contains("SENTINEL"), "the token is never in the store")
        await service.removeInstance(GitLabFixtures.instance)
        #expect(tokens.count == 0)
        await #expect(throws: ExtrasError.self) { _ = try await service.saveInstance(baseURL: "not a url", token: nil) }
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
        let gitLab: FixtureForgeTransport

        static func start() async throws -> Fixture {
            let harness = try await MockHarness.start(.empty(directory: "/tmp/mock-extras"))
            var configuration = EngineConfiguration(server: .fixed(harness.connection), store: .inMemory)
            configuration.eventBackoff = BackoffPolicy(initial: .milliseconds(20), maximum: .milliseconds(200))
            configuration.writeInterval = .milliseconds(20)
            let vault = InMemorySecretVault()
            let gitLab = FixtureForgeTransport()
            configuration.secretVault = vault
            configuration.forgeTransport = gitLab
            configuration.forgeTokens = GitLabFixtures.tokens()
            configuration.wallClock = ManualWallClock(Date(timeIntervalSince1970: 1_800_000_000))
            let engine = try Engine(configuration: configuration)
            await engine.start()
            try await waitUntil("live") { engine.root.connection == .live }
            return Fixture(harness: harness, engine: engine, vault: vault, gitLab: gitLab)
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

    @Test func linkMergeRequestsWritesSessionMetadata() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        let engine = fixture.engine
        _ = try await engine.extras.mergeRequests.saveInstance(baseURL: GitLabFixtures.instance.baseURL, token: nil)
        GitLabFixtures.install(fixture.gitLab, mr: GitLabFixtures.mr(pipelineStatus: "success"), jobs: GitLabFixtures.jobs([("unit", "success")]))
        let session = try await engine.createThread(in: "/tmp/mock-extras", title: "mr")
        try await waitUntil("graph") { engine.orchestration.node(session.id) != nil }
        let linked = await fixture.call("link_merge_requests", ["refs": .array([.string(GitLabFixtures.ref.url)])], session: session.id)
        #expect(!linked.isError, "\(linked.text)")
        let stored = try await fixture.harness.client.session(session.id.rawValue)
        #expect(String(describing: stored.metadata ?? .null).contains("bellocode_mrs"))
        let list = await fixture.call("list_thread_merge_requests", [:], session: session.id)
        #expect(list.text.contains("Add launch checklist") && list.text.contains("Pipeline passed"), "\(list.text)")
        #expect(!list.text.contains("SENTINEL"), "the token never reaches a tool result")
        let unknown = await fixture.call("link_merge_requests", ["refs": .array(["https://github.com/a/b/pull/1"])], session: session.id)
        #expect(unknown.isError)
        // The wake path posts a labelled synthetic message through the mock.
        try await engine.extras.wake(session.id, text: "[BelloCode MR watch] platform/rocket!42: Pipeline #900 finished.", url: GitLabFixtures.ref.url)
        #expect((await fixture.harness.server.syntheticTexts).last?.hasPrefix("[BelloCode MR watch]") == true)
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
