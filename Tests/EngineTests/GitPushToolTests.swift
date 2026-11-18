import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// The agent push tool (docs/features/git-parity.md row 28) end to end: engine + mock opencode + fake GitLab API on
/// the same origin as a real HTTPS git server, with the app's credential helper. Cards show remote, branch and
/// commits; protected and default branches warn; a force push needs its own card; the token never reaches the agent.
@Suite(.timeLimit(.minutes(3)), .serialized)
@MainActor
struct GitPushToolTests {
    @MainActor struct Fixture {
        let harness: MockHarness
        let engine: Engine
        let setup: GitCredentialTests.Setup
        let fake: FakeGitLabServer

        static func start() async throws -> Fixture {
            let helper = try #require(HostGitIsolationTests.helper, "bellocode-exec is not built")
            let setup = try await GitCredentialTests.setup()
            try await setup.repo.git("switch", "-q", "-c", "feat/x")
            try setup.repo.write("x.txt", "x\n")
            try await setup.repo.git("add", "-A")
            try await setup.repo.git("commit", "-q", "-m", "Add x")
            let fake = FakeGitLabServer(instance: setup.instance, token: GitCredentialTests.token)
            var project = FakeGitLabServer.Project(id: 9, path: "group/project")
            project.branches = ["main", "feat/x"]
            project.protectedBranches = ["main"]
            fake.put(project)
            let harness = try await MockHarness.start(.empty(directory: setup.repo.path))
            var configuration = EngineConfiguration(server: .fixed(harness.connection), store: .inMemory)
            configuration.eventBackoff = BackoffPolicy(initial: .milliseconds(20), maximum: .milliseconds(200))
            configuration.secretVault = InMemorySecretVault()
            configuration.forgeTransport = fake
            let vault = InMemorySecretVault()
            try vault.store(account: setup.instance.baseURL, label: "t", value: SecretValue(GitCredentialTests.token))
            configuration.forgeTokens = vault
            configuration.gitCredentialHelper = URL(filePath: helper)
            let engine = try Engine(configuration: configuration)
            await engine.start()
            try await waitUntil("live") { engine.root.connection == .live }
            engine.git.replaceRunner(setup.runner)
            _ = try await engine.extras.mergeRequests.saveInstance(baseURL: setup.instance.baseURL, token: nil)
            return Fixture(harness: harness, engine: engine, setup: setup, fake: fake)
        }

        func stop() async {
            await engine.stop()
            await harness.stop()
            setup.cleanup()
        }

        func thread(_ mode: PermissionMode? = nil) async throws -> SessionID {
            let session = try await engine.createThread(in: setup.repo.path, title: "push", agent: nil, model: nil, permissionMode: mode)
            try await waitUntil("graph") { engine.orchestration.node(session.id) != nil }
            return session.id
        }

        func push(_ session: SessionID, force: Bool = false) async -> ClientMCPResult {
            await engine.orchestration.handleAppTool(ClientMCPCall(
                tool: GitPushTool.push, arguments: .object(["force": .bool(force)]), sessionID: session.rawValue, directory: setup.repo.path))
        }

        func cards(_ action: AppApproval.Action) async -> [(AppRequest, AppApproval)] {
            await engine.core.appRequests().compactMap { request in
                if case .approval(let approval) = request.kind, approval.action == action { (request, approval) } else { nil }
            }
        }
    }

    @Test func pushNeedsACardShowingRemoteBranchAndCommitsThenPushesWithTheToken() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        let session = try await fixture.thread()
        let result = await fixture.push(session)
        #expect(result.text.contains("Asked the user"))
        let (request, approval) = try #require(await fixture.cards(.gitPush).first)
        #expect(approval.detail.contains("Remote: \(fixture.setup.remote)") && approval.detail.contains("Branch: feat/x → origin/feat/x"))
        #expect(approval.detail.contains("Add x") && approval.detail.contains("Force: no") && !approval.allowsAlways)
        #expect(!fixture.setup.server.recorded().contains { $0.path.hasSuffix("git-receive-pack") })
        try await fixture.engine.extras.respond(to: request.id, .approve(always: false))
        let wake = await fixture.harness.server.syntheticTexts.last ?? ""
        #expect(wake.contains("Pushed feat/x"), "\(wake)")
        #expect(fixture.setup.server.recorded().contains { $0.authorized && $0.path.hasSuffix("git-receive-pack") })
        // The token appears in no tool result, card or wake.
        let texts = [result.text, approval.detail] + (await fixture.harness.server.syntheticTexts)
        #expect(!texts.joined().contains(GitCredentialTests.token))
    }

    @Test func protectedDefaultBranchWarnsEvenInFullAccessAndDeclineSendsNothing() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        try await fixture.setup.repo.git("switch", "-q", "main")
        try fixture.setup.repo.write("m.txt", "m\n")
        try await fixture.setup.repo.git("add", "-A")
        try await fixture.setup.repo.git("commit", "-q", "-m", "On main")
        let session = try await fixture.thread(.fullAccess)
        _ = await fixture.push(session)
        let (request, approval) = try #require(await fixture.cards(.gitPush).first)
        #expect(approval.detail.contains("protected branch on GitLab"))
        try await fixture.engine.extras.respond(to: request.id, .decline)
        let wake = await fixture.harness.server.syntheticTexts.last ?? ""
        #expect(wake.contains("declined"), "\(wake)")
        #expect(!fixture.setup.server.recorded().contains { $0.path.hasSuffix("git-receive-pack") && $0.authorized })
    }

    @Test func fullAccessPushesAFeatureBranchAtOnceButForceAlwaysNeedsItsOwnCard() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.stop() } }
        let session = try await fixture.thread(.fullAccess)
        let first = await fixture.push(session)
        #expect(first.text.contains("Pushed feat/x"), "\(first.text)")
        // Rewrite history: an ordinary push is refused with an explanation, never forced silently.
        try await fixture.setup.repo.git("commit", "-q", "--amend", "-m", "Add x, amended")
        let refused = await fixture.push(session)
        #expect(refused.text.contains("force: true"))
        #expect(await fixture.cards(.gitForcePush).isEmpty)
        let asked = await fixture.push(session, force: true)
        #expect(asked.text.contains("Asked the user"))
        let (request, approval) = try #require(await fixture.cards(.gitForcePush).first)
        #expect(approval.title.contains("Force push") && approval.detail.contains("Force: YES"))
        try await fixture.engine.extras.respond(to: request.id, .approve(always: false))
        let wake = await fixture.harness.server.syntheticTexts.last ?? ""
        #expect(wake.contains("force-with-lease"), "\(wake)")
    }
}
