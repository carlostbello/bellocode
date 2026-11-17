import BelloCore
import Foundation
import Observation
import OpenCodeKit
import Synchronization
import os

/// Receives a terminal's output in order, off the main actor (AGENTS.md rule 7). Implementations must be safe to call
/// from any thread; the emulator parses there (SwiftTerm's `TerminalFeedSender`).
public protocol TerminalOutputSink: Sendable {
    /// Clear the screen and scrollback (the replay that follows rebuilds them). `trimmed`: older output is gone.
    func reset(trimmed: Bool)
    /// Output bytes, coalesced: one call per batch of socket frames.
    func feed(_ data: Data)
}

/// The connection state of a stream, for the pane's status line. Never colour-only in the UI.
public enum TerminalStreamStatus: Sendable, Hashable {
    /// Not attached (the terminal is not shown).
    case detached
    case connecting
    /// Attached as the controller (keystrokes go to the PTY).
    case live
    /// Attached read-only: another client controls the PTY. `TerminalStream.takeControl()` takes over.
    case observing
    /// The socket dropped; reconnecting from the cursor (attempt n).
    case reconnecting(attempt: Int)
    /// The PTY is gone (exited or ended); see the record's state.
    case ended
}

/// An emulator's position in a PTY's output, kept across detach and re-attach of the same emulator so a re-attach
/// replays only what it missed. Shared between the stream's receive task and the main actor.
public final class TerminalStreamCursor: Sendable {
    private let state: Mutex<PTYStreamState>

    public init() { state = Mutex(PTYStreamState()) }

    public var offset: Int { state.withLock { $0.offset } }
    public var hasContent: Bool { state.withLock { $0.emulatorHasContent } }
    var connectCursor: Int { state.withLock { $0.connectCursor } }

    func beginConnect() { state.withLock { $0.beginConnect() } }
    func attached(_ replay: PTYReplayWindow) -> PTYStreamState.AttachDecision { state.withLock { $0.attached(replay) } }
    func received(_ count: Int) { state.withLock { $0.received(count) } }
    func replayComplete(endOffset: Int?) { state.withLock { $0.replayComplete(endOffset: endOffset) } }
    /// The emulator was cleared by the user (Clear): the next attach must replay from the start of what is kept.
    public func emulatorDiscarded() { state.withLock { $0.emulatorDiscarded() } }
}

/// Builds the socket for a connect request (tests inject fakes).
public typealias PTYSocketFactory = @Sendable (URLRequest) -> any PTYSocket

/// One terminal's WebSocket attachment: connect, replay from the cursor, live output into the sink, keystrokes and
/// resizes out, and reconnect with backoff after a drop (AGENTS.md rule 12: each reconnect asks for exactly the
/// bytes after the cursor, and resets the emulator when the server cannot continue it).
///
/// Ownership: created by `TerminalService.makeStream`, owned by the view that shows the terminal (one stream per
/// emulator). `activate()` when shown, `deactivate()` when hidden; the PTY keeps running on the server either way.
/// Threading: `@MainActor`; socket reads, decoding and feeding run off the main actor in the stream's task.
@MainActor
@Observable
public final class TerminalStream {
    public let terminalID: String
    public private(set) var status: TerminalStreamStatus = .detached
    /// The grid size last sent to the server.
    public private(set) var sentSize: PTYSize?
    public let cursor: TerminalStreamCursor

    @ObservationIgnored private let sink: any TerminalOutputSink
    @ObservationIgnored private let client: @Sendable () async throws -> OpenCodeClient
    @ObservationIgnored private let socketFactory: PTYSocketFactory
    @ObservationIgnored private weak var owner: ThreadTerminals?
    @ObservationIgnored private let socket = SocketHolder()
    @ObservationIgnored private let tasks = TaskBox()
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var desiredSize: PTYSize?
    @ObservationIgnored private var pendingInput = Data()
    @ObservationIgnored private var role: PTYRole = .controller
    @ObservationIgnored private var takeover = false
    @ObservationIgnored private var exitSeen = false
    @ObservationIgnored let attachmentID = "bellocode-" + UUID().uuidString.lowercased()
    @ObservationIgnored private let backoff = BackoffPolicy(initial: .milliseconds(250), maximum: .seconds(5))

    /// Keystrokes typed while not attached are kept up to this many bytes and sent on attach (bounded, rule 5).
    public static let pendingInputLimit = 64 * 1024
    /// Resizes are coalesced for this long, so a drag or a multi-pass layout sends only the final size (the spike saw
    /// vim scroll by a line when it observed an intermediate size).
    public static let resizeDebounce: Duration = .milliseconds(40)

    init(
        terminalID: String, owner: ThreadTerminals, sink: any TerminalOutputSink, cursor: TerminalStreamCursor,
        client: @escaping @Sendable () async throws -> OpenCodeClient, socketFactory: @escaping PTYSocketFactory
    ) {
        self.terminalID = terminalID
        self.owner = owner
        self.sink = sink
        self.cursor = cursor
        self.client = client
        self.socketFactory = socketFactory
    }

    isolated deinit {
        runTask?.cancel()
        socket.close()
    }

    // MARK: Lifecycle

    /// Attaches (if not already). Waits for a previous attachment of this emulator to drain first, so output is fed
    /// in order and the cursor matches what the emulator holds.
    public func activate() {
        guard runTask == nil, status != .ended else { return }
        status = .connecting
        let previous = tasks.take("drain")
        runTask = Task { [weak self] in
            await previous?.value
            await self?.run()
        }
    }

    /// Detaches; the PTY keeps running. Output already received is still fed to the emulator.
    public func deactivate() {
        guard let task = runTask else { return }
        runTask = nil
        generation += 1
        task.cancel()
        socket.close()
        tasks.set("drain", task)
        if status != .ended { status = .detached }
    }

    /// Takes control from another client (reconnects with `takeover`).
    public func takeControl() {
        guard status == .observing else { return }
        role = .controller
        takeover = true
        deactivate()
        activate()
    }

    // MARK: Input

    /// Bytes for the PTY (keystrokes, paste). Kept briefly while connecting; dropped while observing.
    public func send(_ bytes: some Collection<UInt8>) {
        switch status {
        case .live:
            if let size = sentSize ?? desiredSize { socket.send(PTYWire.inputFrame(bytes, size: size)) }
        case .connecting, .reconnecting, .detached:
            if pendingInput.count + bytes.count <= Self.pendingInputLimit { pendingInput.append(contentsOf: bytes) }
        case .observing, .ended:
            break
        }
    }

    /// The view's grid changed. Sent after `resizeDebounce` if still different from what the server has.
    public func resize(to size: PTYSize) {
        let size = size.clamped
        guard size != desiredSize else { return }
        desiredSize = size
        tasks.set("resize", Task { [weak self] in
            try? await Task.sleep(for: Self.resizeDebounce)
            guard !Task.isCancelled else { return }
            self?.flushResize()
        })
    }

    private func flushResize() {
        guard status == .live, let size = desiredSize, size != sentSize else { return }
        sentSize = size
        socket.send(PTYWire.resizeFrame(size))
    }

    // MARK: Connect loop

    private func run() async {
        var attempt = 0
        exitSeen = false
        while !Task.isCancelled {
            generation += 1
            let current = generation
            let client: OpenCodeClient
            do {
                client = try await self.client()
            } catch {
                attempt += 1
                status = .reconnecting(attempt: attempt)
                try? await Task.sleep(for: backoff.delay(forAttempt: attempt, random: systemRandomUnit()))
                continue
            }
            cursor.beginConnect()
            let request: URLRequest
            do {
                request = try client.terminalConnectRequest(
                    terminalID, cursor: cursor.connectCursor, attachmentID: attachmentID, role: role, takeover: takeover)
            } catch {
                break
            }
            takeover = false
            let socket = socketFactory(request)
            self.socket.set(socket)
            let signpost = TerminalSignposts.stream.beginInterval("attach")
            let outcome = await Self.pump(
                socket: socket, cursor: cursor, sink: sink,
                report: { [weak self] event in self?.handle(event, generation: current) })
            TerminalSignposts.stream.endInterval("attach", signpost)
            self.socket.set(nil)
            if Task.isCancelled { return }
            if exitSeen {
                status = .ended
                return
            }
            switch outcome {
            case .unavailable:
                // Another controller holds the PTY: show it read-only rather than fight over it.
                role = .observer
                attempt = 0
                continue
            case .rejected(let status) where status == 404:
                ended(reason: "Terminal ended")
                return
            case .normal, .rejected, .failed:
                if await isGone(client) {
                    ended(reason: "Terminal ended")
                    return
                }
                attempt = (status == .live || status == .observing) ? 1 : attempt + 1
                status = .reconnecting(attempt: attempt)
                try? await Task.sleep(for: backoff.delay(forAttempt: attempt, random: systemRandomUnit()))
            }
        }
    }

    private func isGone(_ client: OpenCodeClient) async -> Bool {
        do {
            _ = try await client.terminal(terminalID)
            return false
        } catch let error as OpenCodeError {
            return error.status == 404
        } catch {
            return false
        }
    }

    private func ended(reason: String) {
        status = .ended
        owner?.streamEnded(terminalID, reason: reason)
    }

    enum Event: Sendable {
        case attached(PTYRole)
        case control(PTYControlMessage)
        case activity
    }

    private func handle(_ event: Event, generation: Int) {
        guard generation == self.generation, !Task.isCancelled else { return }
        switch event {
        case .attached(let role):
            self.role = role
            status = role == .controller ? .live : .observing
            if role == .controller {
                // The server keeps the size of whoever resized last; send ours first, then what was typed meanwhile.
                if let size = desiredSize {
                    sentSize = size
                    socket.send(PTYWire.resizeFrame(size))
                }
                if !pendingInput.isEmpty, let size = sentSize {
                    socket.send(PTYWire.inputFrame(pendingInput, size: size))
                }
            }
            pendingInput.removeAll()
        case .control(let message):
            switch message {
            case .exited(let code, _):
                exitSeen = true
                status = .ended
                owner?.streamExited(terminalID, code: code)
            case .controllerChanged(let id):
                if let id, id != attachmentID, role == .controller {
                    role = .observer
                    status = .observing
                } else if id == attachmentID {
                    role = .controller
                    status = .live
                }
            case .resized(let size):
                if role == .controller, size != sentSize, let desired = desiredSize, desired == sentSize {
                    // Another client resized; ours is the visible one, so restore it.
                    socket.send(PTYWire.resizeFrame(desired))
                }
            case .titleChanged(let title):
                owner?.streamTitleChanged(terminalID, title: title)
            case .foregroundProcessChanged(let process):
                owner?.streamForegroundChanged(terminalID, process: process)
            case .attached, .replayComplete, .unknown:
                break
            }
        case .activity:
            owner?.streamActivity(terminalID)
        }
    }

    /// One socket's lifetime: a receive task decodes frames and tracks the cursor; a feed task takes coalesced batches
    /// from a bounded pipe and feeds the emulator, reporting control messages to the main actor in order.
    @concurrent
    private static func pump(
        socket: any PTYSocket, cursor: TerminalStreamCursor, sink: any TerminalOutputSink,
        report: @escaping @MainActor @Sendable (Event) -> Void
    ) async -> PTYSocketClose {
        let pipe = PTYOutputPipe()
        return await withTaskGroup(of: PTYSocketClose?.self) { group in
            group.addTask {
                defer { pipe.finish() }
                do {
                    while true {
                        switch try await socket.receive() {
                        case .output(let data):
                            cursor.received(data.count)
                            await pipe.push(.output(data))
                        case .control(let message):
                            switch message {
                            case .attached(_, let role, _, let replay):
                                if case .reset(let trimmed) = cursor.attached(replay) { await pipe.push(.reset(trimmed: trimmed)) }
                                await report(.attached(role))
                            case .replayComplete(let end):
                                cursor.replayComplete(endOffset: end)
                            default:
                                break
                            }
                            await pipe.push(.control(message))
                        }
                    }
                } catch let closed as PTYSocketClosed {
                    return closed.reason
                } catch {
                    return .failed(code: 0, reason: "cancelled")
                }
            }
            group.addTask {
                var lastActivity = ContinuousClock.now - .seconds(10)
                while let batch = await pipe.next() {
                    let signpost = TerminalSignposts.stream.beginInterval("feed")
                    for item in batch {
                        switch item {
                        case .reset(let trimmed): sink.reset(trimmed: trimmed)
                        case .output(let data):
                            sink.feed(data)
                            let now = ContinuousClock.now
                            if now - lastActivity > .seconds(1) {
                                lastActivity = now
                                await report(.activity)
                            }
                        case .control(let message):
                            await report(.control(message))
                        }
                    }
                    TerminalSignposts.stream.endInterval("feed", signpost)
                }
                if pipe.overflowed { socket.close() }
                return nil
            }
            var outcome: PTYSocketClose = .normal
            for await result in group {
                if let result { outcome = result }
            }
            if pipe.overflowed { outcome = .failed(code: 0, reason: "overflow") }
            return outcome
        }
    }
}

/// The current socket, shared between the main actor (sends) and the connect loop.
final class SocketHolder: Sendable {
    private let socket = Mutex<(any PTYSocket)?>(nil)

    func set(_ new: (any PTYSocket)?) {
        let old = socket.withLock { current in
            defer { current = new }
            return current
        }
        guard let old else { return }
        if let new, (old as AnyObject) === (new as AnyObject) { return }
        old.close()
    }

    func send(_ frame: Data) { socket.withLock { $0 }?.send(frame) }

    func close() { set(nil) }
}

enum TerminalSignposts {
    static let stream = OSSignposter(subsystem: EngineSignposts.subsystem, category: "Terminal")
}
