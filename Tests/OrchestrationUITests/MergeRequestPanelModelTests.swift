import BelloCore
import Engine
import Foundation
import Testing

@testable import OrchestrationUI

@MainActor
final class PanelHost: MergeRequestHost {
    var links: [SessionID: [LinkedMergeRequest]] = [:]
    func allSessions() async -> [Session] { [] }
    func writeLinks(_ sessionID: SessionID, _ transform: @escaping @Sendable ([LinkedMergeRequest]) -> [LinkedMergeRequest]) async throws -> [LinkedMergeRequest] {
        let updated = transform(links[sessionID] ?? [])
        links[sessionID] = updated
        return updated
    }
    func wake(_ sessionID: SessionID, text: String, url: String) async throws {}
    func pause(_ sessionID: SessionID) -> MergeRequestPause { .none }
    func checkout(of sessionID: SessionID) async -> (remote: String, branch: String)? { ("git@gitlab.corp.test:team/app.git", "feat/parser") }
}

@Suite(.timeLimit(.minutes(3)))
@MainActor
struct MergeRequestPanelModelTests {
    static let instance = GitLabInstance(baseURL: "https://gitlab.corp.test")!
    static let token = "glpat-PANEL-TOKEN-SENTINEL-01234567"
    static let ref = MergeRequestRef(instance: instance.baseURL, projectPath: "team/app", iid: 5)
    let thread = SessionID("ses_panel")

    func make() async throws -> (MergeRequestPanelModel, FakeGitLabServer, PanelHost) {
        let server = FakeGitLabServer(instance: Self.instance, token: Self.token)
        var project = FakeGitLabServer.Project(id: 3, path: "team/app")
        project.branches = ["main", "feat/parser"]
        project.members = [GitLabUserRef(id: 21, username: "mara", name: "Mara")]
        var mr = FakeGitLabServer.MR(iid: 5, title: "Parser", source: "feat/parser")
        mr.pipelineID = 70
        mr.pipelineStatus = "failed"
        project.mrs[5] = mr
        project.jobs[70] = [
            .init(id: 701, name: "unit", stage: "test", status: "failed"), .init(id: 702, name: "deploy", stage: "deploy", status: "manual"),
        ]
        project.traces[701] = "\u{1B}[32mok\u{1B}[0m\nerror: expected 4\napi_key = sk-live-abcdefgh\nfinal line"
        server.put(project)
        let vault = InMemorySecretVault()
        try vault.store(account: Self.instance.baseURL, label: "t", value: SecretValue(Self.token))
        let service = MergeRequestService(
            store: try ProjectionStore(location: .inMemory), clock: ManualWallClock(Date(timeIntervalSince1970: 1_800_000_000)), transport: server,
            tokens: vault, autoPoll: false)
        let host = PanelHost()
        service.host = host
        await service.start()
        _ = try await service.saveInstance(baseURL: Self.instance.baseURL, token: nil)
        try await service.link([Self.ref], to: thread, source: .user)
        await service.waitForFetches()
        let model = MergeRequestPanelModel(service: service)
        model.display(thread)
        return (model, server, host)
    }

    @Test func logOpensParsedAndTriageGoesToTheComposerQuoted() async throws {
        let (model, _, _) = try await make()
        let snapshot = try #require(model.service.snapshots[Self.ref.url])
        let job = try #require(snapshot.pipeline?.failedJobs.first)
        model.showLog(Self.ref, job)
        await model.loadLog()
        guard case .loaded(let parsed, _, _) = model.log else {
            Issue.record("log not loaded: \(model.log)")
            return
        }
        #expect(parsed.lines.first?.spans.first?.colour == 2)
        var inserted: String?
        model.composerTarget = { ComposerTarget { inserted = $0; return true } }
        await model.sendToAgent(Self.ref, job)
        let text = try #require(inserted)
        #expect(text.contains(UntrustedText.beginMarker))
        #expect(text.contains("error: expected 4"))
        #expect(!text.contains("sk-live-abcdefgh"), "redacted")
        #expect(!text.contains(Self.token))
        #expect(text.contains("unit"))
    }

    /// Two GitLab installations behind one transport, routed by API base.
    struct TwoInstances: ForgeTransport {
        let servers: [FakeGitLabServer]
        func send(_ request: ForgeRequest) async throws -> ForgeResponse {
            guard let server = servers.first(where: { request.url.absoluteString.hasPrefix($0.instance.apiBase + "/") }) else {
                throw ForgeError.network("no such instance")
            }
            return try await server.send(request)
        }
    }

    /// AV2-01 and AV2-05: job 701 exists on two installations (job IDs are numbered per installation). After the
    /// excerpt of A's private failure was shown, Send to Agent for B's job 701 reads and redacts B's log and inserts
    /// that, never A's. And a job name and stage chosen in a contributor's `.gitlab-ci.yml` that carry the instance's
    /// token reach the composer redacted, as the log does.
    @Test func excerptsAreKeyedByInstallationAndEveryFieldIsRedacted() async throws {
        let other = GitLabInstance(baseURL: "https://gitlab.other.test")!
        let otherToken = "corp9-OTHER-INSTALLATION-TOKEN-7654321"
        func server(_ instance: GitLabInstance, _ token: String, job: FakeGitLabServer.Job, trace: String) -> FakeGitLabServer {
            let server = FakeGitLabServer(instance: instance, token: token)
            var project = FakeGitLabServer.Project(id: 3, path: "team/app")
            var mr = FakeGitLabServer.MR(iid: 5, title: "Parser", source: "feat/parser")
            mr.pipelineID = 70
            mr.pipelineStatus = "failed"
            project.mrs[5] = mr
            project.jobs[70] = [job]
            project.traces[701] = trace
            server.put(project)
            return server
        }
        let a = server(Self.instance, Self.token, job: .init(id: 701, name: "unit \(Self.token)", stage: "test-\(Self.token)", status: "failed"),
                       trace: "error: A-PRIVATE-FAILURE\nfinal line")
        let b = server(other, otherToken, job: .init(id: 701, name: "unit", stage: "test", status: "failed"), trace: "error: B-FAILURE\nfinal line")
        let vault = InMemorySecretVault()
        try vault.store(account: Self.instance.baseURL, label: "a", value: SecretValue(Self.token))
        try vault.store(account: other.baseURL, label: "b", value: SecretValue(otherToken))
        let service = MergeRequestService(
            store: try ProjectionStore(location: .inMemory), clock: ManualWallClock(Date(timeIntervalSince1970: 1_800_000_000)),
            transport: TwoInstances(servers: [a, b]), tokens: vault, autoPoll: false)
        let host = PanelHost()
        service.host = host
        await service.start()
        _ = try await service.saveInstance(baseURL: Self.instance.baseURL, token: nil)
        _ = try await service.saveInstance(baseURL: other.baseURL, token: nil)
        let refB = MergeRequestRef(instance: other.baseURL, projectPath: "team/app", iid: 5)
        let threadB = SessionID("ses_panel_b")
        try await service.link([Self.ref], to: thread, source: .user)
        try await service.link([refB], to: threadB, source: .user)
        await service.waitForFetches()
        let model = MergeRequestPanelModel(service: service)
        var inserted: String?
        model.composerTarget = { ComposerTarget { inserted = $0; return true } }

        model.display(thread)
        let jobA = try #require(service.snapshots[Self.ref.url]?.pipeline?.failedJobs.first)
        await model.loadExcerpt(Self.ref, jobA)
        #expect(model.excerpt(Self.ref, jobA)?.text.contains("A-PRIVATE-FAILURE") == true)
        await model.sendToAgent(Self.ref, jobA)
        let textA = try #require(inserted)
        #expect(!textA.contains(Self.token), "the job name and stage are redacted too")
        #expect(textA.contains("A-PRIVATE-FAILURE"))

        model.display(threadB)
        let jobB = try #require(service.snapshots[refB.url]?.pipeline?.failedJobs.first)
        #expect(jobB.id == jobA.id)
        #expect(model.excerpt(refB, jobB) == nil, "A's excerpt is not B's")
        inserted = nil
        await model.sendToAgent(refB, jobB)
        let textB = try #require(inserted)
        #expect(textB.contains("B-FAILURE"))
        #expect(!textB.contains("A-PRIVATE-FAILURE"), "never the other installation's log")
        #expect(b.requests.contains { $0.path.contains("jobs/701/trace") }, "B's log was read")
    }

    @Test func writesAreOffByDefaultAndManualJobsAskFirst() async throws {
        let (model, server, _) = try await make()
        let snapshot = try #require(model.service.snapshots[Self.ref.url])
        let failed = try #require(snapshot.pipeline?.jobs.first { $0.name == "unit" })
        await model.retry(Self.ref, failed)
        #expect(model.message?.contains("write actions are off") == true)
        #expect(!server.requests.contains { $0.method == "POST" })
        await model.service.setSettings(GitLabInstanceSettings(writesEnabled: true), for: Self.instance.baseURL)
        await model.retry(Self.ref, failed)
        #expect(server.requests.contains { $0.method == "POST" && $0.path.hasSuffix("jobs/701/retry") })
        let manual = try #require(snapshot.pipeline?.jobs.first { $0.isManual })
        var asked = 0
        model.confirm = { _, _, _ in asked += 1; return false }
        await model.play(Self.ref, manual)
        #expect(asked == 1)
        #expect(!server.requests.contains { $0.path.hasSuffix("/play") }, "declined: nothing sent")
        // Approve and merge stay hidden and refused until their own switch is on.
        await model.approve(snapshot)
        #expect(model.message?.contains("Approve and Merge are off") == true)
    }

    @Test func createFormPreviewsExactlyWhatItSendsAndLinks() async throws {
        let (model, server, host) = try await make()
        await model.service.setSettings(GitLabInstanceSettings(writesEnabled: true), for: Self.instance.baseURL)
        server.editMR("team/app", 5) { $0.state = "merged" }  // the branch's earlier MR is done
        var pushed = false
        model.makeCreateContext = { id in
            CreateMergeRequestContext(
                sessionID: id, directory: "/tmp/x",
                checkout: { CheckoutState(branch: "feat/parser", remote: "git@gitlab.corp.test:team/app.git", upstream: pushed ? "origin/feat/parser" : nil, ahead: pushed ? 0 : 2) },
                push: { pushed = true }, commits: { _ in ["Add precedence climbing", "Fix associativity"] },
                generate: { _ in "Parser: precedence climbing\n\nRewrites the expression parser." })
        }
        model.openCreate()
        let form = try #require(model.create)
        await form.prepare()
        #expect(form.title == "Parser: precedence climbing")
        #expect(form.proposalSource.contains("model"))
        #expect(form.target == "main")
        #expect(form.blocker?.contains("Push") == true)
        await form.push()
        form.draft = true
        form.reviewerQuery = "mara"
        await form.addPerson(reviewer: true)
        #expect(form.reviewers.map(\.id) == [21])
        #expect(form.blocker == nil)
        let preview = form.mergeDraft.payloadText
        #expect(preview.contains("\"title\" : \"Draft: Parser: precedence climbing\""))
        #expect(preview.contains("\"reviewer_ids\""))
        await form.create()
        let post = try #require(server.requests.last { $0.method == "POST" && $0.path.hasSuffix("merge_requests") })
        let sent = try JSONSerialization.jsonObject(with: Data((post.body ?? "").utf8)) as? NSDictionary
        let shown = try JSONSerialization.jsonObject(with: Data(preview.utf8)) as? NSDictionary
        #expect(sent == shown, "the preview is exactly the payload")
        #expect(model.create == nil)
        #expect(host.links[thread]?.contains { $0.ref.iid == 6 } == true, "linked after GitLab acknowledged it")
    }
}

@Suite
struct MergeRequestChipTests {
    @Test func chipsCarryGlyphWordsApprovalsAndDraft() {
        let ref = MergeRequestRef(instance: "https://g.test", projectPath: "a/b", iid: 42)
        let link = LinkedMergeRequest(ref: ref, source: .user, linked: .now)
        var snapshot = MergeRequestSnapshot(
            ref: ref, title: "T", state: .opened, draft: true, pipeline: Pipeline(id: 1, status: "failed", jobs: [PipelineJob(id: 1, name: "u", status: "failed")]),
            approvals: MergeRequestApprovals(approved: false, required: 2, left: 1, approvedBy: ["mara"]), fetched: .now)
        #expect(MergeRequestText.chip(link, snapshot) == "!42 Draft · ✕ Pipeline failed (1 job) · 1/2 approvals")
        #expect(MergeRequestText.compact(link, snapshot) == "!42 Draft ✕ 1/2")
        snapshot.state = .merged
        #expect(MergeRequestText.compact(link, snapshot) == "!42 Merged")
        #expect(MergeRequestText.chip(link, nil) == "!42")
    }
}
