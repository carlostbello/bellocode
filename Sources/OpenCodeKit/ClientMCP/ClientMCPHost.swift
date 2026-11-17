import Foundation
import os

/// A bidirectional text-frame channel: the WebSocket in production, an in-memory pair in tests.
public protocol ClientMCPChannel: Sendable {
    /// Inbound text frames; finishes when the peer closes or the channel fails.
    var frames: AsyncStream<String> { get }
    func send(_ frame: String) async throws
    func close() async
}

/// Opens channels for one location.
public protocol ClientMCPDialer: Sendable {
    func open(name: String, directory: String) async throws -> any ClientMCPChannel
}

/// Hosts the app's MCP server for one location over `GET /api/experimental/client-mcp?name=…&location[directory]=…`
/// (Basic auth; no ticket needed with credentials, verified on 2.3.0). opencode attaches the tools while the socket is
/// open and drops them when it closes; connections under one name stack and the newest serves.
///
/// Threading and ownership: an actor. The owner (Engine's `OrchestrationService`) calls `start()` once and `stop()` when
/// the location is no longer shown or the app quits; every task this actor starts ends with `stop()`. A dropped
/// connection is reopened with backoff (a reconnect is a fresh MCP session: nothing is replayed).
public actor ClientMCPHost {
    public enum State: Sendable, Equatable {
        case idle, connecting, connected, waiting(retryIn: Duration), stopped
    }

    public nonisolated let name: String
    public nonisolated let directory: String
    private let dialer: any ClientMCPDialer
    private let provider: any ClientMCPToolProvider
    private let protocolHandler: MCPServerProtocol
    private let backoff: BackoffPolicy
    /// Tool calls running at once; more are answered with an error (bounded, AGENTS.md rule 5).
    private let maxConcurrentCalls: Int

    public private(set) var state: State = .idle
    private var loop: Task<Void, Never>?
    private var channel: (any ClientMCPChannel)?
    private var running = 0
    private var calls: [Int: Task<Void, Never>] = [:]
    private var nextCall = 0
    private var onState: (@Sendable (State) -> Void)?

    private static let log = Logger(subsystem: "com.bellocode.app", category: "client-mcp")

    public init(
        name: String, directory: String, dialer: any ClientMCPDialer, provider: any ClientMCPToolProvider,
        serverVersion: String = "1", backoff: BackoffPolicy = BackoffPolicy(initial: .milliseconds(500), maximum: .seconds(30)),
        maxConcurrentCalls: Int = 8
    ) {
        self.name = name
        self.directory = directory
        self.dialer = dialer
        self.provider = provider
        protocolHandler = MCPServerProtocol(serverName: name, serverVersion: serverVersion)
        self.backoff = backoff
        self.maxConcurrentCalls = maxConcurrentCalls
    }

    public func observeState(_ handler: @escaping @Sendable (State) -> Void) {
        onState = handler
        handler(state)
    }

    public func start() {
        guard loop == nil, state != .stopped else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    public func stop() async {
        setState(.stopped)
        loop?.cancel()
        loop = nil
        for task in calls.values { task.cancel() }
        calls.removeAll()
        await channel?.close()
        channel = nil
    }

    /// Tells opencode to list the tools again (after the provider's tool set changed).
    public func toolsChanged() async {
        try? await channel?.send(MCPServerProtocol.toolsChangedNotification)
    }

    // MARK: - Loop

    private func run() async {
        var failures = 0
        while !Task.isCancelled, state != .stopped {
            setState(.connecting)
            do {
                let channel = try await dialer.open(name: name, directory: directory)
                guard !Task.isCancelled, state != .stopped else {
                    await channel.close()
                    return
                }
                self.channel = channel
                setState(.connected)
                failures = 0
                for await frame in channel.frames {
                    if Task.isCancelled { break }
                    await receive(frame, on: channel)
                }
                self.channel = nil
            } catch {
                Self.log.debug("client MCP open failed: \(String(describing: type(of: error)), privacy: .public)")
            }
            guard !Task.isCancelled, state != .stopped else { return }
            failures += 1
            let delay = backoff.delay(forAttempt: failures, random: Double.random(in: 0..<1))
            setState(.waiting(retryIn: delay))
            do { try await Task.sleep(for: delay) } catch { return }
        }
    }

    private func receive(_ frame: String, on channel: any ClientMCPChannel) async {
        switch protocolHandler.handle(frame, directory: directory) {
        case .ignore: return
        case .reply(let text): try? await channel.send(text)
        case .listTools(let id):
            let tools = await provider.tools(directory: directory)
            try? await channel.send(MCPServerProtocol.toolsList(id: id, tools))
        case .call(let id, let call):
            guard running < maxConcurrentCalls else {
                try? await channel.send(MCPServerProtocol.result(id: id, .error("BelloCode is busy with other tool calls; try again.")))
                return
            }
            running += 1
            nextCall += 1
            let key = nextCall
            let provider = self.provider
            calls[key] = Task { [weak self] in
                let result = await provider.call(call)
                await self?.finish(key, id: id, result, on: channel)
            }
        }
    }

    private func finish(_ key: Int, id: JSONValue, _ result: ClientMCPResult, on channel: any ClientMCPChannel) async {
        running -= 1
        calls[key] = nil
        guard !Task.isCancelled, state != .stopped else { return }
        try? await channel.send(MCPServerProtocol.result(id: id, result))
    }

    private func setState(_ next: State) {
        guard state != next else { return }
        if state == .stopped { return }
        state = next
        onState?(next)
    }
}

// MARK: - WebSocket channel

/// The production dialer: `URLSessionWebSocketTask` to the server's client-MCP route with Basic auth.
public struct WebSocketClientMCPDialer: ClientMCPDialer {
    public let connection: ServerConnection

    public init(connection: ServerConnection) {
        self.connection = connection
    }

    public func open(name: String, directory: String) async throws -> any ClientMCPChannel {
        guard var components = URLComponents(url: connection.baseURL, resolvingAgainstBaseURL: false) else {
            throw OpenCodeError.invalidResponse
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/api/experimental/client-mcp"
        components.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "location[directory]", value: directory)]
        guard let url = components.url else { throw OpenCodeError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue(connection.credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        return WebSocketChannel(task: WebSocketChannel.session.webSocketTask(with: request))
    }
}

final class WebSocketChannel: ClientMCPChannel {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 7 * 24 * 3600
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: configuration)
    }()

    let frames: AsyncStream<String>
    private let task: URLSessionWebSocketTask
    private let reader: Task<Void, Never>

    init(task: URLSessionWebSocketTask) {
        self.task = task
        // Frames are handled one at a time by the host; 256 buffered frames is far above what opencode sends.
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(256))
        frames = stream
        task.resume()
        reader = Task {
            while !Task.isCancelled {
                do {
                    switch try await task.receive() {
                    case .string(let text): continuation.yield(text)
                    case .data(let data): continuation.yield(String(decoding: data, as: UTF8.self))
                    @unknown default: break
                    }
                } catch {
                    break
                }
            }
            continuation.finish()
        }
    }

    func send(_ frame: String) async throws { try await task.send(.string(frame)) }

    func close() async {
        reader.cancel()
        task.cancel(with: .normalClosure, reason: nil)
    }
}

// MARK: - In-memory channel (tests, mock mode)

/// A channel pair: the host's side and the peer's (the test plays opencode's MCP client).
public final class InMemoryClientMCPChannel: ClientMCPChannel {
    public let frames: AsyncStream<String>
    private let inbound: AsyncStream<String>.Continuation
    /// Frames the host sent.
    public let sent: AsyncStream<String>
    private let outbound: AsyncStream<String>.Continuation

    public init() {
        (frames, inbound) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(256))
        (sent, outbound) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    /// Delivers a frame to the host, as opencode would.
    public func deliver(_ frame: String) { inbound.yield(frame) }
    public func peerClose() { inbound.finish() }

    public func send(_ frame: String) async throws { outbound.yield(frame) }
    public func close() async {
        inbound.finish()
        outbound.finish()
    }
}

/// Hands out prepared channels in order; fails when none is left.
public actor InMemoryClientMCPDialer: ClientMCPDialer {
    private var channels: [InMemoryClientMCPChannel]
    public private(set) var opened: [(name: String, directory: String)] = []

    public init(_ channels: [InMemoryClientMCPChannel]) {
        self.channels = channels
    }

    public func open(name: String, directory: String) async throws -> any ClientMCPChannel {
        opened.append((name, directory))
        guard !channels.isEmpty else { throw OpenCodeError.invalidResponse }
        return channels.removeFirst()
    }
}
