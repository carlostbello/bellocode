import AgentUI
import AppKit
import BelloCore
import ComposerKit
import Engine
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import BelloCodeApp

/// The integrated app, scripted end to end in-process against MockOpenCode: the real main window, the real composer
/// (typed into, sent through the Thread menu's command), a streamed scripted turn, a permission answered through the
/// request stack's command, a queued follow-up while running, Stop, and switching threads with drafts preserved.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct IntegratedShellTests {
    @MainActor struct Shell {
        let server: MockOpenCodeServer
        let engine: Engine
        let controller: MainWindowController
        let driver: ShellDriver
        let attachments: URL

        static func start() async throws -> Shell {
            _ = NSApplication.shared
            let server = MockOpenCodeServer(scenario: .demo(), options: MockServerOptions(clock: .realTime))
            let endpoint = try await server.start()
            let connection = ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? ""))
            let engine = try Engine(configuration: EngineConfiguration(server: .fixed(connection), store: .inMemory))
            await engine.start()
            let attachments = FileManager.default.temporaryDirectory.appending(path: "shell-attachments-\(UUID().uuidString)")
            let services = AppServices(
                settings: AppSettings(defaults: nil), auth: engine.makeAuthService(openURL: { _ in }),
                attachmentStore: AttachmentFileStore(directory: attachments))
            let workspace = WorkspaceController(engine: engine, stateStore: ShellStateStore(defaults: nil))
            let controller = MainWindowController(
                workspace: workspace, configuration: .init(surfaces: .builtIn(services: services), autosaveSuffix: nil))
            controller.showWindow(nil)
            let live = await waitUntil(timeout: .seconds(20)) {
                engine.root.connection == .live
                    && engine.root.projects.allSatisfy { workspace.projectModel($0).map { !$0.sessionIDs.isEmpty } ?? false }
            }
            #expect(live)
            return Shell(server: server, engine: engine, controller: controller, driver: ShellDriver(controller: controller), attachments: attachments)
        }

        func stop() async {
            controller.workspace.close()
            controller.close()
            await engine.stop()
            await server.stop()
            try? FileManager.default.removeItem(at: attachments)
        }

        var threads: [SessionID] { engine.root.projects.flatMap { controller.workspace.projectModel($0)?.sessionIDs ?? [] } }
    }

    static let approvalTurn = TurnScript(name: "e2e-approval") {
        TurnStep.text("Reading the project first.\n\n", chunkSize: 4, rate: 80)
        TurnStep.tool(
            "edit", input: ["path": "README.md", "old": "Hello", "new": "Hello, world"], output: "Edited README.md",
            duration: 30, permission: PermissionAsk(action: "edit", resources: ["README.md"], save: ["README.md"]))
        TurnStep.text("Edited the README.", chunkSize: 4, rate: 80)
        TurnStep.delay(milliseconds: 20_000)
    }

    @Test func sendStreamApproveQueueStopAndSwitch() async throws {
        let shell = try await Shell.start()
        defer { Task { await shell.stop() } }
        let driver = shell.driver
        let workspace = shell.controller.workspace
        let threads = shell.threads
        try #require(threads.count >= 2)
        let first = threads[0]
        let other = threads[1]

        // Select a thread: the real composer is mounted with its controls and context line.
        #expect(await driver.select(.thread(first)))
        let thread = workspace.threadModel(first)
        #expect(await waitUntil(timeout: .seconds(5)) { thread.phase == .ready })
        let composer = try #require(driver.composer)
        #expect(composer.host is ThreadModelComposerHost)
        #expect(composer.leadingControls.arrangedSubviews.count == 2, "plan toggle and model picker")
        #expect(composer.trailingControls.arrangedSubviews.count == 1, "permission mode")
        #expect(composer.contextLineView is ComposerContextLine)
        await thread.setPermissionMode(.ask)

        // Type and send through the Thread menu's Send command; the scripted turn streams in.
        await shell.server.enqueueScript(Self.approvalTurn, for: first.rawValue)
        driver.type("Please greet the world in the README.")
        #expect(shell.controller.commandContext().isEnabled(.sendMessage))
        driver.send()
        #expect(composer.currentDraft().isEmpty, "cleared at once")
        let userShown = await waitUntil(timeout: .seconds(5)) {
            thread.messageIDs.compactMap { thread.message($0)?.message }.contains {
                if case .user(let content) = $0.kind { content.text == "Please greet the world in the README." } else { false }
            }
        }
        #expect(userShown)
        #expect(await waitUntil(timeout: .seconds(10)) { thread.isRunning })

        // The permission arrives: pinned above the composer, and focus stays in the composer.
        #expect(await waitUntil(timeout: .seconds(10)) { thread.pendingRequests.contains { $0.isPermission } })
        driver.settle()
        #expect(driver.window.firstResponder === composer.textView, "a request never steals focus from typing")
        let stack = try #require(driver.requestStack?.model)
        #expect(stack.canPerform(.allowOnce))
        #expect(shell.controller.commandContext().isEnabled(.allowOnce))
        // F6 cycling reaches the request stack while a request is pending.
        #expect(shell.controller.container.requestFocusView != nil)
        driver.perform(.allowOnce)
        #expect(await waitUntil(timeout: .seconds(10)) { thread.pendingRequests.isEmpty })
        let streamed = await waitUntil(timeout: .seconds(10)) {
            thread.messageIDs.compactMap { thread.message($0)?.message.searchableText }.contains { $0.contains("Edited the README.") }
        }
        #expect(streamed, "the rest of the turn streamed in after approval")
        #expect(thread.isRunning)

        // The streamed turn through the real transcript: rows by server ID, the tail text, the edit as a tool line,
        // and the view still following the bottom.
        let transcript = try #require(shell.controller.container.transcriptSurface?.controller)
        let shown = await waitUntil(timeout: .seconds(10)) {
            transcript.rows.contains { row in
                if case .markdown(let text, _) = row.content { return text.contains("Edited the README.") }
                return false
            }
        }
        #expect(shown, "the streamed tail is a transcript row")
        await transcript.settle()
        let userRows = transcript.rows.filter { $0.role == .user }
        #expect(userRows.contains { if case .user(let user) = $0.content { user.text == "Please greet the world in the README." } else { false } })
        #expect(transcript.rows.contains { row in
            if case .work(let group) = row.content { return group.items.contains { $0.name == "edit" && $0.target == "README.md" } }
            return false
        }, "the approved edit is a tool line")
        #expect(Set(transcript.rows.map(\.id)).count == transcript.rows.count, "row identity is unique")
        #expect(transcript.following && abs(transcript.distanceFromBottom) < 1, "following the tail")
        transcript.selectAll()
        #expect(transcript.selectedText().contains("Edited the README."), "streamed text is selectable and copies")
        transcript.clearSelection()

        // A follow-up while running is queued (labelled, not claimed delivered until the server answers).
        driver.type("Then add a changelog entry.")
        #expect(composer.primaryAction == .send(.queue))
        driver.send()
        #expect(await waitUntil(timeout: .seconds(5)) { thread.queue.contains { $0.state == .queued } })
        let bodies = await shell.server.promptBodies()
        #expect(bodies.last?["delivery"]?.stringValue == "queue")

        // Stop (⌘.) is a menu command, not Escape.
        #expect(ShellCommand.stopRun.shortcut.key == ".")
        #expect(shell.controller.commandContext().isEnabled(.stopRun))
        driver.perform(.stopRun)
        #expect(await waitUntil(timeout: .seconds(10)) { !thread.isRunning && !thread.isStopping })

        // A draft survives switching away and back (text, tokens and caret).
        driver.type("Draft for later about ")
        composer.insert(token: ComposerToken(kind: .file, text: "@README.md", value: "/tmp/README.md"))
        let draft = composer.currentDraft()
        #expect(await driver.select(.thread(other)))
        #expect(driver.composer?.currentDraft().text.contains("Draft for later") == false, "no leak into another thread")
        #expect(await driver.select(.thread(first)))
        let restored = try #require(driver.composer?.currentDraft())
        #expect(restored.text == draft.text)
        #expect(restored.tokens.map(\.token.text) == ["@README.md"])
    }

    @Test func draftSendsAttachmentsAndMentionsThenDocks() async throws {
        let shell = try await Shell.start()
        defer { Task { await shell.stop() } }
        let driver = shell.driver
        let project = try #require(shell.engine.root.projects.first)
        #expect(await driver.select(.draft(directory: project.directory)))
        let composer = try #require(driver.composer)
        #expect(composer.style.minimumLines == 3, "the hero composer")
        #expect(driver.composer?.host is DraftComposerHost)
        composer.insert(text: "Look at ")
        composer.insert(token: ComposerToken(kind: .file, text: "@Package.swift", value: project.directory + "/Package.swift"))
        composer.insert(text: "and this screenshot")
        _ = composer.add(attachments: [.image(Data([0x89, 0x50, 0x4E, 0x47]), type: .png, name: "shot.png")])
        driver.send()

        // The thread is created, the selection moves to it and the composer docks.
        let docked = await waitUntil(timeout: .seconds(10)) {
            if case .thread = shell.controller.workspace.selection, driver.composer?.style.minimumLines == 1 { return true }
            return false
        }
        #expect(docked)
        guard case .thread(let id) = shell.controller.workspace.selection else { return }
        let thread = shell.controller.workspace.threadModel(id)
        #expect(await waitUntil(timeout: .seconds(10)) {
            thread.messageIDs.compactMap { thread.message($0)?.message }.contains { message in
                message.parts.contains { if case .file(let file) = $0.content { file.name == "shot.png" } else { false } }
            }
        }, "the sent attachment shows in the user message")
        let body = try #require(await shell.server.promptBodies().last)
        let files = body["files"]?.arrayValue ?? []
        #expect(files.count == 2)
        #expect(files.first?["mention"]?["text"]?.stringValue == "@Package.swift")
        #expect(files.first?["source"]?["type"]?.stringValue == "uri")
        let written = try #require(files.last?["uri"]?.stringValue.flatMap(URL.init(string:)))
        #expect(written.path.hasPrefix(shell.attachments.path), "pasted image written to the app's attachments folder")
    }

    @Test func completionUsesServerCommandsAndFiles() async throws {
        let shell = try await Shell.start()
        defer { Task { await shell.stop() } }
        let driver = shell.driver
        let first = try #require(shell.threads.first)
        #expect(await driver.select(.thread(first)))
        let composer = try #require(driver.composer)
        driver.type("/rev")
        await composer.settle()
        #expect(composer.completion.items.first?.title == "/review")
        composer.completion.close()
        composer.textView.string = ""
        driver.type("see @Pars")
        await composer.settle()
        #expect(composer.completion.items.map(\.title).contains("Parser.swift"), "from the server's file search")
    }
}
