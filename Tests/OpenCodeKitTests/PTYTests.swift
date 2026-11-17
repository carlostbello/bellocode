import Foundation
import MockOpenCode
import Testing

@testable import OpenCodeKit

@Suite("PTY wire format")
struct PTYWireTests {
    @Test func inputFrameLayout() {
        let frame = PTYWire.inputFrame(Array("ls\r".utf8), size: PTYSize(cols: 300, rows: 40))
        #expect([UInt8](frame) == [1, 0x01, 0x2C, 0x00, 0x28] + Array("ls\r".utf8))
        let resize = PTYWire.resizeFrame(PTYSize(cols: 80, rows: 24))
        #expect([UInt8](resize) == [0, 0, 80, 0, 24])
        let decoded = PTYWire.decodeClientFrame(frame)
        #expect(decoded?.isInput == true)
        #expect(decoded?.size == PTYSize(cols: 300, rows: 40))
        #expect(decoded?.payload == Data("ls\r".utf8))
        #expect(PTYWire.decodeClientFrame(Data([1, 2])) == nil)
    }

    @Test func sizesAreClampedToTheWireRange() {
        let frame = PTYWire.resizeFrame(PTYSize(cols: 0, rows: 70_000))
        #expect(PTYWire.decodeClientFrame(frame)?.size == PTYSize(cols: 1, rows: 65_535))
    }

    @Test func decodesEveryControlMessage() {
        let attached = """
            {"type":"attached","attachmentID":"a1","inputProtocol":1,"role":"observer","generation":1,
             "info":{"size":{"cols":120,"rows":37}},
             "replay":{"requestedOffset":10,"availableOffset":994036,"endOffset":3091188,"truncated":true}}
            """
        #expect(
            PTYControlMessage.decode(attached)
                == .attached(
                    attachmentID: "a1", role: .observer, size: PTYSize(cols: 120, rows: 37),
                    replay: PTYReplayWindow(requestedOffset: 10, availableOffset: 994_036, endOffset: 3_091_188, truncated: true)))
        #expect(PTYControlMessage.decode(#"{"type":"replay_complete","endOffset":42}"#) == .replayComplete(endOffset: 42))
        #expect(PTYControlMessage.decode(#"{"type":"resized","cols":81,"rows":25,"checkpoint":""}"#) == .resized(PTYSize(cols: 81, rows: 25)))
        #expect(PTYControlMessage.decode(#"{"type":"controller_changed","attachmentID":"b"}"#) == .controllerChanged(attachmentID: "b"))
        #expect(PTYControlMessage.decode(#"{"type":"controller_changed"}"#) == .controllerChanged(attachmentID: nil))
        #expect(PTYControlMessage.decode(#"{"type":"exited","exitCode":3,"finalOffset":99}"#) == .exited(exitCode: 3, finalOffset: 99))
        #expect(PTYControlMessage.decode(#"{"type":"exited","finalOffset":99}"#) == .exited(exitCode: nil, finalOffset: 99))
        #expect(PTYControlMessage.decode(#"{"type":"title_changed","title":"vim"}"#) == .titleChanged("vim"))
        #expect(PTYControlMessage.decode(#"{"type":"foreground_process_changed","process":"top"}"#) == .foregroundProcessChanged("top"))
        #expect(PTYControlMessage.decode(#"{"type":"foreground_process_changed","process":null}"#) == .foregroundProcessChanged(nil))
        #expect(PTYControlMessage.decode(#"{"type":"something_new"}"#) == .unknown(type: "something_new"))
        #expect(PTYControlMessage.decode("not json") == nil)
        #expect(PTYControlMessage.decode(#"{"no":"type"}"#) == nil)
    }

    @Test func updateBodyDistinguishesClearingFromKeepingTheTitle() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func json(_ body: PTYUpdateRequest) throws -> String { String(decoding: try encoder.encode(body), as: UTF8.self) }
        #expect(try json(PTYUpdateRequest(size: PTYSize(cols: 2, rows: 3))) == #"{"size":{"cols":2,"rows":3}}"#)
        #expect(try json(PTYUpdateRequest(title: .some(nil))) == #"{"title":null}"#)
        #expect(try json(PTYUpdateRequest(title: "build")) == #"{"title":"build"}"#)
    }
}

@Suite("PTY stream state (reconnect from cursor)")
struct PTYStreamStateTests {
    @Test func freshEmulatorReplaysEverything() {
        var state = PTYStreamState()
        state.beginConnect()
        #expect(state.connectCursor == 0)
        let decision = state.attached(PTYReplayWindow(requestedOffset: 0, availableOffset: 0, endOffset: 500, truncated: false))
        #expect(decision == .reset(trimmed: false))
        state.received(500)
        state.replayComplete(endOffset: 500)
        state.received(20)
        #expect(state.offset == 520)
        #expect(state.phase == .live)
        #expect(state.connectCursor == 520)
    }

    @Test func reconnectWithContentAppendsOnlyTheGap() {
        var state = PTYStreamState(cursor: 520, emulatorHasContent: true)
        state.beginConnect()
        #expect(state.connectCursor == 520)
        let decision = state.attached(PTYReplayWindow(requestedOffset: 520, availableOffset: 520, endOffset: 600, truncated: false))
        #expect(decision == .append)
        state.received(80)
        state.replayComplete(endOffset: 600)
        #expect(state.offset == 600)
    }

    @Test func truncatedRingResetsTheEmulator() {
        var state = PTYStreamState(cursor: 100, emulatorHasContent: true)
        state.beginConnect()
        let decision = state.attached(
            PTYReplayWindow(requestedOffset: 100, availableOffset: 994_036, endOffset: 3_091_188, truncated: true))
        #expect(decision == .reset(trimmed: true))
        #expect(state.offset == 994_036)
        state.received(3_091_188 - 994_036)
        state.replayComplete(endOffset: 3_091_188)
        #expect(state.offset == 3_091_188)
    }

    @Test func serverBehindOurCursorResets() {
        // A server that has less output than we hold cannot be continued: rebuild from what it has.
        var state = PTYStreamState(cursor: 900, emulatorHasContent: true)
        state.beginConnect()
        let decision = state.attached(PTYReplayWindow(requestedOffset: 900, availableOffset: 300, endOffset: 300, truncated: false))
        #expect(decision == .reset(trimmed: true))
        #expect(state.offset == 300)
    }

    @Test func discardedEmulatorStartsOver() {
        var state = PTYStreamState(cursor: 900, emulatorHasContent: true)
        state.emulatorDiscarded()
        state.beginConnect()
        #expect(state.connectCursor == 0)
    }

    @Test func zeroCursorNeverClaimsContent() {
        let state = PTYStreamState(cursor: 0, emulatorHasContent: true)
        #expect(state.emulatorHasContent == false)
    }
}

@Suite("PTY output pipe")
struct PTYOutputPipeTests {
    @Test func coalescesAdjacentOutputAndKeepsOrder() async {
        let pipe = PTYOutputPipe(capacity: 1 << 20)
        await pipe.push(.reset(trimmed: false))
        await pipe.push(.output(Data("ab".utf8)))
        await pipe.push(.output(Data("cd".utf8)))
        await pipe.push(.control(.titleChanged("t")))
        await pipe.push(.output(Data("ef".utf8)))
        let batch = await pipe.next()
        #expect(batch == [.reset(trimmed: false), .output(Data("abcd".utf8)), .control(.titleChanged("t")), .output(Data("ef".utf8))])
        #expect(pipe.pendingBytes == 0)
        pipe.finish()
        #expect(await pipe.next() == nil)
    }

    @Test func producerWaitsAtCapacityAndNothingIsLost() async {
        let pipe = PTYOutputPipe(capacity: 1_000)
        let producer = Task {
            for index in 0..<200 { await pipe.push(.output(Data(repeating: UInt8(index % 256), count: 100))) }
            pipe.finish()
        }
        var total = 0
        var maxBatch = 0
        while let batch = await pipe.next() {
            for item in batch {
                if case .output(let data) = item {
                    total += data.count
                    maxBatch = max(maxBatch, data.count)
                }
            }
            #expect(pipe.pendingBytes <= 1_100)
        }
        await producer.value
        #expect(total == 20_000)
        #expect(maxBatch <= 1_100)
    }

    @Test func tooManyControlsFinishWithOverflow() async {
        let pipe = PTYOutputPipe(capacity: 1_000, controlLimit: 3)
        for _ in 0..<5 { await pipe.push(.control(.titleChanged("x"))) }
        #expect(pipe.overflowed)
        let batch = await pipe.next()
        #expect(batch?.count == 4)
        #expect(await pipe.next() == nil)
    }

    @Test func finishReleasesAWaitingConsumer() async {
        let pipe = PTYOutputPipe()
        let consumer = Task { await pipe.next() }
        try? await Task.sleep(for: .milliseconds(20))
        pipe.finish()
        #expect(await consumer.value == nil)
    }
}

@Suite("PTY client against the mock")
struct PTYClientMockTests {
    struct Fixture {
        let server: MockOpenCodeServer
        let client: OpenCodeClient
        let sessionID: String

        static func start() async throws -> Fixture {
            let server = MockOpenCodeServer(scenario: .empty(), options: .testing)
            let endpoint = try await server.start()
            let client = OpenCodeClient(
                connection: ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? "")))
            let session = try await client.createSession(SessionCreateRequest(directory: "/tmp/mock-project", title: "pty"))
            return Fixture(server: server, client: client, sessionID: session.id)
        }
    }

    /// Reads socket messages until `predicate` holds for the accumulated output, or fails after `limit` messages.
    static func read(
        _ socket: URLSessionPTYSocket, until predicate: (String, [PTYControlMessage]) -> Bool, limit: Int = 200
    ) async throws -> (String, [PTYControlMessage]) {
        var output = Data()
        var controls: [PTYControlMessage] = []
        for _ in 0..<limit {
            switch try await socket.receive() {
            case .output(let data): output.append(data)
            case .control(let message): controls.append(message)
            }
            if predicate(String(decoding: output, as: UTF8.self), controls) { break }
        }
        return (String(decoding: output, as: UTF8.self), controls)
    }

    @Test func createListResizeSnapshotDelete() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.server.stop() } }
        let client = fixture.client
        let info = try await client.createTerminal(
            sessionID: fixture.sessionID,
            PTYCreateRequest(command: "/bin/zsh", args: ["-l"], cwd: "/tmp/mock-project", title: "Terminal 1", size: PTYSize(cols: 100, rows: 30)))
        #expect(info.id.hasPrefix("pty"))
        #expect(info.status == .running)
        #expect(info.size == PTYSize(cols: 100, rows: 30))
        #expect(try await client.terminals(sessionID: fixture.sessionID).map(\.id) == [info.id])
        let resized = try await client.updateTerminal(info.id, PTYUpdateRequest(size: PTYSize(cols: 81, rows: 25), title: "build"))
        #expect(resized.size == PTYSize(cols: 81, rows: 25))
        #expect(resized.userTitle == "build")
        let snapshot = try await client.terminalSnapshot(info.id)
        #expect(snapshot.info.id == info.id)
        #expect(!snapshot.checkpoint.isEmpty)
        let read = try await client.readTerminal(sessionID: fixture.sessionID, lines: 5)
        #expect(read?.ptyID == info.id)
        try await client.deleteTerminal(info.id)
        #expect(try await client.terminals(sessionID: fixture.sessionID).isEmpty)
        await #expect(throws: OpenCodeError.self) { try await client.terminal(info.id) }
        do {
            _ = try await client.terminal(info.id)
        } catch let error as OpenCodeError {
            #expect(error.status == 404)
            #expect(error.tag?.rawValue == "PtyNotFoundError")
        }
    }

    @Test func socketAttachTypeReconnectFromCursorAndExit() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.server.stop() } }
        let client = fixture.client
        let info = try await client.createTerminal(
            sessionID: fixture.sessionID, PTYCreateRequest(cwd: "/tmp/mock-project", title: "t", size: PTYSize(cols: 80, rows: 24)))

        let first = URLSessionPTYSocket(request: try client.terminalConnectRequest(info.id, cursor: 0, attachmentID: "a1"))
        var state = PTYStreamState()
        state.beginConnect()
        var (output, controls) = try await Self.read(first) { _, controls in controls.contains { if case .replayComplete = $0 { true } else { false } } }
        guard case .attached(_, let role, _, let replay) = controls.first else {
            Issue.record("first message must be attached, got \(controls)")
            return
        }
        #expect(role == .controller)
        #expect(state.attached(replay) == .reset(trimmed: false))
        state.received(output.utf8.count)
        if case .replayComplete(let end) = controls.last { state.replayComplete(endOffset: end) }
        #expect(output.contains("$ "))

        first.send(PTYWire.inputFrame(Array("echo hi\r".utf8), size: PTYSize(cols: 90, rows: 20)))
        (output, _) = try await Self.read(first) { text, _ in text.contains("hi\r\n") && text.hasSuffix("\u{7}") }
        state.received(output.utf8.count)
        #expect(await fixture.server.ptySize(info.id) == PTYSize(cols: 90, rows: 20))
        first.close()

        // Output written while detached is replayed from our cursor, and only that.
        try await Task.sleep(for: .milliseconds(50))
        await fixture.server.writeToPTY(info.id, "while-away\r\n")
        let second = URLSessionPTYSocket(request: try client.terminalConnectRequest(info.id, cursor: state.connectCursor, attachmentID: "a2"))
        state.beginConnect()
        (output, controls) = try await Self.read(second) { _, controls in controls.contains { if case .replayComplete = $0 { true } else { false } } }
        guard case .attached(_, _, _, let replay2) = controls.first else {
            Issue.record("expected attached")
            return
        }
        #expect(state.attached(replay2) == .append)
        #expect(output == "while-away\r\n")

        // A second controller without takeover is refused with 4404.
        let intruder = URLSessionPTYSocket(request: try client.terminalConnectRequest(info.id, cursor: 0, attachmentID: "a3"))
        do {
            while true { _ = try await intruder.receive() }
        } catch let closed as PTYSocketClosed {
            #expect(closed.reason == .unavailable)
        }

        // Exit: `exited` with the code, then a normal close; the server forgets the PTY.
        second.send(PTYWire.inputFrame(Array("exit 3\r".utf8), size: PTYSize(cols: 90, rows: 20)))
        var exit: PTYControlMessage?
        do {
            while true {
                if case .control(let message) = try await second.receive(), case .exited = message { exit = message }
            }
        } catch let closed as PTYSocketClosed {
            #expect(closed.reason == .normal)
        }
        guard case .exited(let code, _) = exit else {
            Issue.record("no exited frame")
            return
        }
        #expect(code == 3)
        #expect(try await client.terminals(sessionID: fixture.sessionID).isEmpty)
    }

    @Test func connectingToAMissingTerminalIsRejected() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.server.stop() } }
        let socket = URLSessionPTYSocket(request: try fixture.client.terminalConnectRequest("pty_missing", cursor: 0, attachmentID: "x"))
        do {
            _ = try await socket.receive()
            Issue.record("expected the upgrade to fail")
        } catch let closed as PTYSocketClosed {
            if case .rejected(let status) = closed.reason {
                #expect(status == 404)
            } else if case .failed = closed.reason {
                // URLSession may report a refused upgrade without exposing the response.
            } else {
                Issue.record("unexpected close \(closed.reason)")
            }
        }
    }
}
