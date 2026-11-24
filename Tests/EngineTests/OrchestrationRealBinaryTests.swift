import BelloCore
import Darwin
import Foundation
import OpenCodeKit
import Testing

@testable import Engine

/// M3-A against the pinned opencode with the bellocode plugin loaded from the bundle (`build/BelloCode.app`, after
/// `make app`) or else from `Plugin/`. Opt-in: `BELLOCODE_ORCH_REAL=1 swift test --filter OrchestrationRealBinary`.
/// Five short prompts on the zero-cost default model; HOME and XDG directories in a fresh temporary directory (never
/// the user's opencode data); every process is stopped before a test returns.
@Suite(
    "Orchestration real binary", .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["BELLOCODE_ORCH_REAL"] == "1" && EngineRepo.vendoredOpencode != nil,
        "set BELLOCODE_ORCH_REAL=1 and run Scripts/fetch-opencode.sh"),
    .timeLimit(.minutes(10)))
@MainActor
struct OrchestrationRealBinaryTests {
    /// The plugin every real-binary suite loads. Chosen afresh for each server, never cached.
    nonisolated static var pluginDirectory: URL { pluginDirectory(root: EngineRepo.root) }

    /// The bundle's copy (`make app`) only when its runtime files are byte-for-byte those of `Plugin/`; otherwise
    /// `Plugin/`. A bundle assembled before the latest plugin change would run old plugin code against new tests: a full
    /// live run in a checkout with a stale `build/BelloCode.app` loaded a plugin without durable root pins (AF08) and
    /// failed only where a test looked for the pin file.
    nonisolated static func pluginDirectory(root: URL) -> URL {
        let source = root.appending(path: "Plugin", directoryHint: .isDirectory)
        let bundled = root.appending(path: "build/BelloCode.app/Contents/Resources/opencode-plugin", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: bundled.appending(path: "server.ts").path) else { return source }
        guard let expected = runtimeFiles(source), !expected.isEmpty, runtimeFiles(bundled) == expected else {
            print("real binary: build/BelloCode.app's plugin differs from Plugin/ (stale bundle; run make app): using Plugin/")
            return source
        }
        return bundled
    }

    /// `server.ts` and `src/*.ts` (what Scripts/make-app.sh bundles), by relative path; nil when unreadable.
    nonisolated static func runtimeFiles(_ folder: URL) -> [String: Data]? {
        let manager = FileManager.default
        guard let server = manager.contents(atPath: folder.appending(path: "server.ts").path),
              let names = try? manager.contentsOfDirectory(atPath: folder.appending(path: "src").path)
        else { return nil }
        var files = ["server.ts": server]
        for name in names where name.hasSuffix(".ts") {
            guard let data = manager.contents(atPath: folder.appending(path: "src/\(name)").path) else { return nil }
            files["src/\(name)"] = data
        }
        return files
    }

    @MainActor struct Sandbox {
        let root: URL
        let project: URL
        let supervisor: ServerSupervisor
        let engine: Engine

        static func start(_ name: String) async throws -> Sandbox {
            let executable = try #require(EngineRepo.vendoredOpencode)
            let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-orch-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
            let project = root.appending(path: "project", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try "orchestration sandbox\n".write(to: project.appending(path: "README.md"), atomically: true, encoding: .utf8)
            let supervisor = ServerSupervisor(
                configuration: ServerConfiguration(
                    executableURL: executable, dataRoot: root.appending(path: "server", directoryHint: .isDirectory),
                    expectedVersion: EngineRepo.pinnedVersion, pluginDirectory: OrchestrationRealBinaryTests.pluginDirectory))
            var configuration = EngineConfiguration(server: .supervised(supervisor), store: .inMemory)
            configuration.defaultDirectory = project.path
            let engine = try Engine(configuration: configuration)
            await engine.start()
            await engine.addProject(directory: project.path)
            try await waitUntil("live", timeout: .seconds(30)) { engine.root.connection == .live }
            return Sandbox(root: root, project: project, supervisor: supervisor, engine: engine)
        }

        func client() async throws -> OpenCodeClient { try await engine.core.currentClient() }

        func stop() async {
            let pid = await supervisor.childPID
            await engine.stop()
            if let pid { #expect(kill(pid, 0) != 0, "server child \(pid) still running") }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func texts(_ messages: [SessionMessage]) -> [(type: String, text: String)] {
        messages.map { message in
            switch message {
            case .user(let user): ("user", user.text)
            case .assistant(let assistant):
                ("assistant", assistant.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined())
            case .other(let type, _, let raw): (type, raw["text"]?.stringValue ?? "")
            default: (message.type, "")
            }
        }
    }

    @Test func pluginLoadsFromTheBundleAndRegistersItsTools() async throws {
        let sandbox = try await Sandbox.start("load")
        defer { Task { await sandbox.stop() } }
        let orchestration = sandbox.engine.orchestration!
        await orchestration.checkPlugin(directory: sandbox.project.path)
        print("M3-A real: plugin from \(Self.pluginDirectory.path): \(orchestration.pluginStatus.label)")
        #expect(orchestration.pluginStatus == .ready(tools: OrchestrationContract.Tool.all.count))
        // The app-hosted tools: the client-MCP socket attaches for the location.
        await orchestration.hostAppTools(directories: [sandbox.project.path])
        #expect(orchestration.hostedDirectories == [sandbox.project.path])
        // A session in that location gets the guidance entry from the plugin.
        let thread = try await sandbox.engine.createThread(in: sandbox.project.path, title: "guidance")
        let client = try await sandbox.client()
        var keys: [String] = []
        for _ in 0..<50 where !keys.contains(OrchestrationContract.guidanceKey) {
            keys = ((try? await client.instructionEntries(sessionID: thread.id.rawValue)) ?? []).map(\.key)
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(keys.contains(OrchestrationContract.guidanceKey))
    }

    /// NF01, no prompt: opencode opens an MCP session with the app's tools for the first project, and again on the
    /// restarted server (new port and password) after a supervised restart, without the app being relaunched.
    @Test func appToolsAreHostedAgainAfterASupervisedRestart() async throws {
        let sandbox = try await Sandbox.start("restart")
        defer { Task { await sandbox.stop() } }
        let orchestration = try #require(sandbox.engine.orchestration)
        func waitListed(after count: Int, _ what: String) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(60)
            while orchestration.appToolListings <= count {
                guard clock.now < deadline else {
                    Issue.record("\(what): opencode never listed the app tools (hosted \(orchestration.hostedDirectories))")
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        try await waitListed(after: 0, "first project")
        let before = try #require(await sandbox.supervisor.endpoint)
        // Counted before the restart: only a host dialling the new server can list them again.
        let listed = orchestration.appToolListings
        #expect(await sandbox.engine.core.restartServer())
        let after = try #require(await sandbox.supervisor.endpoint)
        #expect(after.generation == before.generation + 1)
        #expect(after.connection != before.connection)
        try await waitListed(after: listed, "after the restart")
        #expect(orchestration.hostedDirectories == [sandbox.project.path])
    }

    @Test func delegatedChildRunsAndWakesTheParentOnce() async throws {
        let sandbox = try await Sandbox.start("delegate")
        defer { Task { await sandbox.stop() } }
        let engine = sandbox.engine
        let orchestration = engine.orchestration!
        let parent = try await engine.createThread(in: sandbox.project.path, title: "delegate")
        _ = try await engine.send(
            "Use the delegate_task tool exactly once with description 'Say hello' and task 'Reply with exactly: HELLO-CHILD'. "
                + "Then end your turn. When the child's report arrives, reply with exactly: GOT HELLO-CHILD", to: parent.id)
        try await waitUntil("child summary", timeout: .seconds(120)) {
            orchestration.children(of: parent.id).first.flatMap { orchestration.node($0)?.node.summary } != nil
        }
        let child = try #require(orchestration.children(of: parent.id).first)
        #expect(orchestration.node(child)?.node.kind == .delegated)
        try await waitUntil("parent done", timeout: .seconds(120)) { orchestration.status(of: parent.id) == .done }
        let messages = texts(try await sandbox.client().messages(sessionID: parent.id.rawValue, MessageListQuery(limit: 100)).data)
        let reports = messages.filter { $0.type == "synthetic" && $0.text.hasPrefix("<subagent ") }
        print("M3-A real: child summary \(orchestration.node(child)?.node.summary ?? "-"); reports \(reports.count); replies \(messages.filter { $0.type == "assistant" }.map(\.text))")
        #expect(reports.count == 1)
        #expect(messages.contains { $0.type == "assistant" && $0.text.contains("GOT") })
    }

    @Test func stoppingTheParentStopsItsChildWithoutRestartingTheParent() async throws {
        let sandbox = try await Sandbox.start("cascade")
        defer { Task { await sandbox.stop() } }
        let engine = sandbox.engine
        let orchestration = engine.orchestration!
        let parent = try await engine.createThread(in: sandbox.project.path, title: "cascade parent")
        let child = try await engine.createThread(in: sandbox.project.path, title: "cascade child", agent: "general", parent: parent.id)
        let long = "Write the numbers from 1 to 300 in words, one per line. Do not use tools."
        _ = try await engine.send(long, to: parent.id)
        _ = try await engine.send(long, to: child.id)
        try await waitUntil("both running", timeout: .seconds(60)) {
            orchestration.status(of: child.id)?.isActive == true && orchestration.node(parent.id)?.node.ownStatus == .running
        }
        try await Task.sleep(for: .seconds(2))
        // One interrupt, of the parent only: the plugin stops the child and cuts the restart its report causes.
        try await engine.stop(parent.id)
        try await waitUntil("child stopped", timeout: .seconds(30)) { orchestration.status(of: child.id) == .stopped }
        try await Task.sleep(for: .seconds(3))
        let parentSession = try await sandbox.client().session(parent.id.rawValue)
        print("M3-A real: after cascade parent outcome \(parentSession.outcome?.rawValue ?? "-") busy \(parentSession.time.busy ?? 0) idle \(parentSession.time.idle ?? 0)")
        #expect(orchestration.node(parent.id)?.node.ownStatus != .running)
        #expect(parentSession.outcome?.rawValue == "interrupted")
    }

    @Test func createThreadsAndThreadSend() async throws {
        let sandbox = try await Sandbox.start("fanout")
        defer { Task { await sandbox.stop() } }
        let engine = sandbox.engine
        let orchestration = engine.orchestration!
        let creator = try await engine.createThread(in: sandbox.project.path, title: "creator")
        _ = try await engine.send(
            "Call create_threads once with one thread titled 'Fanout probe' and no prompt. Then call thread_send to that "
                + "thread with message 'Reply with exactly: PONG' and delivery queue. Then end your turn.", to: creator.id)
        try await waitUntil("created thread", timeout: .seconds(120)) { orchestration.createdThreads(by: creator.id).count == 1 }
        let created = try #require(orchestration.createdThreads(by: creator.id).first)
        #expect(orchestration.node(created)?.node.kind == .created)
        #expect(orchestration.node(created)?.node.group != nil)
        var received: [(type: String, text: String)] = []
        for _ in 0..<240 where !received.contains(where: { $0.text.hasPrefix("[Message from thread") }) {
            received = texts((try? await sandbox.client().messages(sessionID: created.rawValue, MessageListQuery(limit: 20)).data) ?? [])
            try await Task.sleep(for: .milliseconds(500))
        }
        print("M3-A real: created thread received \(received.map { "\($0.type): \($0.text.prefix(60))" })")
        #expect(received.contains { $0.type == "user" && $0.text.hasPrefix("[Message from thread") })
        try? await orchestration.stopTree(created)
    }

    @Test func childApprovalReachesTheParentsPendingList() async throws {
        let sandbox = try await Sandbox.start("approval")
        defer { Task { await sandbox.stop() } }
        let engine = sandbox.engine
        let parent = try await engine.createThread(in: sandbox.project.path, title: "approval parent")
        let child = try await engine.createThread(in: sandbox.project.path, title: "approval child", agent: "general", parent: parent.id)
        try await engine.setPermissionMode(.ask, for: child.id)
        let thread = engine.openThread(parent.id)
        defer { thread.close() }
        _ = try await engine.send("Run this shell command and report its output: echo bellocode-approval", to: child.id)
        try await waitUntil("approval in the parent", timeout: .seconds(120)) {
            thread.pendingRequests.contains { $0.sessionID == child.id }
        }
        #expect(engine.orchestration.status(of: child.id) == .needsApproval)
        #expect(engine.orchestration.aggregate(under: parent.id).needsYou == 1)
        guard case .permission(let request)? = thread.pendingRequests.first(where: { $0.sessionID == child.id }) else {
            Issue.record("expected a permission request")
            return
        }
        print("M3-A real: child approval \(request.action) reached the parent")
        try await engine.reply(to: request.id, .reject)
        try? await engine.orchestration.stopTree(child.id)
    }
}
