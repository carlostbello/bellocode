import AppKit
import BelloCore
import Engine
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import BelloCodeApp

/// Deep review 1, C4: two windows share one engine and so one `ThreadModel` per thread. Closing one window, or one
/// window evicting the thread from its eight-entry cache, must not freeze the other window's view of it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct ThreadLeaseTests {
    struct Fixture {
        let server: MockOpenCodeServer
        let engine: Engine
        let threads: [SessionID]
        let connection: ServerConnection
    }

    func start() async throws -> Fixture {
        _ = NSApplication.shared
        let server = MockOpenCodeServer(scenario: .empty(), options: .testing)
        let endpoint = try await server.start()
        let connection = ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? ""))
        let engine = try Engine(configuration: EngineConfiguration(server: .fixed(connection), store: .inMemory))
        await engine.start()
        #expect(await waitUntil(timeout: .seconds(20)) { engine.root.connection == .live })
        var threads: [SessionID] = []
        for index in 0..<(WorkspaceController.openThreadLimit + 1) {
            threads.append(try await engine.createThread(in: "/tmp/mock-project", title: "T\(index)").id)
        }
        return Fixture(server: server, engine: engine, threads: threads, connection: connection)
    }

    func stop(_ fixture: Fixture) async {
        await fixture.engine.stop()
        await fixture.server.stop()
    }

    /// The surviving window's model still receives the thread's changes.
    func expectLive(_ model: ThreadModel, _ fixture: Fixture, title: String) async throws {
        #expect(!model.isClosed)
        try await fixture.engine.renameThread(model.sessionID, to: title)
        #expect(await waitUntil(timeout: .seconds(10)) { model.session?.title == title }, "model still subscribed")
    }

    @Test func closingOneWindowKeepsTheOtherWindowsThreadLive() async throws {
        let fixture = try await start()
        let first = WorkspaceController(engine: fixture.engine, stateStore: ShellStateStore(defaults: nil))
        let second = WorkspaceController(engine: fixture.engine, stateStore: ShellStateStore(defaults: nil))
        let a = fixture.threads[0]
        let shown = second.threadModel(a)
        #expect(first.threadModel(a) === shown, "one shared model per thread")
        first.close()
        try await expectLive(shown, fixture, title: "Renamed after close")
        #expect(fixture.engine.openThread(a) === shown, "the engine still hands out the live instance")
        shown.close()
        second.close()
        #expect(shown.isClosed, "the last lease tears the model down")
        await stop(fixture)
    }

    @Test func ninthThreadEvictionInOneWindowKeepsTheOtherWindowsThreadLive() async throws {
        let fixture = try await start()
        let first = WorkspaceController(engine: fixture.engine, stateStore: ShellStateStore(defaults: nil))
        let second = WorkspaceController(engine: fixture.engine, stateStore: ShellStateStore(defaults: nil))
        let a = fixture.threads[0]
        _ = first.threadModel(a)
        let shown = second.threadModel(a)
        for id in fixture.threads.dropFirst() { _ = first.threadModel(id) }
        #expect(first.openThreadCount == WorkspaceController.openThreadLimit, "the first window evicted A")
        try await expectLive(shown, fixture, title: "Renamed after eviction")
        first.close()
        second.close()
        #expect(shown.isClosed)
        await stop(fixture)
    }

    /// NF03: showing a thread or a draft marks its project in use, which is what registers the MCP servers set up for
    /// all projects there (nothing else in the app did).
    @Test func showingAThreadOrDraftMarksItsProjectInUse() async throws {
        let fixture = try await start()
        let workspace = WorkspaceController(engine: fixture.engine, stateStore: ShellStateStore(defaults: nil))
        var shown: [String] = []
        workspace.projectShown = { shown.append($0) }
        let context = try #require(workspace.makeContext(for: .thread(fixture.threads[0])))
        #expect(!context.directory.isEmpty)
        #expect(shown == [context.directory])
        let project = try #require(fixture.engine.root.projects.first)
        _ = try #require(workspace.makeContext(for: .draft(directory: project.directory)))
        #expect(shown.last == project.directory)
        workspace.close()
        await stop(fixture)
    }

    /// NV3-01: a new-thread draft's first send can still be creating its thread when its window closes and the
    /// workspace is released. Opening the created thread then goes to the engine instead of trapping on the released
    /// controller.
    @Test func aDraftContextOutlivingItsWorkspaceStillOpensThreads() async throws {
        let fixture = try await start()
        let project = try #require(fixture.engine.root.projects.first)
        var workspace: WorkspaceController? = WorkspaceController(engine: fixture.engine, stateStore: ShellStateStore(defaults: nil))
        weak let released = workspace
        let context = try #require(workspace?.makeContext(for: .draft(directory: project.directory)))
        workspace?.close()
        workspace = nil
        #expect(released == nil, "the workspace is released with its window")
        let opened = try #require(context.openThread?(fixture.threads[0]))
        #expect(opened.sessionID == fixture.threads[0])
        opened.close()
        await stop(fixture)
    }

    /// NV04: a thread working in a worktree outside the project root keeps its working directory for the terminal, but
    /// per-project settings (opencode trust, Project Environment, global MCP servers) name the registered project.
    @Test func aWorktreeThreadsSettingsNameItsProjectRoot() async throws {
        let fixture = try await start()
        let worktree = try await fixture.engine.createThread(in: "/tmp/mock-worktrees/feat-x", title: "In a worktree")
        let model = fixture.engine.openThread(worktree.id)
        #expect(await waitUntil(timeout: .seconds(10)) { model.session != nil })
        let context = ThreadSurfaceContext(engine: fixture.engine, directory: "/tmp/mock-project", projectName: "mock-project", thread: model)
        #expect(context.directory == "/tmp/mock-worktrees/feat-x")
        #expect(context.settingsDirectory == "/tmp/mock-project")
        // A thread whose project is not known yet falls back to where it works.
        let unknown = ThreadSurfaceContext(engine: fixture.engine, directory: "", projectName: "", thread: model)
        #expect(unknown.settingsDirectory == "/tmp/mock-worktrees/feat-x")
        model.close()
        await stop(fixture)
    }

    /// NF03: a thread shown before its session is known (cold launch, or a child or notification thread opened before
    /// its row arrives) has no directory yet; its project is marked shown once the session hydrates, without the view
    /// being rebuilt.
    @Test func aThreadShownBeforeItsSessionHydratesMarksItsProjectWhenItArrives() async throws {
        let fixture = try await start()
        let id = fixture.threads[0]
        // A second engine on the same server that has not synced yet: it knows nothing about the thread.
        let late = try Engine(configuration: EngineConfiguration(server: .fixed(fixture.connection), store: .inMemory))
        let workspace = WorkspaceController(engine: late, stateStore: ShellStateStore(defaults: nil))
        var shown: [String] = []
        workspace.projectShown = { shown.append($0) }
        let context = try #require(workspace.makeContext(for: .thread(id)))
        #expect(context.directory.isEmpty)
        #expect(shown.isEmpty)
        await late.start()
        #expect(await waitUntil(timeout: .seconds(20)) { !shown.isEmpty }, "marked once the session arrived")
        #expect(shown == ["/tmp/mock-project"])
        // Marked once, not at every later change of the thread.
        try await late.renameThread(id, to: "Renamed")
        #expect(await waitUntil(timeout: .seconds(10)) { workspace.session(id)?.title == "Renamed" })
        #expect(shown.count == 1)
        workspace.close()
        await late.stop()
        await stop(fixture)
    }
}
