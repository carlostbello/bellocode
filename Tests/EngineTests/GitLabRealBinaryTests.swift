import BelloCore
import Darwin
import Foundation
import Testing

@testable import Engine
@testable import OpenCodeKit

/// GitLab 1 and 2 against the pinned opencode with the bellocode plugin and the app tools (client MCP). Opt-in:
/// `BELLOCODE_GITLAB_REAL=1 swift test --filter GitLabRealBinary`. At most four short model runs on the zero-cost
/// default model; HOME and XDG directories in a fresh temporary directory (never the user's opencode data); the GitLab
/// is the in-process fake (no network); the token lives in an in-memory vault.
@Suite(
    "GitLab real binary", .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["BELLOCODE_GITLAB_REAL"] == "1" && EngineRepo.vendoredOpencode != nil,
        "set BELLOCODE_GITLAB_REAL=1 and run Scripts/fetch-opencode.sh"),
    .timeLimit(.minutes(10)))
@MainActor
struct GitLabRealBinaryTests {
    @MainActor struct Sandbox {
        let root: URL
        let project: URL
        let supervisor: ServerSupervisor
        let engine: Engine
        let server: FakeGitLabServer

        static func start() async throws -> Sandbox {
            let executable = try #require(EngineRepo.vendoredOpencode)
            let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-gitlab-\(UUID().uuidString)", directoryHint: .isDirectory)
            let project = root.appending(path: "project", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try "gitlab sandbox\n".write(to: project.appending(path: "README.md"), atomically: true, encoding: .utf8)
            for arguments in [
                ["init", "-q", "-b", "feat/checklist"], ["add", "README.md"],
                ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "Add launch checklist"],
                ["remote", "add", "origin", "git@code.corp.test:platform/rocket.git"],
            ] {
                let process = Process()
                process.standardInput = FileHandle.nullDevice
                process.executableURL = URL(filePath: "/usr/bin/git")
                process.arguments = arguments
                process.currentDirectoryURL = project
                try process.run()
                process.waitUntilExit()
            }
            let supervisor = ServerSupervisor(
                configuration: ServerConfiguration(
                    executableURL: executable, dataRoot: root.appending(path: "server", directoryHint: .isDirectory),
                    expectedVersion: EngineRepo.pinnedVersion, pluginDirectory: OrchestrationRealBinaryTests.pluginDirectory))
            var configuration = EngineConfiguration(server: .supervised(supervisor), store: .inMemory)
            configuration.defaultDirectory = project.path
            let server = GitLabWorld.server()
            configuration.secretVault = InMemorySecretVault()
            configuration.forgeTransport = server
            configuration.forgeTokens = GitLabWorld.tokens()
            configuration.visualsDirectory = root.appending(path: "visuals", directoryHint: .isDirectory)
            let engine = try Engine(configuration: configuration)
            await engine.start()
            await engine.addProject(directory: project.path)
            try await waitUntil("live", timeout: .seconds(30)) { engine.root.connection == .live }
            _ = try await engine.extras.mergeRequests.saveInstance(baseURL: GitLabWorld.instance.baseURL, token: nil)
            await engine.extras.mergeRequests.setSettings(GitLabInstanceSettings(writesEnabled: true), for: GitLabWorld.instance.baseURL)
            await engine.orchestration.hostAppTools(directories: [project.path])
            return Sandbox(root: root, project: project, supervisor: supervisor, engine: engine, server: server)
        }

        func stop() async {
            let pid = await supervisor.childPID
            await engine.stop()
            if let pid { #expect(kill(pid, 0) != 0, "server child \(pid) still running") }
            try? FileManager.default.removeItem(at: root)
        }

        func messageText(_ id: SessionID) async throws -> String {
            let client = try await engine.core.currentClient()
            return try await client.messages(sessionID: id.rawValue, MessageListQuery(limit: 200)).data.map { String(describing: $0) }.joined(separator: "\n")
        }

        func appTools() async throws -> [String] {
            let client = try await engine.core.currentClient()
            let output = try await client.pluginRPC(OrchestrationContract.rpcID, "info", input: .object([:]), directory: project.path)
            guard case .array(let items) = output["appTools"] ?? .null else { return [] }
            return items.compactMap { $0["id"]?.stringValue }
        }

        /// Every file opencode wrote in the sandbox, searched for `needle`.
        func serverFilesContain(_ needle: String) -> Bool {
            guard let enumerator = FileManager.default.enumerator(at: root.appending(path: "server"), includingPropertiesForKeys: nil) else { return false }
            for case let url as URL in enumerator {
                guard let data = try? Data(contentsOf: url), data.count < 64 << 20 else { continue }
                if data.range(of: Data(needle.utf8)) != nil { return true }
            }
            return false
        }
    }

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

    @Test func toolsRegisterAndAReadAndAnApprovedWriteWorkEndToEnd() async throws {
        let sandbox = try await Sandbox.start()
        defer { Task { await sandbox.stop() } }
        let engine = sandbox.engine
        // No model run: every GitLab tool is attached for the project.
        var tools: [String] = []
        for _ in 0..<100 {
            tools = (try? await sandbox.appTools()) ?? []
            if Set(tools).isSuperset(of: GitLabTools.all.map { OrchestrationService.appServerName + "_" + $0 }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("GitLab real: \(tools.filter { $0.contains("gitlab") }.count) GitLab tools attached")
        #expect(Set(tools).isSuperset(of: GitLabTools.all.map { OrchestrationService.appServerName + "_" + $0 }))
        let thread = try await engine.createThread(in: sandbox.project.path, title: "gitlab")
        try await waitUntil("graph") { engine.orchestration.node(thread.id) != nil }
        // Run 1: one read tool and one approval-gated write in a single turn.
        _ = try await engine.send(
            """
            Call these tools once each, in order, then end your turn with: DONE
            1. bellocode_app_gitlab_read_pipeline with ref "!42".
            2. bellocode_app_gitlab_reply_to_discussion with ref "!42", discussionID "d1" and body "Thanks, fixed."
            """, to: thread.id)
        try await eventually("turn started", timeout: .seconds(60)) { await engine.core.knownSession(thread.id)?.busySince != nil }
        try await eventually("turn ended", timeout: .seconds(180)) { !(await engine.core.knownSession(thread.id)?.isRunning ?? true) }
        let afterTurn = try await sandbox.messageText(thread.id)
        #expect(afterTurn.contains("bellocode_app_gitlab_read_pipeline"))
        #expect(afterTurn.contains("unit-tests"), "the read tool's result reached the model")
        #expect(!sandbox.server.requests.contains { $0.method == "POST" }, "nothing written before the card")
        let card = try #require(await engine.extras.pendingAppRequests().first {
            if case .approval(let approval) = $0.kind { approval.action == .gitlabWrite } else { false }
        })
        // The approval sends the reply and wakes the thread (run 2).
        try await engine.extras.respond(to: card.id, .approve(always: false))
        #expect(sandbox.server.requests.contains { $0.method == "POST" && $0.path.hasSuffix("discussions/d1/notes") && ($0.body ?? "").contains("Thanks, fixed.") })
        try await eventually("wake handled", timeout: .seconds(180)) {
            let text = (try? await sandbox.messageText(thread.id)) ?? ""
            let running = await engine.core.knownSession(thread.id)?.isRunning ?? true
            return text.contains("[BelloCode GitLab] Approved by the user") && !running
        }
        let transcript = try await sandbox.messageText(thread.id)
        print("GitLab real: transcript \(transcript.count) chars; wake present \(transcript.contains("[BelloCode GitLab]"))")
        #expect(!transcript.contains(GitLabWorld.token), "the token never reaches the model")
        await engine.flush()
        #expect(!sandbox.serverFilesContain(GitLabWorld.token), "opencode stored no copy of the token")
    }

    /// GitLab 2: the new tools attach, the model reads the review threads, and an approval-gated draft comment is saved
    /// as a GitLab draft note (never published) after the person approves the card. Two model runs (prompt, wake).
    @Test func reviewToolsRegisterAndAnApprovedDraftCommentWorksEndToEnd() async throws {
        let sandbox = try await Sandbox.start()
        defer { Task { await sandbox.stop() } }
        ReviewWorld.configure(sandbox.server)
        let engine = sandbox.engine
        let wanted = [GitLabTools.readIssue, GitLabTools.listIssues, GitLabTools.readReviewDiscussions, GitLabTools.createDraftComment]
            .map { OrchestrationService.appServerName + "_" + $0 }
        var tools: [String] = []
        for _ in 0..<100 {
            tools = (try? await sandbox.appTools()) ?? []
            if Set(tools).isSuperset(of: wanted) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("GitLab real (2): \(tools.filter { $0.contains("gitlab") }.count) GitLab tools attached")
        #expect(Set(tools).isSuperset(of: wanted))
        let thread = try await engine.createThread(in: sandbox.project.path, title: "review")
        try await waitUntil("graph") { engine.orchestration.node(thread.id) != nil }
        _ = try await engine.send(
            """
            Call these tools once each, in order, then end your turn with: DONE
            1. bellocode_app_gitlab_read_review_discussions with ref "!42".
            2. bellocode_app_gitlab_create_draft_comment with ref "!42", path "Sources/Parser.swift", line 3 and body "Please name this constant."
            """, to: thread.id)
        try await eventually("turn started", timeout: .seconds(60)) { await engine.core.knownSession(thread.id)?.busySince != nil }
        try await eventually("turn ended", timeout: .seconds(180)) { !(await engine.core.knownSession(thread.id)?.isRunning ?? true) }
        let afterTurn = try await sandbox.messageText(thread.id)
        #expect(afterTurn.contains("bellocode_app_gitlab_read_review_discussions"))
        #expect(afterTurn.contains("Sources/Parser.swift new line 3"), "the positions reached the model")
        #expect(!sandbox.server.requests.contains { $0.method == "POST" }, "nothing written before the card")
        let card = try #require(await engine.extras.pendingAppRequests().first {
            if case .approval(let approval) = $0.kind { approval.action == .gitlabWrite } else { false }
        })
        if case .approval(let approval) = card.kind {
            #expect(approval.detail.contains("at head 9f2c1ab4e5d6") && approval.detail.contains("File: Sources/Parser.swift") && approval.detail.contains("Line: 3"))
        }
        try await engine.extras.respond(to: card.id, .approve(always: false))
        #expect(sandbox.server.requests.contains { $0.method == "POST" && $0.path.hasSuffix("/draft_notes") && ($0.body ?? "").contains("Please name this constant.") })
        #expect(!sandbox.server.requests.contains { $0.path.hasSuffix("/bulk_publish") }, "an agent never publishes")
        try await eventually("wake handled", timeout: .seconds(180)) {
            let text = (try? await sandbox.messageText(thread.id)) ?? ""
            let running = await engine.core.knownSession(thread.id)?.isRunning ?? true
            return text.contains("[BelloCode GitLab] Approved by the user. Saved a GitLab draft note") && !running
        }
        let transcript = try await sandbox.messageText(thread.id)
        #expect(!transcript.contains(GitLabWorld.token), "the token never reaches the model")
    }
}
