import Foundation
import OpenCodeKit

/// One persistent PTY in the mock, backed by `MockShell`.
struct MockPTY: Sendable {
    var id: String
    var sessionID: String
    var title: String
    var userTitle: String?
    var command: String
    var args: [String]
    var cwd: String
    var size: PTYSize
    var pid: Int
    var shell: MockShell
    var foregroundProcess: String?
    /// The retained output ring (the last `retention` bytes) and the total output written.
    var buffer = Data()
    var tail = 0
    var controller: Int?

    var head: Int { tail - buffer.count }

    func json() -> JSONValue {
        .object([
            ("id", .string(id)), ("title", .string(userTitle ?? title)), ("command", .string(command)),
            ("args", .array(args.map(JSONValue.string))), ("cwd", .string(shell.cwd)), ("status", "running"),
            ("pid", .int(pid)), ("sessionID", .string(sessionID)), ("userTitle", userTitle.map(JSONValue.string) ?? .null),
            ("foregroundProcess", foregroundProcess.map(JSONValue.string) ?? .null),
            ("size", ["cols": .int(size.cols), "rows": .int(size.rows)]),
            ("output", ["head": .int(head), "tail": .int(tail)]),
        ])
    }
}

/// A WebSocket attachment to a mock PTY: encoded frames waiting to be written, and how it ends.
struct PTYSubscriber: Sendable {
    let ptyID: String
    let connectionID: Int
    let attachmentID: String
    var role: PTYRole
    var pending: [Data] = []
    var waiter: CheckedContinuation<PTYSocketBatch?, Never>?
    /// Close the socket with this code after the pending frames.
    var closeAfter: (code: UInt16, reason: String)?
    var abrupt = false
}

struct PTYSocketBatch: Sendable {
    var frames: [Data]
    var close: (code: UInt16, reason: String)?
    var abrupt: Bool
}

/// The mock's persistent-PTY state.
struct MockPTYState: Sendable {
    var ptys: [String: MockPTY] = [:]
    var order: [String] = []
    var subscribers: [Int: PTYSubscriber] = [:]
    var nextSubscriberID = 0
    var nextPID = 40_000
    /// Bytes of output each PTY keeps for replay (the real daemon keeps 2 MiB).
    var retention = 2 << 20
    /// Exit codes of PTYs that exited (tests; the server API forgets them, as the real one does).
    var exitCodes: [String: Int] = [:]
    /// Client frames received, per PTY (input payloads and resize sizes), bounded.
    var inputLog: [String: [String]] = [:]
    static let subscriberFrameLimit = 4_096
}

extension MockOpenCodeServer {
    // MARK: Routes

    func routePTY(_ method: String, _ parts: [String], _ request: HTTPRequest, connectionID: Int) -> ResponsePlan? {
        guard parts.count >= 4, parts[0] == "api", parts[1] == "experimental" else { return nil }
        let tail = Array(parts.dropFirst(2))
        switch (method, tail) {
        case ("POST", let p) where p.count == 3 && p[0] == "session" && p[2] == "terminal":
            return .response(createPTY(sessionID: p[1], request))
        case ("GET", let p) where p.count == 3 && p[0] == "session" && p[2] == "terminal":
            guard state.sessions[p[1]] != nil else { return .response(Self.sessionNotFound(p[1])) }
            let list = pty.order.compactMap { pty.ptys[$0] }.filter { $0.sessionID == p[1] }.map { $0.json() }
            return .response(.json(["data": .array(list)]))
        case ("GET", let p) where p.count == 4 && p[0] == "session" && p[2] == "terminal" && p[3] == "read":
            return .response(readPTY(sessionID: p[1], request))
        case ("GET", let p) where p.count == 2 && p[0] == "persistent-pty":
            return .response(withPTY(p[1]) { .json(["data": $0.json()]) })
        case ("PUT", let p) where p.count == 2 && p[0] == "persistent-pty":
            return .response(updatePTY(p[1], request))
        case ("DELETE", let p) where p.count == 2 && p[0] == "persistent-pty":
            guard pty.ptys[p[1]] != nil else { return .response(Self.ptyNotFound(p[1])) }
            endPTY(p[1], exitCode: nil, closeCode: 1000)
            return .response(.noContent())
        case ("GET", let p) where p.count == 3 && p[0] == "persistent-pty" && p[2] == "snapshot":
            return .response(withPTY(p[1]) { pty in
                let checkpoint = pty.buffer.suffix(4096)
                return .json([
                    "data": [
                        "info": pty.json(), "text": .string(Self.screenText(pty.buffer, rows: pty.size.rows)),
                        "checkpoint": .string(Data(checkpoint).base64EncodedString()), "cursor": ["x": 0, "y": 0],
                    ],
                ])
            })
        case ("GET", let p) where p.count == 3 && p[0] == "persistent-pty" && p[2] == "connect":
            return connectPTY(p[1], request, connectionID: connectionID)
        default:
            return nil
        }
    }

    static func ptyNotFound(_ id: String) -> HTTPResponse {
        .error(404, tag: "PtyNotFoundError", message: "Persistent terminal not found: \(id)", extra: [("ptyID", .string(id))])
    }

    private func withPTY(_ id: String, _ body: (MockPTY) -> HTTPResponse) -> HTTPResponse {
        guard let found = pty.ptys[id] else { return Self.ptyNotFound(id) }
        return body(found)
    }

    private func createPTY(sessionID: String, _ request: HTTPRequest) -> HTTPResponse {
        guard let session = state.sessions[sessionID] else { return Self.sessionNotFound(sessionID) }
        let body: JSONValue
        switch jsonBody(request) {
        case let .failure(error): return error
        case let .success(value): body = value
        }
        guard body["args"]?.arrayValue != nil, let title = body["title"]?.stringValue, body["env"]?.objectValue != nil else {
            return Self.invalid("Missing key\n  at [\"args\"]")
        }
        let size = PTYSize(cols: body["size"]?["cols"]?.intValue ?? 80, rows: body["size"]?["rows"]?.intValue ?? 24)
        let cwd = body["cwd"]?.stringValue ?? session.directory
        pty.nextPID += 1
        let id = makeID("pty_persistent")
        var record = MockPTY(
            id: id, sessionID: sessionID, title: title, command: body["command"]?.stringValue ?? "/bin/zsh",
            args: body["args"]?.arrayValue?.compactMap(\.stringValue) ?? [], cwd: cwd, size: size, pid: pty.nextPID,
            shell: MockShell(cwd: cwd))
        let effect = record.shell.start()
        pty.ptys[id] = record
        pty.order.append(id)
        record = pty.ptys[id]!
        appendOutput(id, effect.output)
        return .json(["data": pty.ptys[id]!.json()])
    }

    private func updatePTY(_ id: String, _ request: HTTPRequest) -> HTTPResponse {
        guard pty.ptys[id] != nil else { return Self.ptyNotFound(id) }
        let body: JSONValue
        switch jsonBody(request) {
        case let .failure(error): return error
        case let .success(value): body = value
        }
        if let cols = body["size"]?["cols"]?.intValue, let rows = body["size"]?["rows"]?.intValue {
            resizePTY(id, PTYSize(cols: cols, rows: rows))
        }
        if let title = body["title"] {
            pty.ptys[id]?.userTitle = title.stringValue
            broadcast(id, WebSocket.text(JSONValue.object([("type", "title_changed"), ("title", .string(pty.ptys[id]!.userTitle ?? pty.ptys[id]!.title))]).serialized))
        }
        return .json(["data": pty.ptys[id]!.json()])
    }

    private func readPTY(sessionID: String, _ request: HTTPRequest) -> HTTPResponse {
        guard state.sessions[sessionID] != nil else { return Self.sessionNotFound(sessionID) }
        guard let current = pty.order.reversed().compactMap({ pty.ptys[$0] }).first(where: { $0.sessionID == sessionID }) else {
            return .json(["data": .null])
        }
        let rows = Int(request.queryValue("lines") ?? "") ?? current.size.rows
        return .json([
            "data": [
                "ptyID": .string(current.id), "title": .string(current.userTitle ?? current.title),
                "cwd": .string(current.shell.cwd),
                "foregroundProcess": current.foregroundProcess.map(JSONValue.string) ?? .null,
                "screen": [
                    "text": .string(Self.screenText(current.buffer, rows: rows)), "cols": .int(current.size.cols),
                    "rows": .int(current.size.rows), "cursor": ["x": 0, "y": 0],
                ],
            ],
        ])
    }

    /// The last `rows` lines of output with escape sequences removed (an approximation of the screen).
    static func screenText(_ output: Data, rows: Int) -> String {
        let text = String(decoding: output.suffix(64 * 1024), as: UTF8.self)
        let stripped = text.replacingOccurrences(
            of: "\u{1B}(\\][^\u{7}\u{1B}]*(\u{7}|\u{1B}\\\\)|\\[[0-9;?]*[ -/]*[@-~]|.)", with: "", options: .regularExpression)
        let lines = stripped.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        return lines.suffix(max(1, rows)).joined(separator: "\n")
    }

    // MARK: WebSocket attach

    private func connectPTY(_ id: String, _ request: HTTPRequest, connectionID: Int) -> ResponsePlan {
        guard let record = pty.ptys[id] else { return .response(Self.ptyNotFound(id)) }
        guard WebSocket.isUpgrade(request), let key = request.headers["sec-websocket-key"] else {
            return .response(.error(400, tag: "InvalidRequestError", message: "Expected a WebSocket upgrade"))
        }
        let cursor = max(0, Int(request.queryValue("cursor") ?? "0") ?? 0)
        let wantsObserver = request.queryValue("role") == "observer"
        let takeover = request.queryValue("takeover") == "true"
        let attachmentID = request.queryValue("attachment_id") ?? makeID("att")
        pty.nextSubscriberID += 1
        let subscriberID = pty.nextSubscriberID
        var subscriber = PTYSubscriber(
            ptyID: id, connectionID: connectionID, attachmentID: attachmentID, role: wantsObserver ? .observer : .controller)

        if subscriber.role == .controller, let current = record.controller, current != subscriberID, pty.subscribers[current] != nil {
            if takeover {
                pty.subscribers[current]?.role = .observer
                pty.ptys[id]?.controller = subscriberID
                broadcast(id, WebSocket.text(JSONValue.object([("type", "controller_changed"), ("attachmentID", .string(attachmentID))]).serialized))
            } else {
                subscriber.closeAfter = (4404, "terminal unavailable")
                pty.subscribers[subscriberID] = subscriber
                return .ptySocket(subscriberID: subscriberID, handshake: WebSocket.handshake(key: key))
            }
        } else if subscriber.role == .controller {
            pty.ptys[id]?.controller = subscriberID
        }

        let available = min(max(cursor, record.head), record.tail)
        let replay = record.buffer.suffix(record.tail - available)
        let attached: JSONValue = .object([
            ("type", "attached"), ("attachmentID", .string(attachmentID)), ("inputProtocol", 1), ("info", record.json()),
            ("role", .string(subscriber.role.rawValue)), ("generation", 1),
            ("replay", [
                "requestedOffset": .int(cursor), "availableOffset": .int(available), "endOffset": .int(record.tail),
                "truncated": .bool(cursor < record.head),
            ]),
        ])
        subscriber.pending.append(WebSocket.text(attached.serialized))
        if !replay.isEmpty { subscriber.pending.append(WebSocket.frame(.binary, Data(replay))) }
        subscriber.pending.append(WebSocket.text(JSONValue.object([("type", "replay_complete"), ("endOffset", .int(record.tail))]).serialized))
        pty.subscribers[subscriberID] = subscriber
        return .ptySocket(subscriberID: subscriberID, handshake: WebSocket.handshake(key: key))
    }

    /// A message from a PTY socket's client.
    func ptySocketMessage(_ subscriberID: Int, _ message: WebSocket.Message) {
        guard let subscriber = pty.subscribers[subscriberID] else { return }
        if clientMCP.peers[subscriberID] != nil {
            switch message {
            case .text(let text): clientMCPFrame(subscriberID, text)
            case .ping(let payload): enqueuePTYFrame(WebSocket.frame(.pong, payload), to: subscriberID)
            case .close: closePTYSubscriber(subscriberID)
            case .binary: break
            }
            return
        }
        switch message {
        case .binary(let data):
            guard subscriber.role == .controller, pty.ptys[subscriber.ptyID]?.controller == subscriberID,
                let frame = PTYWire.decodeClientFrame(data)
            else { return }
            let id = subscriber.ptyID
            if frame.size.cols > 0, frame.size.rows > 0, frame.size != pty.ptys[id]?.size {
                resizePTY(id, frame.size)
            }
            logInput(id, frame.isInput ? "input:\(String(decoding: frame.payload, as: UTF8.self))" : "resize:\(frame.size)")
            if frame.isInput, !frame.payload.isEmpty { runShell(id, frame.payload) }
        case .text:
            break
        case .ping(let payload):
            enqueuePTYFrame(WebSocket.frame(.pong, payload), to: subscriberID)
        case .close:
            closePTYSubscriber(subscriberID)
        }
    }

    private func logInput(_ id: String, _ entry: String) {
        var log = pty.inputLog[id, default: []]
        log.append(entry)
        if log.count > 500 { log.removeFirst(log.count - 500) }
        pty.inputLog[id] = log
    }

    private func runShell(_ id: String, _ bytes: Data) {
        guard var record = pty.ptys[id] else { return }
        let effect = record.shell.input(bytes, size: (record.size.cols, record.size.rows))
        if let title = effect.title { record.title = title }
        if let foreground = effect.foregroundProcess { record.foregroundProcess = foreground }
        pty.ptys[id] = record
        appendOutput(id, effect.output)
        if let title = effect.title {
            broadcast(id, WebSocket.text(JSONValue.object([("type", "title_changed"), ("title", .string(title))]).serialized))
        }
        if let foreground = effect.foregroundProcess {
            broadcast(id, WebSocket.text(JSONValue.object([("type", "foreground_process_changed"), ("process", foreground.map(JSONValue.string) ?? .null)]).serialized))
        }
        if let code = effect.exitCode { endPTY(id, exitCode: code, closeCode: 1000) }
    }

    private func resizePTY(_ id: String, _ size: PTYSize) {
        guard pty.ptys[id] != nil else { return }
        pty.ptys[id]?.size = size
        broadcast(id, WebSocket.text(JSONValue.object([("type", "resized"), ("cols", .int(size.cols)), ("rows", .int(size.rows)), ("checkpoint", "")]).serialized))
    }

    private func appendOutput(_ id: String, _ data: Data) {
        guard !data.isEmpty, var record = pty.ptys[id] else { return }
        record.buffer.append(data)
        record.tail += data.count
        if record.buffer.count > pty.retention { record.buffer = Data(record.buffer.suffix(pty.retention)) }
        pty.ptys[id] = record
        // Live output in frames of at most 64 KiB, as a pty read loop would deliver it.
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + 65_536, data.endIndex)
            broadcast(id, WebSocket.frame(.binary, Data(data[offset..<end])))
            offset = end
        }
    }

    /// The PTY exits (or is deleted): every attachment gets `exited` and close; the PTY is forgotten at once.
    private func endPTY(_ id: String, exitCode: Int?, closeCode: UInt16) {
        guard let record = pty.ptys[id] else { return }
        let exited: JSONValue = .compact([
            ("type", "exited"), ("exitCode", exitCode.map(JSONValue.int)), ("finalOffset", .int(record.tail)),
        ])
        broadcast(id, WebSocket.text(exited.serialized))
        for (subscriberID, subscriber) in pty.subscribers where subscriber.ptyID == id {
            pty.subscribers[subscriberID]?.closeAfter = (closeCode, "")
            wake(subscriberID)
        }
        pty.ptys[id] = nil
        pty.order.removeAll { $0 == id }
        if let exitCode { pty.exitCodes[id] = exitCode }
    }

    private func broadcast(_ id: String, _ frame: Data) {
        for (subscriberID, subscriber) in pty.subscribers where subscriber.ptyID == id && subscriber.closeAfter == nil {
            enqueuePTYFrame(frame, to: subscriberID)
        }
    }

    func enqueuePTYFrame(_ frame: Data, to subscriberID: Int) {
        guard var subscriber = pty.subscribers[subscriberID], subscriber.closeAfter == nil else { return }
        if subscriber.pending.count >= MockPTYState.subscriberFrameLimit {
            subscriber.abrupt = true
            subscriber.closeAfter = (1011, "overflow")
        } else {
            subscriber.pending.append(frame)
        }
        pty.subscribers[subscriberID] = subscriber
        wake(subscriberID)
    }

    private func wake(_ subscriberID: Int) {
        guard var subscriber = pty.subscribers[subscriberID], let waiter = subscriber.waiter else { return }
        subscriber.waiter = nil
        pty.subscribers[subscriberID] = subscriber
        waiter.resume(returning: takePTYBatch(subscriberID))
    }

    private func takePTYBatch(_ subscriberID: Int) -> PTYSocketBatch? {
        guard var subscriber = pty.subscribers[subscriberID] else { return nil }
        guard !subscriber.pending.isEmpty || subscriber.closeAfter != nil else { return nil }
        let batch = PTYSocketBatch(frames: subscriber.pending, close: subscriber.closeAfter, abrupt: subscriber.abrupt)
        subscriber.pending.removeAll()
        pty.subscribers[subscriberID] = subscriber
        if batch.close != nil { closePTYSubscriber(subscriberID) }
        return batch
    }

    /// The next frames to write to a PTY socket, waiting if none; nil once the attachment is gone.
    func nextPTYBatch(_ subscriberID: Int) async -> PTYSocketBatch? {
        guard let subscriber = pty.subscribers[subscriberID] else { return nil }
        if !subscriber.pending.isEmpty || subscriber.closeAfter != nil { return takePTYBatch(subscriberID) }
        return await withCheckedContinuation { continuation in
            pty.subscribers[subscriberID]?.waiter = continuation
        }
    }

    func closePTYSubscriber(_ subscriberID: Int) {
        guard let subscriber = pty.subscribers.removeValue(forKey: subscriberID) else { return }
        subscriber.waiter?.resume(returning: nil)
        clientMCPClosed(subscriberID)
        if pty.ptys[subscriber.ptyID]?.controller == subscriberID { pty.ptys[subscriber.ptyID]?.controller = nil }
    }

    func closePTYSubscribers(connectionID: Int) {
        for (id, subscriber) in pty.subscribers where subscriber.connectionID == connectionID { closePTYSubscriber(id) }
    }

    // MARK: Test control

    /// IDs of running PTYs, oldest first.
    public func ptyIDs() -> [String] { pty.order }

    /// Everything a PTY has written that is still retained.
    public func ptyOutput(_ id: String) -> Data? { pty.ptys[id]?.buffer }

    /// The current grid size of a PTY.
    public func ptySize(_ id: String) -> PTYSize? { pty.ptys[id]?.size }

    /// Client frames received for a PTY (`input:…`, `resize:COLSxROWS`), oldest first.
    public func ptyInputLog(_ id: String) -> [String] { pty.inputLog[id] ?? [] }

    /// The exit code recorded for a PTY that exited.
    public func ptyExitCode(_ id: String) -> Int? { pty.exitCodes[id] }

    /// Number of WebSocket attachments to a PTY.
    public func ptyAttachmentCount(_ id: String) -> Int { pty.subscribers.values.filter { $0.ptyID == id }.count }

    /// Writes output as if the program in the PTY printed it.
    public func writeToPTY(_ id: String, _ text: String) { appendOutput(id, Data(text.utf8)) }

    /// Writes raw output bytes.
    public func writeToPTY(_ id: String, bytes: Data) { appendOutput(id, bytes) }

    /// The program exits with `code`.
    public func exitPTY(_ id: String, code: Int) { endPTY(id, exitCode: code, closeCode: 1000) }

    /// Drops every PTY socket without a close frame (a network blip). PTYs keep running.
    public func dropPTYSockets() {
        for (id, subscriber) in pty.subscribers {
            pty.subscribers[id]?.abrupt = true
            pty.subscribers[id]?.closeAfter = (1006, "dropped")
            if subscriber.waiter != nil { wake(id) }
        }
    }

    /// How many bytes of output each PTY retains for replay (default 2 MiB, like the real daemon).
    public func setPTYRetention(_ bytes: Int) { pty.retention = max(1, bytes) }

    /// Forgets every PTY at once without `exited` frames, as when the server restarts.
    public func discardPTYs() {
        for id in Array(pty.subscribers.keys) {
            pty.subscribers[id]?.abrupt = true
            pty.subscribers[id]?.closeAfter = (1006, "gone")
            wake(id)
        }
        pty.ptys.removeAll()
        pty.order.removeAll()
    }
}
