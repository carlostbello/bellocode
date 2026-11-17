import BelloCore
import Darwin
import Foundation
import Synchronization
import Testing

@testable import Engine
@testable import OpenCodeKit

/// M3-B against the pinned opencode with the bellocode plugin and the app tools (client MCP). Opt-in:
/// `BELLOCODE_EXTRAS_REAL=1 swift test --filter ExtrasRealBinary`. Seven short model runs in total on the zero-cost
/// default model; HOME and XDG directories in a fresh temporary directory (never the user's opencode data); an
/// in-memory secret vault (never the Keychain) and recorded GitLab answers (no forge traffic); every process stopped.
@Suite(
    "Extras real binary", .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["BELLOCODE_EXTRAS_REAL"] == "1" && EngineRepo.vendoredOpencode != nil,
        "set BELLOCODE_EXTRAS_REAL=1 and run Scripts/fetch-opencode.sh"))
@MainActor
struct ExtrasRealBinaryTests {
    @MainActor struct Sandbox {
        let root: URL
        let project: URL
        let supervisor: ServerSupervisor
        let engine: Engine
        let vault: InMemorySecretVault
        let gitLab: FixtureForgeTransport
        let renderer: FakeRenderer
        let events: EventRecorder

        static func start(_ name: String) async throws -> Sandbox {
            let executable = try #require(EngineRepo.vendoredOpencode)
            let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-extras-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
            let project = root.appending(path: "project", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try "extras sandbox\n".write(to: project.appending(path: "README.md"), atomically: true, encoding: .utf8)
            let supervisor = ServerSupervisor(
                configuration: ServerConfiguration(
                    executableURL: executable, dataRoot: root.appending(path: "server", directoryHint: .isDirectory),
                    expectedVersion: EngineRepo.pinnedVersion, pluginDirectory: OrchestrationRealBinaryTests.pluginDirectory))
            var configuration = EngineConfiguration(server: .supervised(supervisor), store: .inMemory)
            configuration.defaultDirectory = project.path
            let vault = InMemorySecretVault()
            let gitLab = FixtureForgeTransport()
            configuration.secretVault = vault
            configuration.forgeTransport = gitLab
            configuration.forgeTokens = GitLabFixtures.tokens()
            configuration.visualsDirectory = root.appending(path: "visuals", directoryHint: .isDirectory)
            configuration.mergeRequestPoll = .seconds(3)
            let engine = try Engine(configuration: configuration)
            let renderer = FakeRenderer()
            engine.extras.visuals.renderer = renderer
            await engine.start()
            await engine.addProject(directory: project.path)
            try await waitUntil("live", timeout: .seconds(30)) { engine.root.connection == .live }
            let client = try await engine.core.currentClient()
            let events = EventRecorder()
            events.start(client.connection)
            _ = try await engine.extras.mergeRequests.saveInstance(baseURL: GitLabFixtures.instance.baseURL, token: nil)
            await engine.orchestration.hostAppTools(directories: [project.path])
            return Sandbox(root: root, project: project, supervisor: supervisor, engine: engine, vault: vault, gitLab: gitLab, renderer: renderer, events: events)
        }

        func client() async throws -> OpenCodeClient { try await engine.core.currentClient() }

        func stop() async {
            events.stop()
            let pid = await supervisor.childPID
            await engine.stop()
            if let pid { #expect(kill(pid, 0) != 0, "server child \(pid) still running") }
            try? FileManager.default.removeItem(at: root)
        }

        /// The app tools the server sees for the project (plugin RPC `bellocode.info` → `appTools`).
        func appTools() async throws -> [(id: String, codemode: Bool)] {
            let output = try await client().pluginRPC(OrchestrationContract.rpcID, "info", input: .object([:]), directory: project.path)
            guard case .array(let items) = output["appTools"] ?? .null else { return [] }
            return items.compactMap { item in item["id"]?.stringValue.map { ($0, item["codemode"]?.boolValue ?? true) } }
        }

        /// Waits until every app tool is attached for the project (the client-MCP socket is up) and called directly.
        func appToolsReady() async throws {
            var tools: [(id: String, codemode: Bool)] = []
            for _ in 0..<100 {
                tools = (try? await appTools()) ?? []
                if tools.count >= AppTools.definitions.count + ExtrasTools.all.count, tools.allSatisfy({ !$0.codemode }) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            print("M3-B real: app tools \(tools.count): \(tools.map { "\($0.id)\($0.codemode ? " (code mode)" : "")" }.joined(separator: ", "))")
            #expect(Set(tools.map(\.id)).isSuperset(of: ExtrasTools.all.map { OrchestrationService.appServerName + "_" + $0 }))
            #expect(tools.allSatisfy { !$0.codemode }, "app tools are called directly, not through Code Mode")
        }

        func messageText(_ id: SessionID) async throws -> String {
            let page = try await client().messages(sessionID: id.rawValue, MessageListQuery(limit: 200))
            return page.data.map { String(describing: $0) }.joined(separator: "\n")
        }

        /// Every file opencode wrote in the sandbox (its database included), as text.
        func serverFilesContain(_ needle: String) -> Bool {
            guard let enumerator = FileManager.default.enumerator(at: root.appending(path: "server"), includingPropertiesForKeys: nil) else { return false }
            for case let url as URL in enumerator {
                guard let data = try? Data(contentsOf: url), data.count < 64 << 20 else { continue }
                if data.range(of: Data(needle.utf8)) != nil { return true }
            }
            return false
        }
    }

    /// Records the raw event stream (bounded) to prove a value never travels on it.
    final class EventRecorder: Sendable {
        private let state = Mutex<(text: String, task: Task<Void, Never>?)>(("", nil))

        static func authorization(_ connection: ServerConnection) -> String {
            "Basic " + Data("\(ServerCredentials.username):\(connection.credentials.password)".utf8).base64EncodedString()
        }

        func start(_ connection: ServerConnection) {
            let task = Task { [weak self] in
                var request = URLRequest(url: connection.baseURL.appending(path: "api/event"))
                request.setValue(Self.authorization(connection), forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 600
                guard let (bytes, _) = try? await URLSession.shared.bytes(for: request) else { return }
                do {
                    for try await line in bytes.lines {
                        self?.state.withLock { if $0.text.count < 8 << 20 { $0.text += line + "\n" } }
                    }
                } catch {}
            }
            state.withLock { $0.task = task }
        }

        func stop() { state.withLock { $0.task?.cancel() } }
        var text: String { state.withLock { $0.text } }
    }

    /// Polls an async condition (bounded).
    func eventually(_ message: String, timeout: Duration, _ condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            guard clock.now < deadline else {
                Issue.record("timed out waiting for \(message)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// No model run: the app tools attach for the project and are exposed directly (not inside Code Mode).
    @Test func appToolsAttachOutsideCodeMode() async throws {
        let sandbox = try await Sandbox.start("attach")
        defer { Task { await sandbox.stop() } }
        try await sandbox.appToolsReady()
    }

    @Test func appToolsAreRegisteredAndASecretNeverReachesTheModel() async throws {
        let sandbox = try await Sandbox.start("secret")
        defer { Task { await sandbox.stop() } }
        try await sandbox.appToolsReady()
        let engine = sandbox.engine
        let thread = try await engine.createThread(in: sandbox.project.path, title: "secret")
        try await waitUntil("graph") { engine.orchestration.node(thread.id) != nil }
        // Run 1: the agent asks.
        _ = try await engine.send(
            "Call the tool bellocode_app_request_secret exactly once with label \"probe token\" and reason \"testing\". Then end your turn with: ASKED",
            to: thread.id)
        try await eventually("secret card", timeout: .seconds(120)) { !(await engine.extras.pendingAppRequests()).isEmpty }
        try await waitUntil("turn ended", timeout: .seconds(120)) { engine.orchestration.node(thread.id)?.node.ownStatus != .running }
        let request = try #require(await engine.extras.pendingAppRequests().first)
        let sentinel = "zzSENTINEL\(UUID().uuidString.prefix(12))"
        // Run 2: the save wakes the thread with a reference.
        try await engine.extras.respond(to: request.id, .saveSecret(SecretValue(sentinel)))
        try await eventually("wake handled", timeout: .seconds(120)) {
            let text = (try? await sandbox.messageText(thread.id)) ?? ""
            return text.contains("[BelloCode secret]") && engine.orchestration.node(thread.id)?.node.ownStatus != .running
                && text.components(separatedBy: "assistant").count > 2
        }
        try await waitUntil("wake run done", timeout: .seconds(120)) { engine.orchestration.node(thread.id)?.node.ownStatus != .running }
        let afterWake = try await sandbox.messageText(thread.id)
        let reference = try #require(afterWake.components(separatedBy: CharacterSet.alphanumerics.union(["_"]).inverted).first { $0.hasPrefix(SecretService.referencePrefix) })
        // Run 3: the agent turns the reference into a one-read path and uses it in one command.
        _ = try await engine.send(
            "Call bellocode_app_secret_file with secretRef \(reference). Then run exactly this shell command, with PATH replaced by the path it returned: wc -c < PATH . Reply with only the number it printed.",
            to: thread.id)
        try await waitUntil("command started", timeout: .seconds(60)) { engine.orchestration.node(thread.id)?.node.ownStatus == .running }
        try await waitUntil("command ran", timeout: .seconds(180)) { engine.orchestration.node(thread.id)?.node.ownStatus != .running }
        let transcript = try await sandbox.messageText(thread.id)
        print("M3-B real: reference \(reference.prefix(14))…; transcript has wc count \(transcript.contains("\(sentinel.utf8.count)")); synthetic present \(transcript.contains("[BelloCode secret]"))")
        #expect(transcript.contains("[BelloCode secret]"), "the wake is a labelled synthetic message")
        #expect(transcript.contains("\(sentinel.utf8.count)"), "the one command read the value through the pipe")
        #expect(!transcript.contains(sentinel), "the value is not in the session's messages (the model's context)")
        #expect(!sandbox.events.text.contains(sentinel), "the value is not on the event stream")
        await engine.flush()
        #expect(!sandbox.serverFilesContain(sentinel), "opencode stored no copy")
        #expect(sandbox.vault.count == 1)
    }

    @Test func scheduleLinkAndVisualHappyPaths() async throws {
        let sandbox = try await Sandbox.start("tools")
        defer { Task { await sandbox.stop() } }
        try await sandbox.appToolsReady()
        let engine = sandbox.engine
        let thread = try await engine.createThread(in: sandbox.project.path, title: "tools")
        try await waitUntil("graph") { engine.orchestration.node(thread.id) != nil }
        let ref = GitLabFixtures.ref
        GitLabFixtures.install(sandbox.gitLab, mr: GitLabFixtures.mr(pipelineStatus: "success"))
        // Run 4: three app tools in one turn.
        _ = try await engine.send(
            """
            Call these tools once each, in order, then end your turn with: DONE
            1. bellocode_app_schedule_task with name "probe schedule", prompt "Reply with exactly: SCHEDULED-OK", everyMinutes 60.
            2. bellocode_app_link_pull_requests with urls ["\(ref.url)"].
            3. bellocode_app_html_render with title "probe visual" and html "<h1>probe</h1>".
            """, to: thread.id)
        // The session's own run state (an approval card mid-turn is not the end of the turn).
        try await eventually("turn started", timeout: .seconds(60)) { await engine.core.knownSession(thread.id)?.busySince != nil }
        try await eventually("turn ended", timeout: .seconds(180)) { !(await engine.core.knownSession(thread.id)?.isRunning ?? true) }
        try await waitUntil("schedule", timeout: .seconds(10)) { !engine.extras.schedules.tasks.isEmpty }
        let task = try #require(engine.extras.schedules.tasks.first)
        #expect(task.approval == .pending, "the first agent schedule in a project waits for approval")
        #expect(task.createdBy == thread.id)
        // The link travels in the session's metadata on the server, beside the plugin's own key.
        let session = try await sandbox.client().session(thread.id.rawValue)
        let metadata = String(describing: session.metadata ?? .null)
        print("M3-B real: metadata \(metadata.prefix(300))")
        #expect(metadata.contains(LinkedMergeRequest.metadataKey))
        #expect(engine.extras.mergeRequests.links(for: thread.id).map(\.ref) == [ref])
        #expect(sandbox.renderer.requests.contains { $0.html.contains("probe") })
        let transcript = try await sandbox.messageText(thread.id)
        #expect(transcript.contains("bellocode_app_html_render"))
        #expect(transcript.contains("visualID: v_"))
        // Approve, then run it now: run 5 is the scheduled run in a new thread.
        let request = try #require(await engine.extras.pendingAppRequests().first)
        try await engine.extras.respond(to: request.id, .approve(always: false))
        try await engine.extras.schedules.runNow(task.id)
        let run = try #require(engine.extras.schedules.task(task.id)?.lastRun?.sessionID)
        try await eventually("scheduled run", timeout: .seconds(120)) {
            ((try? await sandbox.messageText(run)) ?? "").contains("SCHEDULED-OK") && engine.orchestration.node(run)?.node.ownStatus != .running
        }
        let runText = try await sandbox.messageText(run)
        print("M3-B real: scheduled run thread \(run.rawValue): \(runText.contains("SCHEDULED-OK") ? "replied" : "no reply")")
        #expect(runText.contains("[Scheduled task “probe schedule”]"))
        #expect(runText.contains("SCHEDULED-OK"))
    }

    @Test func watchedMergeRequestWakesTheThreadOnce() async throws {
        let sandbox = try await Sandbox.start("watch")
        defer { Task { await sandbox.stop() } }
        let engine = sandbox.engine
        let thread = try await engine.createThread(in: sandbox.project.path, title: "watch")
        try await waitUntil("graph") { engine.orchestration.node(thread.id) != nil }
        let ref = GitLabFixtures.ref
        GitLabFixtures.install(sandbox.gitLab, mr: GitLabFixtures.mr(), jobs: GitLabFixtures.jobs([("unit", "running")]))
        try await engine.extras.mergeRequests.setWatching(ref, for: thread.id, true)
        await engine.extras.mergeRequests.waitForFetches()
        await engine.extras.mergeRequests.pollDue()
        try await waitUntil("baseline", timeout: .seconds(10)) { engine.extras.mergeRequests.watch(thread.id, ref.url)?.baseline != nil }
        GitLabFixtures.install(sandbox.gitLab, mr: GitLabFixtures.mr(pipelineStatus: "success"), jobs: GitLabFixtures.jobs([("unit", "success")]))
        // One model run (the wake): the poller (3 s here) finds the finished pipeline; later polls must not wake again.
        try await waitUntil("woken", timeout: .seconds(60)) { engine.extras.mergeRequests.watch(thread.id, ref.url)?.wakes == 1 }
        try await eventually("wake run done", timeout: .seconds(120)) {
            ((try? await sandbox.messageText(thread.id)) ?? "").contains("[BelloCode MR watch]") && engine.orchestration.node(thread.id)?.node.ownStatus != .running
        }
        try await Task.sleep(for: .seconds(8))  // two more polls
        let text = try await sandbox.messageText(thread.id)
        #expect(text.components(separatedBy: "[BelloCode MR watch]").count == 2, "exactly one wake")
        #expect(engine.extras.mergeRequests.watch(thread.id, ref.url)?.wakes == 1)
    }
}
