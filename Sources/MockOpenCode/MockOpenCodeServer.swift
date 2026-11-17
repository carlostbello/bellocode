import Foundation
import Network
import os

/// Where a running mock listens and how to authenticate.
public struct MockOpenCodeEndpoint: Sendable, Equatable {
    public var url: URL
    public var username: String
    public var password: String?

    /// `Basic …` for the `Authorization` header, or `nil` when auth is off.
    public var authorizationHeader: String? {
        password.map { "Basic " + Data("\(username):\($0)".utf8).base64EncodedString() }
    }
}

/// How outgoing event-stream bytes are cut into separate writes (fault injection).
public enum ByteSplitting: Sendable, Equatable {
    /// One write per batch of frames.
    case none
    /// Pieces of exactly `n` bytes (`fixed(1)` splits inside every UTF-8 sequence and every SSE line).
    case fixed(Int)
    /// Pieces of 1...`maxPiece` bytes from a seeded generator, so a failing split is reproducible.
    case seeded(seed: UInt64, maxPiece: Int)
}

/// A scripted failure for matching HTTP requests.
public struct HTTPFault: Sendable {
    public enum Action: Sendable {
        /// Respond with this status and body instead of the real route (body may be malformed on purpose).
        case respond(status: Int, body: String, contentType: String)
        /// Wait, then serve the real route.
        case delay(Duration)
        /// Close the connection without any response.
        case resetConnection
        /// Serve the real route (its effects happen), then close the connection without sending the response: a lost
        /// answer to a request the server applied.
        case dropResponse
        /// Serve the real route (its effects and events happen), then hold the answer until
        /// `MockOpenCodeServer.releaseResponses(gate:)`: forces "the event arrives before the HTTP answer".
        case holdResponse(gate: String)
        /// Hold the request before routing until `releaseResponses(gate:)`, then handle it as if it arrived then
        /// (faults injected meanwhile apply): forces "this request reaches the server after what the test did".
        case holdRequest(gate: String)
    }

    public var method: String?
    /// Matches a request whose path starts with this.
    public var pathPrefix: String
    public var action: Action
    /// How many requests the fault applies to; `nil` for every request until cleared.
    public var count: Int?

    public init(method: String? = nil, pathPrefix: String, action: Action, count: Int? = 1) {
        self.method = method
        self.pathPrefix = pathPrefix
        self.action = action
        self.count = count
    }

    /// The real server's error envelope with the given status.
    public static func status(
        _ status: Int, method: String? = nil, pathPrefix: String, tag: String = "UnknownError",
        message: String = "Injected failure", count: Int? = 1
    ) -> HTTPFault {
        let body: JSONValue = ["_tag": .string(tag), "message": .string(message)]
        return HTTPFault(
            method: method, pathPrefix: pathPrefix,
            action: .respond(status: status, body: body.serialized, contentType: "application/json"), count: count)
    }

    func matches(_ request: HTTPRequest) -> Bool {
        (method == nil || method == request.method) && request.path.hasPrefix(pathPrefix)
    }
}

/// A scriptable fake opencode v2 server on 127.0.0.1, faithful to the pinned wire format for the routes it serves.
///
/// ```swift
/// let server = MockOpenCodeServer(scenario: .empty(), options: .testing)
/// let endpoint = try await server.start()
/// await server.enqueueScript(.fullTour)
/// // drive endpoint.url with URLSession or OpenCodeKit …
/// await server.stop()
/// ```
///
/// All state lives in this actor. Each connection runs in its own task that only touches the socket, so a slow
/// event-stream reader never blocks requests or other subscribers; its frames queue here up to
/// ``MockServerOptions/subscriberQueueLimit``, after which that one connection is dropped.
public actor MockOpenCodeServer {
    public nonisolated let options: MockServerOptions
    let log = Logger(subsystem: "dev.bellocode.mock", category: "server")
    let signposter = OSSignposter(subsystem: "dev.bellocode.mock", category: .pointsOfInterest)

    // MARK: State

    var state: ServerState
    /// Integrations, credentials, login attempts and saved permission rules (IntegrationRoutes.swift).
    var integration: IntegrationState
    /// Scripted repositories, turn diffs, staged reverts and worktrees (VCSRoutes.swift).
    var vcs = MockVCSState()
    var ids: IdentifierGenerator
    var virtualNow: Int64

    // MARK: Network

    private let queue = DispatchQueue(label: "dev.bellocode.mock.network")
    private var listener: LoopbackListener?
    private var acceptTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var connections: [Int: ConnectionRecord] = [:]
    private var nextConnectionID = 0
    private(set) var endpoint: MockOpenCodeEndpoint?

    // MARK: Events

    private var subscribers: [Int: Subscriber] = [:]
    private var duplicateNext = false
    private var eventLog: [JSONValue] = []
    private let eventLogLimit = 50_000
    private var splitting: ByteSplitting = .none
    private var pieceDelay: Duration?
    private var httpFaults: [HTTPFault] = []
    private var dropAfterFrames: Int?
    /// Event types whose frames are held back (tests force "the HTTP answer arrives before the event").
    private var heldEventTypes: Set<String> = []
    private var heldEvents: [(type: String, frame: Data)] = []
    /// Answers held at a gate, waiting for `releaseResponses(gate:)`.
    private var heldResponses: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// The last requests received ("METHOD path"), oldest first, for failure diagnostics in tests.
    private var requestLog: [String] = []
    private let requestLogLimit = 2_000
    /// Turn runners waiting for subscribers to drain (virtual clock only; see ``sleep(milliseconds:)``).
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private let drainThreshold = 256

    // MARK: Turns

    var turns: [String: TurnHandle] = [:]
    /// Sessions whose turn was killed by `crashAndRestart()`: their turn ends without any event or idle state, as
    /// when the real process dies (opencode keeps such sessions busy).
    var crashedSessions: Set<String> = []
    /// Added to the reported pid, so a crash restart looks like a new server process.
    var pidGeneration = 0
    var turnGeneration = 0
    var pendingInbox: [String: [InboxItem]] = [:]
    var waiters: [String: Waiter] = [:]
    var queuedScripts: [TurnScript] = []
    /// Bodies of admitted `prompt` requests, oldest first (bounded), for tests that check the request shape.
    var recordedPrompts: [JSONValue] = [] {
        didSet { if recordedPrompts.count > 200 { recordedPrompts.removeFirst(recordedPrompts.count - 200) } }
    }
    /// `session.command` runs: session, name, argument text (bounded).
    var recordedCommands: [(sessionID: String, name: String, text: String)] = [] {
        didSet { if recordedCommands.count > 200 { recordedCommands.removeFirst(recordedCommands.count - 200) } }
    }
    var queuedSessionScripts: [String: [TurnScript]] = [:]
    /// Persistent PTYs and their WebSocket attachments (PTYRoutes.swift).
    var pty = MockPTYState()
    /// Client-MCP sockets, where the mock plays opencode's MCP client (ClientMCPRoutes.swift).
    var clientMCP = MockClientMCPState()
    /// The simulated `experimental.browser` plugin and session instruction entries (BrowserRoutes.swift).
    var browser = MockBrowserState()
    /// Observes each streamed text/reasoning delta after it is published (harness latency measurements).
    var deltaObserver: (@Sendable (_ messageID: String, _ utf8Length: Int, _ uptime: Double) -> Void)?

    public init(scenario: Scenario = .empty(), options: MockServerOptions = MockServerOptions()) {
        self.options = options
        state = ServerState(scenario: scenario)
        integration = IntegrationState(integrations: scenario.integrations)
        ids = IdentifierGenerator(seed: scenario.seed)
        virtualNow = scenario.startTime
    }

    // MARK: Lifecycle

    /// Binds 127.0.0.1 on an ephemeral port. Calling it again while running returns the same endpoint.
    @discardableResult
    public func start() async throws -> MockOpenCodeEndpoint {
        if let endpoint { return endpoint }
        let listener = try await LoopbackListener.start(queue: queue)
        self.listener = listener
        let endpoint = MockOpenCodeEndpoint(
            url: URL(string: "http://127.0.0.1:\(listener.port)")!, username: "opencode", password: options.password)
        self.endpoint = endpoint
        acceptTask = Task { [connections = listener.connections] in
            for await connection in connections {
                self.accept(connection)
            }
        }
        if let interval = options.heartbeatInterval {
            heartbeatTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { return }
                    self.broadcastHeartbeat()
                }
            }
        }
        log.debug("listening on port \(listener.port, privacy: .public)")
        return endpoint
    }

    /// Stops listening, drops every connection and cancels running turns. State is kept.
    public func stop() {
        closeNetwork()
        for handle in turns.values { handle.task.cancel() }
        for id in Array(waiters.keys) { resumeWaiter(id, with: .interrupted) }
        for gate in Array(heldResponses.keys) { releaseResponses(gate: gate) }
    }

    /// Simulates a server restart: every connection drops and the server comes back on a new port with the same
    /// data. Running turns keep going, so events published while nobody is connected are lost, exactly the gap a
    /// client must recover from by re-reading the list endpoints.
    @discardableResult
    public func restart() async throws -> MockOpenCodeEndpoint {
        closeNetwork()
        return try await start()
    }

    /// Simulates the server process dying mid-turn and a new one starting (a new pid, a new port, the same data):
    /// running turns stop where they are, publish nothing more, and their sessions stay busy.
    @discardableResult
    public func crashAndRestart() async throws -> MockOpenCodeEndpoint {
        crashedSessions.formUnion(turns.keys)
        for handle in turns.values { handle.task.cancel() }
        for id in Array(waiters.keys) { resumeWaiter(id, with: .interrupted) }
        pidGeneration += 1
        closeNetwork()
        return try await start()
    }

    private func closeNetwork() {
        acceptTask?.cancel()
        acceptTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        listener?.stop()
        listener = nil
        endpoint = nil
        for id in Array(subscribers.keys) { closeSubscriber(id, abrupt: true) }
        for record in connections.values {
            record.io.reset()
            record.task.cancel()
        }
        connections.removeAll()
    }

    /// Serves until `input` closes, like `opencode serve --stdio`: writes one JSON line to `output` with the URL (and,
    /// unlike the real server, the password, because the caller cannot choose it), then waits for end of input and
    /// stops. Point the app at it with `BELLOCODE_SERVER_URL` and `BELLOCODE_SERVER_PASSWORD` (docs/spikes/mock-opencode.md).
    public static func runStandalone(
        scenario: Scenario = .demo(), options: MockServerOptions = MockServerOptions(clock: .realTime),
        input: FileHandle = .standardInput, output: FileHandle = .standardOutput
    ) async throws {
        let server = MockOpenCodeServer(scenario: scenario, options: options)
        let endpoint = try await server.start()
        let line: JSONValue = .compact([
            ("url", .string(endpoint.url.absoluteString)), ("password", endpoint.password.map(JSONValue.string)),
        ])
        output.write(Data((line.serialized + "\n").utf8))
        do {
            for try await _ in input.bytes {}
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    // MARK: Fault injection and control

    /// The next prompt (for `sessionID`, or any session when `nil`) plays `script`. Scripts queue in order.
    /// The `prompt` request bodies received so far, oldest first (at most 200).
    public func promptBodies() -> [JSONValue] { recordedPrompts }

    /// The `session.command` runs received so far (at most 200).
    public func commandRuns() -> [(sessionID: String, name: String, text: String)] { recordedCommands }

    public func enqueueScript(_ script: TurnScript, for sessionID: String? = nil) {
        if let sessionID {
            queuedSessionScripts[sessionID, default: []].append(script)
        } else {
            queuedScripts.append(script)
        }
    }

    public func setDefaultScript(_ script: TurnScript) { state.defaultScript = script }

    /// Calls `observer` after each streamed text or reasoning delta is published, with the message ID, the block's
    /// UTF-8 length so far and the monotonic time (`DispatchTime` uptime, seconds). For latency measurements.
    public func setDeltaObserver(_ observer: (@Sendable (_ messageID: String, _ utf8Length: Int, _ uptime: Double) -> Void)?) {
        deltaObserver = observer
    }
    public func addScripts(_ scripts: [String: TurnScript]) { state.scripts.merge(scripts) { $1 } }

    /// How event-stream bytes are cut into writes from now on, and an optional pause between pieces.
    public func setEventSplitting(_ splitting: ByteSplitting, pieceDelay: Duration? = nil) {
        self.splitting = splitting
        self.pieceDelay = pieceDelay
    }

    /// Drops every open event stream: frames already published are flushed, then the connection closes without the
    /// terminating chunk, as when the server dies mid-stream. Later events never reach those streams. New
    /// subscriptions work normally.
    public func dropEventStreams() {
        for id in Array(subscribers.keys) {
            guard var subscriber = subscribers[id] else { continue }
            subscriber.dropRequested = true
            let waiter = subscriber.waiter
            subscriber.waiter = nil
            subscribers[id] = subscriber
            waiter?.resume(returning: takeBatch(id))
        }
    }

    /// Drops each event stream after it has been sent `frames` more frames; `nil` turns this off.
    public func dropEventStreams(afterFrames frames: Int?) { dropAfterFrames = frames }

    /// The next published event is delivered twice with the same `id`.
    public func duplicateNextEvent() { duplicateNext = true }

    public func injectHTTPFault(_ fault: HTTPFault) { httpFaults.append(fault) }

    /// From now on, events of these types are held back (in order) instead of being sent; other events flow. The
    /// event log still records them when published.
    public func holdEvents(types: Set<String>) { heldEventTypes = types }

    /// Sends the first `count` held events (all if nil) to the subscribers connected now, in published order. Holding
    /// stays on for later events until `holdEvents(types: [])`.
    public func releaseHeldEvents(count: Int? = nil) {
        let taken = min(count ?? heldEvents.count, heldEvents.count)
        let release = heldEvents.prefix(taken)
        heldEvents.removeFirst(taken)
        for event in release {
            for id in Array(subscribers.keys) where subscribers[id]?.accepts(event.type) == true { enqueue(event.frame, to: id) }
        }
    }

    /// Events held back and not yet released.
    public var heldEventCount: Int { heldEvents.count }

    /// Requests or answers waiting at `gate`.
    public func heldResponseCount(gate: String) -> Int { heldResponses[gate]?.count ?? 0 }

    /// Sends every answer waiting at `gate`.
    public func releaseResponses(gate: String) {
        for waiter in heldResponses.removeValue(forKey: gate) ?? [] { waiter.resume() }
    }
    public func clearHTTPFaults() { httpFaults.removeAll() }

    // MARK: Observation

    /// Every event published so far (without heartbeats), oldest first, bounded to the last 50,000.
    public func publishedEvents() -> [JSONValue] { eventLog }

    /// The last 2,000 requests received ("METHOD path", before faults and auth), oldest first.
    public func recordedRequests() -> [String] { requestLog }

    public var subscriberCount: Int { subscribers.count }

    /// Returns when `sessionID` has no running or queued turn.
    public func waitUntilIdle(_ sessionID: String) async {
        while let handle = turns[sessionID] {
            await handle.task.value
        }
    }

    /// Returns when no session has a running turn.
    public func waitUntilAllIdle() async {
        while let handle = turns.values.first {
            await handle.task.value
        }
    }

    public func session(_ id: String) -> MockSession? { state.sessions[id] }
    public func messages(_ sessionID: String) -> [MockMessage] { state.messages[sessionID] ?? [] }
    public func pendingPermissions() -> [MockPermission] { state.permissions }
    public func pendingForms() -> [MockForm] { state.forms }

    // MARK: Clock

    func now() -> Int64 {
        switch options.clock {
        case .virtual: virtualNow
        case .realTime: Int64(Date().timeIntervalSince1970 * 1000)
        }
    }

    func sleep(milliseconds: Double) async throws {
        try Task.checkCancellation()
        switch options.clock {
        case .virtual:
            virtualNow += Int64(milliseconds.rounded(.up))
            await Task.yield()
            // With no real time passing, a fast script could outrun the sockets and overflow a subscriber's queue.
            // The virtual clock therefore waits for connected subscribers to drain: deterministic, never lossy.
            while subscribers.values.contains(where: { $0.pending.count > drainThreshold }) {
                await withCheckedContinuation { drainWaiters.append($0) }
            }
        case .realTime:
            if milliseconds > 0 { try await Task.sleep(for: .microseconds(Int(milliseconds * 1000))) }
        }
        try Task.checkCancellation()
    }

    func makeID(_ prefix: String, descending: Bool = false) -> String {
        ids.make(prefix, time: now(), descending: descending)
    }

    // MARK: Events

    /// Publishes one event in the real envelope: `id`, `created`, `type`, `location?`, `data`, `durable?`.
    func publish(
        _ type: String, _ data: JSONValue, location: String? = nil, durable aggregateID: String? = nil, version: Int = 1
    ) {
        let interval = signposter.beginInterval("publish")
        defer { signposter.endInterval("publish", interval) }
        var pairs: [(String, JSONValue)] = [
            ("id", .string(makeID("evt"))), ("created", .int(Int(now()))), ("type", .string(type)),
        ]
        if let location { pairs.append(("location", ["directory": .string(location)])) }
        pairs.append(("data", data))
        if let aggregateID {
            let seq = state.nextSeq(aggregateID)
            pairs.append(("durable", ["aggregateID": .string(aggregateID), "seq": .int(seq), "version": .int(version)]))
        }
        let event = JSONValue.object(pairs)
        if eventLog.count >= eventLogLimit { eventLog.removeFirst(eventLogLimit / 10) }
        eventLog.append(event)
        let frame = Data(("data: " + event.serialized + "\n\n").utf8)
        if heldEventTypes.contains(type) {
            heldEvents.append((type, frame))
            return
        }
        let copies = duplicateNext ? 2 : 1
        duplicateNext = false
        for id in Array(subscribers.keys) {
            guard let subscriber = subscribers[id], subscriber.accepts(type) else { continue }
            for _ in 0..<copies { enqueue(frame, to: id) }
        }
    }

    private func broadcastHeartbeat() {
        for id in Array(subscribers.keys) { enqueue(Self.heartbeatFrame, to: id) }
    }

    static let heartbeatFrame = Data(": heartbeat\n\n".utf8)

    private func enqueue(_ frame: Data, to id: Int) {
        guard var subscriber = subscribers[id], !subscriber.closed, !subscriber.dropRequested else { return }
        if subscriber.pending.count >= options.subscriberQueueLimit {
            log.notice("event subscriber \(id) overflowed; dropping its connection")
            closeSubscriber(id, abrupt: true)
            return
        }
        subscriber.pending.append(frame)
        if let waiter = subscriber.waiter {
            subscriber.waiter = nil
            subscribers[id] = subscriber
            waiter.resume(returning: takeBatch(id))
        } else {
            subscribers[id] = subscriber
        }
    }

    private func takeBatch(_ id: Int) -> EventBatch? {
        guard var subscriber = subscribers[id] else { return nil }
        if subscriber.pending.isEmpty, !subscriber.dropRequested { return nil }
        var frames = subscriber.pending
        subscriber.pending.removeAll(keepingCapacity: true)
        var dropAfter = subscriber.dropRequested
        if let limit = subscriber.remainingBeforeDrop {
            if frames.count >= limit {
                frames = Array(frames.prefix(limit))
                dropAfter = true
            }
            subscriber.remainingBeforeDrop = limit - frames.count
        }
        subscribers[id] = subscriber
        releaseDrainWaiters()
        return EventBatch(frames: frames, splitting: splitting, pieceDelay: pieceDelay, dropAfter: dropAfter)
    }

    /// The next frames for a subscriber, waiting if there are none; `nil` once the subscriber is closed.
    func nextBatch(_ id: Int) async -> EventBatch? {
        guard let subscriber = subscribers[id] else { return nil }
        if !subscriber.pending.isEmpty || subscriber.dropRequested { return takeBatch(id) }
        if subscriber.closed { return nil }
        return await withCheckedContinuation { continuation in
            subscribers[id]?.waiter = continuation
        }
    }

    func closeSubscriber(_ id: Int, abrupt: Bool) {
        guard var subscriber = subscribers.removeValue(forKey: id) else { return }
        subscriber.closed = true
        subscriber.waiter?.resume(returning: nil)
        releaseDrainWaiters()
        if abrupt, let record = connections[subscriber.connectionID] {
            record.io.reset()
        }
    }

    private func releaseDrainWaiters() {
        guard !drainWaiters.isEmpty, !subscribers.values.contains(where: { $0.pending.count > drainThreshold }) else {
            return
        }
        let waiting = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    func openSubscriber(connectionID: Int, types: Set<String>?) -> Int {
        nextConnectionID += 1
        let id = nextConnectionID
        let connected: JSONValue = ["id": .string(makeID("evt")), "type": "server.connected", "data": [:]]
        subscribers[id] = Subscriber(
            connectionID: connectionID, types: types,
            pending: [Data(("data: " + connected.serialized + "\n\n").utf8), Self.heartbeatFrame],
            remainingBeforeDrop: dropAfterFrames)
        return id
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        nextConnectionID += 1
        let id = nextConnectionID
        let io = ConnectionIO(connection: connection)
        io.start(queue: queue)
        let task = Task {
            await Self.serve(io, connectionID: id, server: self)
            self.connectionEnded(id)
        }
        connections[id] = ConnectionRecord(io: io, task: task)
    }

    private func connectionEnded(_ id: Int) {
        connections.removeValue(forKey: id)
        for (subscriberID, subscriber) in subscribers where subscriber.connectionID == id {
            closeSubscriber(subscriberID, abrupt: false)
        }
        closePTYSubscribers(connectionID: id)
    }

    /// Applies injected faults, then auth, then routing.
    func plan(for request: HTTPRequest, connectionID: Int) async -> ResponsePlan {
        let interval = signposter.beginInterval("request")
        defer { signposter.endInterval("request", interval) }
        if requestLog.count >= requestLogLimit { requestLog.removeFirst(requestLogLimit / 10) }
        requestLog.append("\(request.method) \(request.path)")
        var delay: Duration?
        var dropResponse = false
        var holdGate: String?
        if let index = httpFaults.firstIndex(where: { $0.matches(request) }) {
            let fault = httpFaults[index]
            if let count = fault.count {
                if count <= 1 { httpFaults.remove(at: index) } else { httpFaults[index].count = count - 1 }
            }
            switch fault.action {
            case let .respond(status, body, contentType):
                return .response(HTTPResponse(status: status, headers: [("content-type", contentType)], body: Data(body.utf8)))
            case .resetConnection:
                return .reset
            case let .delay(duration):
                delay = duration
            case .dropResponse:
                dropResponse = true
            case let .holdResponse(gate):
                holdGate = gate
            case let .holdRequest(gate):
                await withCheckedContinuation { heldResponses[gate, default: []].append($0) }
                return await plan(for: request, connectionID: connectionID)
            }
        }
        if let delay { try? await Task.sleep(for: delay) }
        // Each request moves the virtual clock by 1 ms, so request-driven changes get distinct, ordered timestamps.
        if options.clock == .virtual { virtualNow += 1 }
        if let unauthenticated = authenticate(request) { return .response(unauthenticated) }
        let plan = await route(request, connectionID: connectionID)
        if let holdGate { await withCheckedContinuation { heldResponses[holdGate, default: []].append($0) } }
        return dropResponse ? .reset : plan
    }

    private func authenticate(_ request: HTTPRequest) -> HTTPResponse? {
        guard let password = options.password else { return nil }
        let expected = "Basic " + Data("opencode:\(password)".utf8).base64EncodedString()
        if request.method == "GET", ["/", "/doc", "/health"].contains(request.path) { return nil }
        if request.headers["authorization"] == expected { return nil }
        var response = HTTPResponse.error(401, tag: "UnauthorizedError", message: "Authentication required")
        response.headers.insert(("www-authenticate", "Basic realm=\"Secure Area\""), at: 0)
        return response
    }

    /// One connection: parse requests, answer them, keep the connection alive, or stream events.
    @concurrent
    private static func serve(_ io: ConnectionIO, connectionID: Int, server: MockOpenCodeServer) async {
        var parser = HTTPRequestParser()
        while !Task.isCancelled {
            let request: HTTPRequest
            do {
                guard let next = try parser.next() else {
                    guard let data = try await io.receive() else { break }
                    parser.append(data)
                    continue
                }
                request = next
            } catch let error as HTTPParseError {
                try? await io.send(error.response.serialized(keepAlive: false))
                io.finish()
                return
            } catch {
                break
            }

            switch await server.plan(for: request, connectionID: connectionID) {
            case let .response(response):
                let keepAlive = !request.wantsClose
                do {
                    try await io.send(response.serialized(keepAlive: keepAlive))
                } catch {
                    return
                }
                if !keepAlive {
                    io.finish()
                    return
                }
            case .reset:
                io.reset()
                return
            case let .eventStream(subscriberID):
                await streamEvents(io, subscriberID: subscriberID, server: server)
                return
            case let .ptySocket(subscriberID, handshake):
                await streamPTY(io, parser: parser, subscriberID: subscriberID, handshake: handshake, server: server)
                return
            case let .longPoll(id):
                await serveLongPoll(io, id: id, server: server)
                return
            }
        }
        io.finish()
    }

    /// A long-poll request (a plugin RPC `attach`): answers when the server settles it and closes the connection, or
    /// tells the server the client went away when the peer closes first.
    @concurrent
    private static func serveLongPoll(_ io: ConnectionIO, id: Int, server: MockOpenCodeServer) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while true {
                    guard let data = try? await io.receive() else { break }
                    if data.isEmpty { continue }
                }
                await server.abandonLongPoll(id)
            }
            group.addTask {
                if let response = await server.longPollResponse(id) {
                    try? await io.send(response.serialized(keepAlive: false))
                }
                io.finish()
            }
            await group.waitForAll()
        }
    }

    /// A PTY WebSocket: writes the attachment's frames and reads the client's until either side closes.
    @concurrent
    private static func streamPTY(
        _ io: ConnectionIO, parser: HTTPRequestParser, subscriberID: Int, handshake: Data, server: MockOpenCodeServer
    ) async {
        do {
            try await io.send(handshake)
        } catch {
            await server.closePTYSubscriber(subscriberID)
            io.reset()
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var frames = WebSocket.Parser()
                frames.append(parser.remainder)
                while !Task.isCancelled {
                    do {
                        while let message = try frames.next() {
                            await server.ptySocketMessage(subscriberID, message)
                            if case .close = message { return }
                        }
                        guard let data = try await io.receive() else { break }
                        frames.append(data)
                    } catch {
                        break
                    }
                }
                await server.closePTYSubscriber(subscriberID)
            }
            group.addTask {
                while let batch = await server.nextPTYBatch(subscriberID) {
                    var bytes = Data()
                    for frame in batch.frames { bytes.append(frame) }
                    if let close = batch.close, !batch.abrupt { bytes.append(WebSocket.close(code: close.code, reason: close.reason)) }
                    if !bytes.isEmpty { try? await io.send(bytes) }
                    if batch.close != nil {
                        if batch.abrupt { io.reset() } else { io.finish() }
                        return
                    }
                }
                io.finish()
            }
            await group.next()
            group.cancelAll()
            io.reset()
        }
    }

    @concurrent
    private static func streamEvents(_ io: ConnectionIO, subscriberID: Int, server: MockOpenCodeServer) async {
        do {
            try await io.send(HTTPResponse.eventStreamHead())
            var splitter = ByteSplitter(.none)
            while let batch = await server.nextBatch(subscriberID) {
                if batch.splitting != splitter.mode { splitter = ByteSplitter(batch.splitting) }
                var bytes = Data()
                for frame in batch.frames { bytes.append(frame) }
                for piece in splitter.split(bytes) {
                    try await io.send(HTTPResponse.chunk(piece))
                    if let delay = batch.pieceDelay { try await Task.sleep(for: delay) }
                }
                if batch.dropAfter {
                    // Flushed frames stay delivered; the body just stops without its terminating chunk.
                    await server.closeSubscriber(subscriberID, abrupt: false)
                    io.finish()
                    return
                }
            }
            // Closed by the server: graceful closes end the chunked body; abrupt ones already reset the socket.
            try? await io.send(HTTPResponse.lastChunk)
            io.finish()
        } catch {
            io.reset()
        }
    }
}

// MARK: - Support types

struct ConnectionRecord {
    let io: ConnectionIO
    let task: Task<Void, Never>
}

struct Subscriber {
    let connectionID: Int
    let types: Set<String>?
    var pending: [Data]
    var remainingBeforeDrop: Int?
    var waiter: CheckedContinuation<EventBatch?, Never>?
    var closed = false
    var dropRequested = false

    func accepts(_ type: String) -> Bool { types?.contains(type) ?? true }
}

struct EventBatch: Sendable {
    let frames: [Data]
    let splitting: ByteSplitting
    let pieceDelay: Duration?
    let dropAfter: Bool
}

enum ResponsePlan: Sendable {
    case response(HTTPResponse)
    case eventStream(subscriberID: Int)
    /// Upgrade to a PTY WebSocket: send `handshake` (101), then frames.
    case ptySocket(subscriberID: Int, handshake: Data)
    /// Answer later (a pending plugin RPC such as `attach`); see `serveLongPoll`.
    case longPoll(id: Int)
    case reset
}

/// Cuts a byte stream into pieces according to a ``ByteSplitting`` mode.
struct ByteSplitter {
    let mode: ByteSplitting
    private var random: SeededRandom

    init(_ mode: ByteSplitting) {
        self.mode = mode
        if case let .seeded(seed, _) = mode { random = SeededRandom(seed: seed) } else { random = SeededRandom(seed: 0) }
    }

    mutating func split(_ data: Data) -> [Data] {
        let size: () -> Int
        switch mode {
        case .none: return data.isEmpty ? [] : [data]
        case let .fixed(n):
            let n = max(1, n)
            size = { n }
        case let .seeded(_, maxPiece):
            var generator = random
            defer { random = generator }
            var pieces: [Data] = []
            var offset = data.startIndex
            while offset < data.endIndex {
                let length = min(generator.int(in: 1...max(1, maxPiece)), data.endIndex - offset)
                pieces.append(data[offset..<(offset + length)])
                offset += length
            }
            return pieces
        }
        var pieces: [Data] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let length = min(size(), data.endIndex - offset)
            pieces.append(data[offset..<(offset + length)])
            offset += length
        }
        return pieces
    }
}
