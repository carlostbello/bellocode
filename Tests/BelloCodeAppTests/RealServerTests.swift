import AppKit
import BelloCore
import ComposerKit
import Darwin
import Engine
import Foundation
import OpenCodeKit
import Testing

@testable import BelloCodeApp

enum ShellRepo {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var version: String? {
        try? String(contentsOf: root.appending(path: "Scripts/opencode-version"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static var opencode: URL? {
        guard let version else { return nil }
        let url = root.appending(path: "Vendor/opencode/\(version)/opencode")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    static var enabled: Bool { ProcessInfo.processInfo.environment["BELLOCODE_SHELL_E2E"] == "1" && opencode != nil }
}

/// Opt-in check of the integrated app against the real pinned opencode (`BELLOCODE_SHELL_E2E=1 swift test --filter
/// RealServer`), through the app's own code paths: the server configuration of the assembled bundle
/// (`build/BelloCode.app`, else the vendored binary), the main window, the real composer and the Thread menu's
/// commands. Adds a project folder, sends one prompt from the new-thread draft with a small image and an `@`-mentioned
/// file on the default model only if it is zero-cost, waits for the reply, then asks for a file edit in "Ask" mode and
/// approves the permission through the Engine API if the model asks. Two prompts at most. Isolated XDG/HOME in a
/// temporary directory; the user's opencode config and data are never touched.
@MainActor @Suite("Shell real server", .serialized, .enabled(if: ShellRepo.enabled, "set BELLOCODE_SHELL_E2E=1"), .timeLimit(.minutes(10)))
struct RealServerTests {
    @Test func addProjectSendWithAttachmentsApproveAndReply() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-shell-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        let project = root.appending(path: "hello-project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "# Hello project\nThe secret word is pelican.\n".write(to: project.appending(path: "README.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = ShellRepo.root.appending(path: "build/BelloCode.app")
        let configuration: ServerConfiguration
        if let bundle = Bundle(url: bundleURL),
           FileManager.default.isExecutableFile(atPath: bundleURL.appending(path: "Contents/Helpers/opencode").path)
        {
            configuration = AppRuntime.bundledServerConfiguration(bundle: bundle, dataRoot: root.appending(path: "server"))
            print("e2e: server from the app bundle \(configuration.executableURL.path)")
        } else {
            configuration = ServerConfiguration(
                executableURL: try #require(ShellRepo.opencode), dataRoot: root.appending(path: "server", directoryHint: .isDirectory),
                helpersDirectory: ShellRepo.root.appending(path: "Vendor/ripgrep", directoryHint: .isDirectory),
                expectedVersion: ShellRepo.version)
            print("e2e: server from Vendor (no assembled bundle)")
        }
        let supervisor = ServerSupervisor(configuration: configuration)
        let engine = try Engine(configuration: EngineConfiguration(server: .supervised(supervisor), store: .file(root.appending(path: "projection.sqlite"))))
        await engine.start()
        #expect(await waitUntil(timeout: .seconds(60)) { engine.root.connection == .live })
        let pid = await supervisor.childPID

        let attachments = root.appending(path: "attachments")
        let auth = engine.makeAuthService(openURL: { _ in })
        let services = AppServices(settings: AppSettings(defaults: nil), auth: auth, attachmentStore: AttachmentFileStore(directory: attachments))
        let workspace = WorkspaceController(engine: engine, stateStore: ShellStateStore(defaults: nil))
        let controller = MainWindowController(workspace: workspace, configuration: .init(surfaces: .builtIn(services: services), autosaveSuffix: nil))
        controller.showWindow(nil)
        let driver = ShellDriver(controller: controller)
        workspace.addProjects([project])
        let directory = WorkspaceController.canonicalDirectory(project)
        #expect(await waitUntil(timeout: .seconds(30)) {
            workspace.selection == .draft(directory: directory) && controller.container.composerController != nil
        })

        // Zero-cost default model only.
        await engine.refreshCatalog(directory: directory)
        let catalog = try #require(engine.root.catalog.catalog(for: directory))
        let defaultModel = try #require(catalog.defaultModel, "no default model")
        let model = try #require(catalog.models.first { $0.providerID == defaultModel.providerID && $0.modelID == defaultModel.modelID })
        print("e2e: default model \(model.id) free=\(model.isFree)")
        try #require(model.isFree, "default model is not zero-cost; not sending")

        // Prompt 1, from the draft's real composer: an @-mentioned file and a pasted image.
        let composer = try #require(driver.composer)
        composer.insert(text: "Reply in one short sentence: what is the secret word in ")
        composer.insert(token: ComposerToken(kind: .file, text: "@README.md", value: directory + "/README.md"))
        composer.insert(text: "and what colour is the attached image? Do not use tools.")
        _ = composer.add(attachments: [.image(Self.redSquarePNG(), type: .png, name: "red.png")])
        let clock = ContinuousClock()
        let start = clock.now
        driver.send()
        #expect(await waitUntil(timeout: .seconds(30)) {
            if case .thread = workspace.selection { return true }
            return false
        }, "the draft created its thread: \(controller.container.context?.visibleError ?? "")")
        guard case .thread(let id) = workspace.selection else { return }
        let thread = workspace.threadModel(id)
        let replied = await waitUntil(timeout: .seconds(120)) { !thread.isRunning && !Self.assistantText(thread).isEmpty }
        let reply = Self.assistantText(thread)
        print("e2e: reply 1 in \(clock.now - start): \(reply.prefix(200))")
        #expect(replied, "no reply; error: \(thread.lastError?.userMessage ?? thread.session?.lastError?.message ?? "none")")
        let user = thread.messageIDs.compactMap { thread.message($0)?.message }.first { $0.kind.typeName == "user" }
        let fileParts = user?.parts.compactMap { part -> FileReference? in if case .file(let f) = part.content { f } else { nil } } ?? []
        print("e2e: server user message files: \(fileParts.map { "\($0.name ?? "?") \($0.mime)" })")
        #expect(fileParts.contains { $0.name == "red.png" }, "the server kept the image attachment")
        print("e2e: mentions pelican: \(reply.lowercased().contains("pelican")), red: \(reply.lowercased().contains("red"))")

        // Prompt 2, in "Ask" mode: a file edit; approve through the Engine API if the model asks.
        await thread.setPermissionMode(.ask)
        driver.type("Create a file named hello.txt containing the single word hi. Use the write or edit tool once, then stop.")
        driver.send()
        var approved = false
        let deadline = clock.now + .seconds(150)
        while clock.now < deadline {
            if case .permission(let permission)? = thread.pendingRequests.first(where: \.isPermission) {
                print("e2e: permission \(permission.action) \(permission.resources)")
                await thread.reply(to: permission.id, .once)
                approved = thread.lastError == nil
            }
            if !thread.isRunning, thread.pendingRequests.isEmpty, thread.messageIDs.count >= 4 { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let created = FileManager.default.fileExists(atPath: project.appending(path: "hello.txt").path)
        print("e2e: permission approved: \(approved); hello.txt created: \(created); final status \(thread.status?.status.label ?? "?")")
        #expect(!thread.isRunning)

        let listed = await waitUntil(timeout: .seconds(10)) {
            engine.root.projects.contains { item in workspace.projectModel(item)?.sessionIDs.contains(id) ?? false }
        }
        #expect(listed, "the new thread is listed under its project")
        workspace.close()
        controller.close()
        auth.shutdown()
        await engine.stop()
        if let pid { #expect(kill(pid, 0) != 0, "server process exited") }
    }

    static func assistantText(_ thread: ThreadModel) -> String {
        thread.messageIDs.compactMap { thread.message($0)?.message }.filter { if case .assistant = $0.kind { true } else { false } }
            .map(\.searchableText).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A 16x16 red PNG.
    static func redSquarePNG() -> Data {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        return image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]) ?? Data()
    }
}
