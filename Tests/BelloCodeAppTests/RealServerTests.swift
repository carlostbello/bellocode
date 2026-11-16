import AppKit
import BelloCore
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

/// Opt-in walking-skeleton check against the real pinned opencode (`BELLOCODE_SHELL_E2E=1 swift test --filter
/// RealServer`): through the shell's own code paths, add a project folder, open its new-thread draft, send one short
/// prompt (the thread is created on first send) on the default model only if it is zero-cost, and wait for the reply.
/// Isolated XDG/HOME in a temporary directory; the user's opencode config and data are never touched.
@MainActor @Suite("Shell real server", .serialized, .enabled(if: ShellRepo.enabled, "set BELLOCODE_SHELL_E2E=1"))
struct RealServerTests {
    @Test func addProjectCreateThreadAndExchangeAMessage() async throws {
        _ = NSApplication.shared
        let executable = try #require(ShellRepo.opencode)
        let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-shell-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        let project = root.appending(path: "hello-project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "Shell end-to-end test\n".write(to: project.appending(path: "README.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = ServerSupervisor(
            configuration: ServerConfiguration(
                executableURL: executable, dataRoot: root.appending(path: "server", directoryHint: .isDirectory),
                helpersDirectory: ShellRepo.root.appending(path: "Vendor/ripgrep", directoryHint: .isDirectory),
                expectedVersion: ShellRepo.version))
        let engine = try Engine(configuration: EngineConfiguration(server: .supervised(supervisor), store: .file(root.appending(path: "projection.sqlite"))))
        await engine.start()
        defer { Task { await engine.stop() } }
        #expect(await waitUntil(timeout: .seconds(60)) { engine.root.connection == .live })
        let pid = await supervisor.childPID

        let workspace = WorkspaceController(engine: engine, stateStore: ShellStateStore(defaults: nil))
        let container = ThreadContainerViewController(workspace: workspace, surfaces: .builtIn)
        container.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        workspace.addProjects([project])
        let directory = WorkspaceController.canonicalDirectory(project)
        #expect(await waitUntil(timeout: .seconds(30)) { workspace.selection == .draft(directory: directory) && container.context != nil })
        print("e2e: projects \(engine.root.projects.map { "\($0.name) id=\($0.projectID?.rawValue ?? "nil")" })")

        // Zero-cost default model only.
        await engine.refreshCatalog(directory: directory)
        let catalog = try #require(engine.root.catalog.catalog(for: directory))
        let defaultModel = try #require(catalog.defaultModel, "no default model")
        let model = try #require(catalog.models.first { $0.providerID == defaultModel.providerID && $0.modelID == defaultModel.modelID })
        print("e2e: default model \(model.id) free=\(model.isFree)")
        try #require(model.isFree, "default model is not zero-cost; not sending")

        let draft = try #require(container.context)
        #expect(draft.isDraft)
        let clock = ContinuousClock()
        let start = clock.now
        let sent = await draft.send("Reply with one short sentence saying hello. Do not use tools.")
        #expect(sent, "send failed: \(draft.visibleError ?? "?")")
        guard case .thread(let id) = workspace.selection else {
            Issue.record("selection did not move to the created thread")
            return
        }
        let thread = workspace.threadModel(id)
        let replied = await waitUntil(timeout: .seconds(120)) {
            let texts = thread.messageIDs.compactMap { thread.message($0)?.message }.filter {
                if case .assistant = $0.kind { true } else { false }
            }.map(\.searchableText)
            return !thread.isRunning && texts.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        let reply = thread.messageIDs.compactMap { thread.message($0)?.message }.last { if case .assistant = $0.kind { true } else { false } }
        print("e2e: thread \(thread.session?.displayTitle ?? "?") in \(clock.now - start); \(thread.messageIDs.count) messages; reply chars \(reply?.searchableText.count ?? 0); status \(thread.status?.status.label ?? "?")")
        #expect(replied, "no assistant reply; error: \(thread.lastError?.userMessage ?? thread.session?.lastError?.message ?? "none")")
        #expect(engine.root.projects.contains { $0.directory == directory })
        let listed = await waitUntil(timeout: .seconds(10)) {
            engine.root.projects.contains { item in workspace.projectModel(item)?.sessionIDs.contains(id) ?? false }
        }
        print("e2e: after reply projects \(engine.root.projects.map { "\($0.name) id=\($0.projectID?.rawValue ?? "nil") dir=\($0.directory)" }); thread listed in sidebar: \(listed); session projectID \(thread.session?.projectID.rawValue ?? "?")")
        #expect(listed, "the new thread is listed under its project")

        workspace.close()
        await engine.stop()
        if let pid { #expect(kill(pid, 0) != 0, "server process exited") }
    }
}
