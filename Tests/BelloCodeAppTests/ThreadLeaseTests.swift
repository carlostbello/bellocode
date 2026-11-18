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
        return Fixture(server: server, engine: engine, threads: threads)
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
}
