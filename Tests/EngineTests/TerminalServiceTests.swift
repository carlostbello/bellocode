import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Synchronization
import Testing

@testable import Engine

/// Collects what a stream feeds an emulator.
final class RecordingSink: TerminalOutputSink {
    struct State {
        var output = Data()
        var resets: [Bool] = []
        var feeds = 0
    }

    let state = Mutex(State())

    func reset(trimmed: Bool) {
        state.withLock {
            $0.resets.append(trimmed)
            $0.output.removeAll()
        }
    }

    func feed(_ data: Data) {
        state.withLock {
            $0.output.append(data)
            $0.feeds += 1
        }
    }

    var text: String { state.withLock { String(decoding: $0.output, as: UTF8.self) } }
    var output: Data { state.withLock { $0.output } }
    var resets: [Bool] { state.withLock { $0.resets } }
}

/// `eventually` for main-actor tests: polls `condition` on the main actor.
@MainActor
func waitFor(
    _ message: String, timeout: Duration = .seconds(10), _ condition: @MainActor () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    if try await condition() { return }
    Issue.record("timed out: \(message)")
    throw CancellationError()
}

@MainActor
@Suite("Terminal service (mock PTYs)", .serialized, .timeLimit(.minutes(3)))
struct TerminalServiceTests {
    @MainActor
    struct Fixture {
        let harness: MockHarness
        let store: ProjectionStore
        let service: TerminalService
        let sessionID: SessionID

        static func start(store: ProjectionStore? = nil) async throws -> Fixture {
            let harness = try await MockHarness.start()
            let store = try store ?? ProjectionStore(location: .inMemory)
            let client = harness.client
            let session = try await client.createSession(SessionCreateRequest(directory: "/tmp/mock-project", title: "t"))
            let service = TerminalService(
                store: store, client: { client },
                launch: TerminalLaunch(command: "/bin/zsh", args: ["-l"], environment: ["TERM": "xterm-256color"]))
            return Fixture(harness: harness, store: store, service: service, sessionID: SessionID(session.id))
        }

        func service(sharing store: ProjectionStore) -> TerminalService {
            let client = harness.client
            return TerminalService(store: store, client: { client }, launch: service.launch)
        }

        func stop() async {
            await service.shutdown()
            await harness.stop()
        }
    }

    @Test func createRenameMoveSplitAndPersist() async throws {
        let fixture = try await Fixture.start()
        let terminals = fixture.service.terminals(for: fixture.sessionID)
        await terminals.waitUntilLoaded()
        let first = try #require(await terminals.create(directory: "/tmp/mock-project", size: PTYSize(cols: 100, rows: 30)))
        let second = try #require(await terminals.create(directory: "/tmp/mock-project/sub"))
        #expect(first.id.hasPrefix("pty"))
        #expect(first.displayTitle == "Terminal 1")
        #expect(second.displayTitle == "Terminal 2")
        #expect(terminals.selected(in: .drawer) == second.id)
        #expect(await fixture.harness.server.ptySize(first.id) == PTYSize(cols: 100, rows: 30))

        await terminals.rename(first.id, to: "  server  ")
        #expect(terminals.record(first.id)?.displayTitle == "server")
        #expect(try await fixture.harness.client.terminal(first.id).userTitle == "server")
        terminals.move(second.id, to: 0)
        #expect(terminals.records(in: .drawer).map(\.id) == [second.id, first.id])
        terminals.setSplit(first.id)
        terminals.setDrawer(open: true, height: 240.4)
        let third = try #require(await terminals.create(directory: "/tmp/mock-project", placement: .panel))
        #expect(terminals.selected(in: .panel) == third.id)
        #expect(terminals.selected(in: .drawer) == second.id)
        await terminals.save()

        // A new service (an app relaunch) restores the set from the store, then reconciles with the server.
        let relaunched = fixture.service(sharing: fixture.store).terminals(for: fixture.sessionID)
        await relaunched.waitUntilLoaded()
        #expect(relaunched.records(in: .drawer).map(\.id) == [second.id, first.id])
        #expect(relaunched.records(in: .panel).map(\.id) == [third.id])
        #expect(relaunched.set.splitSecondary == first.id)
        #expect(relaunched.set.isDrawerOpen == true)
        #expect(relaunched.set.drawerHeight == 240)
        #expect(relaunched.record(first.id)?.displayTitle == "server")
        await relaunched.refresh()
        #expect(relaunched.records(in: .drawer).allSatisfy { $0.state == .running })
        await fixture.stop()
    }

    @Test func streamTypesResizesDetachesAndReplaysOnlyTheGap() async throws {
        let fixture = try await Fixture.start()
        let server = fixture.harness.server
        let terminals = fixture.service.terminals(for: fixture.sessionID)
        let record = try #require(await terminals.create(directory: "/tmp/mock-project", size: PTYSize(cols: 80, rows: 24)))
        let sink = RecordingSink()
        let stream = fixture.service.makeStream(record.id, in: terminals, sink: sink)
        stream.resize(to: PTYSize(cols: 120, rows: 40))
        stream.activate()
        try await waitFor("live") { stream.status == .live }
        try await waitFor("prompt") { sink.text.contains("$ ") }
        #expect(stream.sentSize == PTYSize(cols: 120, rows: 40))

        // Typing goes out with the current size; output comes back through the sink.
        stream.send(Array("echo hello\r".utf8))
        try await waitFor("echo output") { sink.text.contains("\u{7}hello\r\n") }

        // A burst of layout passes sends only the final size.
        for cols in stride(from: 119, through: 90, by: -1) { stream.resize(to: PTYSize(cols: cols, rows: 30)) }
        try await waitFor("resized") { await server.ptySize(record.id) == PTYSize(cols: 90, rows: 30) }
        try await Task.sleep(for: .milliseconds(100))
        let resizes = await server.ptyInputLog(record.id).filter { $0.hasPrefix("resize:") }
        #expect(resizes == ["resize:120x40", "resize:90x30"], "intermediate sizes must not reach the PTY")

        // Detach; output written meanwhile is replayed on re-attach, and nothing before it is repeated.
        stream.deactivate()
        try await waitFor("detached on server") { await server.ptyAttachmentCount(record.id) == 0 }
        await server.writeToPTY(record.id, "while away\r\n")
        let before = sink.output
        stream.activate()
        try await waitFor("gap replayed") { sink.text.hasSuffix("while away\r\n") }
        #expect(sink.resets.count == 1, "only the first attach resets the emulator")
        #expect(sink.output == before + Data("while away\r\n".utf8))
        #expect(sink.output == (await server.ptyOutput(record.id)))
        await fixture.stop()
    }

    @Test func reconnectsAfterADropWithoutLosingOrRepeatingOutput() async throws {
        let fixture = try await Fixture.start()
        let server = fixture.harness.server
        let terminals = fixture.service.terminals(for: fixture.sessionID)
        let record = try #require(await terminals.create(directory: "/tmp/mock-project"))
        let sink = RecordingSink()
        let stream = fixture.service.makeStream(record.id, in: terminals, sink: sink)
        stream.resize(to: PTYSize(cols: 80, rows: 24))
        stream.activate()
        try await waitFor("live") { stream.status == .live }
        try await waitFor("prompt") { sink.text.contains("$ ") }
        for round in 0..<3 {
            await server.dropPTYSockets()
            await server.writeToPTY(record.id, "after drop \(round)\r\n")
            try await waitFor("reconnected \(round)") { stream.status == .live && sink.text.hasSuffix("after drop \(round)\r\n") }
        }
        stream.send(Array("seq 2000\r".utf8))
        try await waitFor("seq output") { sink.text.contains("2000\r\n") }
        try await waitFor("all output") { sink.output == (await server.ptyOutput(record.id)) }
        #expect(sink.resets.count == 1)
        await fixture.stop()
    }

    @Test func exitCodeIsKeptLocallyAndRestartReplacesTheTab() async throws {
        let fixture = try await Fixture.start()
        let server = fixture.harness.server
        let terminals = fixture.service.terminals(for: fixture.sessionID)
        let first = try #require(await terminals.create(directory: "/tmp/mock-project"))
        let second = try #require(await terminals.create(directory: "/tmp/mock-project"))
        let sink = RecordingSink()
        let stream = fixture.service.makeStream(first.id, in: terminals, sink: sink)
        stream.resize(to: PTYSize(cols: 80, rows: 24))
        stream.activate()
        try await waitFor("live") { stream.status == .live }
        stream.send(Array("exit 7\r".utf8))
        try await waitFor("exited") { terminals.record(first.id)?.state == .exited(code: 7) }
        #expect(stream.status == .ended)
        #expect(terminals.record(first.id)?.state.label == "exited (7)")
        // The server forgot it at once; the code survives a relaunch because it is ours.
        #expect(try await fixture.harness.client.terminals(sessionID: fixture.sessionID.rawValue).map(\.id) == [second.id])
        await terminals.save()
        let relaunched = fixture.service(sharing: fixture.store).terminals(for: fixture.sessionID)
        await relaunched.waitUntilLoaded()
        await relaunched.refresh()
        #expect(relaunched.record(first.id)?.state == .exited(code: 7))

        let restarted = try #require(await terminals.restart(first.id))
        #expect(restarted.id != first.id)
        #expect(terminals.records(in: .drawer).map(\.id) == [restarted.id, second.id])
        #expect(restarted.state == .running)
        #expect(await server.ptyIDs().contains(restarted.id))
        await fixture.stop()
    }

    @Test func reconcileMarksVanishedTerminalsAndAdoptsTheAgents() async throws {
        let fixture = try await Fixture.start()
        let server = fixture.harness.server
        let terminals = fixture.service.terminals(for: fixture.sessionID)
        let mine = try #require(await terminals.create(directory: "/tmp/mock-project"))
        // The agent (or another client) opens a terminal in the same session.
        let agents = try await fixture.harness.client.createTerminal(
            sessionID: fixture.sessionID.rawValue, PTYCreateRequest(title: "agent build", env: [:]))
        await terminals.refresh()
        #expect(terminals.records(in: .drawer).map(\.id) == [mine.id, agents.id])
        #expect(terminals.record(agents.id)?.displayTitle == "agent build")

        // The server restarts and forgets every PTY: our records end, labelled, and stay restartable.
        await server.discardPTYs()
        await terminals.refresh()
        #expect(terminals.record(mine.id)?.state == .ended(reason: "Ended while BelloCode was away"))
        #expect(!terminals.isStale)

        // Offline: nothing changes, the records are marked stale.
        await fixture.harness.stop()
        await terminals.refresh()
        #expect(terminals.isStale)
        #expect(terminals.records(in: .drawer).count == 2)
        await fixture.service.shutdown()
    }

    @Test func truncatedReplayResetsTheEmulatorFirst() async throws {
        let fixture = try await Fixture.start()
        let server = fixture.harness.server
        await server.setPTYRetention(4_096)
        let terminals = fixture.service.terminals(for: fixture.sessionID)
        let record = try #require(await terminals.create(directory: "/tmp/mock-project"))
        let sink = RecordingSink()
        let stream = fixture.service.makeStream(record.id, in: terminals, sink: sink)
        stream.resize(to: PTYSize(cols: 80, rows: 24))
        stream.activate()
        try await waitFor("prompt") { sink.text.contains("$ ") }
        stream.deactivate()
        try await waitFor("detached") { await server.ptyAttachmentCount(record.id) == 0 }
        await server.writeToPTY(record.id, String(repeating: "z", count: 10_000))
        stream.activate()
        try await waitFor("replayed") { sink.output.count == 4_096 }
        #expect(sink.resets == [false, true])
        #expect(sink.output == (await server.ptyOutput(record.id)))
        await fixture.stop()
    }

    @Test func anotherControllerMakesTheStreamReadOnlyUntilTakeover() async throws {
        let fixture = try await Fixture.start()
        let server = fixture.harness.server
        let terminals = fixture.service.terminals(for: fixture.sessionID)
        let record = try #require(await terminals.create(directory: "/tmp/mock-project"))
        let other = URLSessionPTYSocket(
            request: try fixture.harness.client.terminalConnectRequest(record.id, cursor: 0, attachmentID: "other"))
        _ = try await other.receive()
        let sink = RecordingSink()
        let stream = fixture.service.makeStream(record.id, in: terminals, sink: sink)
        stream.resize(to: PTYSize(cols: 80, rows: 24))
        stream.activate()
        try await waitFor("observing") { stream.status == .observing }
        stream.send(Array("echo ignored\r".utf8))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!(await server.ptyInputLog(record.id)).contains { $0.contains("ignored") })
        stream.takeControl()
        try await waitFor("controller") { stream.status == .live }
        stream.send(Array("echo mine\r".utf8))
        try await waitFor("typed") { sink.text.contains("\u{7}mine\r\n") }
        other.close()
        await fixture.stop()
    }

    @Test func closeDeletesOnTheServerAndIdlePolicyEndsQuietTerminals() async throws {
        let fixture = try await Fixture.start()
        let server = fixture.harness.server
        let terminals = fixture.service.terminals(for: fixture.sessionID)
        let a = try #require(await terminals.create(directory: "/tmp/mock-project"))
        let b = try #require(await terminals.create(directory: "/tmp/mock-project"))
        let c = try #require(await terminals.create(directory: "/tmp/mock-project"))
        await terminals.close(b.id)
        #expect(terminals.records(in: .drawer).map(\.id) == [a.id, c.id])
        #expect(terminals.selected(in: .drawer) == c.id)
        await terminals.close(c.id)
        #expect(terminals.selected(in: .drawer) == a.id)
        let d = try #require(await terminals.create(directory: "/tmp/mock-project"))
        #expect(await server.ptyIDs() == [a.id, d.id])

        let closed = await terminals.closeIdle(policy: .idle(for: 60), now: Date().addingTimeInterval(120))
        #expect(Set(closed) == [a.id, d.id])
        #expect(terminals.record(a.id)?.state == .ended(reason: "Closed while idle"))
        #expect(await server.ptyIDs().isEmpty)
        #expect(await terminals.closeIdle(policy: .never).isEmpty)
        await fixture.stop()
    }

    @Test func idlePolicyKeepsBusyTerminals() {
        let now = Date()
        var record = TerminalRecord(
            id: "pty_1", sessionID: SessionID("s"), title: "t", startDirectory: "/", lastActivity: now.addingTimeInterval(-600))
        let policy = TerminalIdlePolicy.idle(for: 300)
        #expect(policy.shouldClose(record, now))
        record.foregroundProcess = "vim"
        #expect(!policy.shouldClose(record, now))
        record.foregroundProcess = "/bin/zsh"
        #expect(policy.shouldClose(record, now))
        record.lastActivity = now
        #expect(!policy.shouldClose(record, now))
        record.state = .exited(code: 0)
        record.lastActivity = .distantPast
        #expect(!policy.shouldClose(record, now))
    }

    @Test func createFailureIsReportedAndLeavesNoRecord() async throws {
        let fixture = try await Fixture.start()
        await fixture.harness.server.injectHTTPFault(.status(503, method: "POST", pathPrefix: "/api/experimental/session", tag: "ServiceUnavailableError"))
        let terminals = fixture.service.terminals(for: fixture.sessionID)
        #expect(await terminals.create(directory: "/tmp/mock-project") == nil)
        #expect(terminals.set.records.isEmpty)
        #expect(terminals.lastError?.userMessage.contains("unavailable") == true)
        #expect(terminals.creatingCount == 0)
        await fixture.stop()
    }

    @Test func storeKeepsTerminalSetsAcrossRebuildAndBoundsRecords() async throws {
        let store = try ProjectionStore(location: .inMemory)
        var set = ThreadTerminalSet()
        for index in 0..<(ThreadTerminalSet.maxRecords + 5) {
            set.records.append(
                TerminalRecord(
                    id: "pty_\(index)", sessionID: SessionID("s"), title: "t", startDirectory: "/",
                    state: index < 10 ? .exited(code: 0) : .running))
        }
        set.trim()
        #expect(set.records.count == ThreadTerminalSet.maxRecords)
        #expect(set.records.first?.id == "pty_5")
        try await store.setTerminalSet(set, for: SessionID("s"))
        try await store.rebuild()
        #expect(try await store.terminalSet(SessionID("s")) == set)
        #expect(try await store.terminalSessionIDs() == [SessionID("s")])
        try await store.setTerminalSet(ThreadTerminalSet(), for: SessionID("s"))
        #expect(try await store.terminalSet(SessionID("s")) == nil)
    }
}
