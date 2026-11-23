import ContainerKit
import Foundation
import OpenCodeKit
import os
import Synchronization

/// Whether one admitted agent call may still put a request on the browser's wire (AV05). `BrowseMCPClient` checks it in
/// the same step that registers and sends each request, so no browser operation of the call starts once `revoke()`
/// has returned: not the first (a call that waited for the pooled client to start), not a later one (the tab opened
/// again and the call retried). `revoke()` returns only after every send that began before it has been written.
public final class BrowserCallAuthorization: Sendable {
    private struct State {
        var revoked = false
        var sending = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    public init() {}

    public var isRevoked: Bool { state.withLock { $0.revoked } }

    /// True (and counted as sending until `endSend`) while not revoked.
    func beginSend() -> Bool {
        state.withLock { state in
            guard !state.revoked else { return false }
            state.sending += 1
            return true
        }
    }

    func endSend() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.sending -= 1
            guard state.sending == 0 else { return [] }
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }

    /// No request may be sent from now on; returns once none that began before is still being written.
    public func revoke() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle = state.withLock { state -> Bool in
                state.revoked = true
                guard state.sending > 0 else { return true }
                state.waiters.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }
}

/// A line-delimited JSON-RPC channel to `browse mcp` (stdio). Production: a non-TTY exec in the browser container;
/// tests: an in-memory fake.
public protocol BrowseMCPTransport: Sendable {
    func send(_ line: Data) async throws
    /// Inbound lines; finishes when the process ends.
    func lines() -> AsyncThrowingStream<Data, any Error>
    func close() async
}

/// The one pooled `browse mcp` every thread's calls go through (docs/features/shared-browser.md "One MCP process").
/// Multiplexes request IDs on its stdin and matches out-of-order replies; per-request cancellation is passed on
/// (`notifications/cancelled`). It initializes as opencode (`clientInfo.name = "opencode"`) so browse serves its plain
/// tools. When the process ends, every pending call fails and the owner starts a new one.
public actor BrowseMCPClient {
    public struct CallResult: Sendable, Equatable {
        public var text: String
        public var images: [ClientMCPImage]
        public var isError: Bool
    }

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case closed
        case protocolError(String)
        case timedOut
        /// The call's authorization was withdrawn before this request was sent (nothing reached the browser).
        case revoked
        public var description: String {
            switch self {
            case .revoked: "The person revoked this project's access to the shared Chrome, so the request was not sent."
            case .closed: "The shared Chrome's MCP server stopped."
            case .protocolError(let message): "The shared Chrome's MCP server answered with an error: \(message)"
            case .timedOut: "The shared Chrome did not answer in time."
            }
        }
    }

    private let transport: any BrowseMCPTransport
    private var nextID = 100
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    /// Requests issued but not registered yet. A cancellation or timeout that arrives first removes the ID, and the
    /// registration then refuses it: a cancelled caller never sends (AV05). Bounded by the requests in flight.
    private var unregistered: Set<Int> = []
    private var reader: Task<Void, Never>?
    public private(set) var tools: [ClientMCPTool] = []
    public private(set) var isClosed = false
    /// Bounded (rule 5): more in flight are refused by the gate before they get here.
    public static let maxPending = 64
    private static let log = Logger(subsystem: "app.bellocode", category: "shared-browser")

    public init(transport: any BrowseMCPTransport) {
        self.transport = transport
    }

    /// Starts reading, initializes and lists the tools.
    public func start(timeout: Duration = .seconds(30)) async throws -> [ClientMCPTool] {
        let lines = transport.lines()
        reader = Task { [weak self] in
            do {
                for try await line in lines { await self?.receive(line) }
            } catch {}
            await self?.closed()
        }
        _ = try await request("initialize", params: .object([
            "protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("opencode"), "version": .string("bellocode")]),
        ]), timeout: timeout)
        try await notify("notifications/initialized", params: nil)
        let listed = try await request("tools/list", params: .object([:]), timeout: timeout)
        tools = (listed["tools"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue else { return nil }
            return ClientMCPTool(name: name, description: entry["description"]?.stringValue ?? "", inputSchema: entry["inputSchema"] ?? .object([:]))
        }
        return tools
    }

    /// Calls a browse tool. With `authorization`, the request is sent only if it is still current at the moment it is
    /// registered (else `Failure.revoked`, nothing sent); a caller cancelled before that never sends either.
    public func call(_ tool: String, arguments: JSONValue, timeout: Duration = .seconds(660),
                     authorization: BrowserCallAuthorization? = nil) async throws -> CallResult {
        let result = try await request("tools/call", params: .object(["name": .string(tool), "arguments": arguments]), timeout: timeout,
                                       authorization: authorization)
        var texts: [String] = []
        var images: [ClientMCPImage] = []
        for block in result["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text": texts.append(block["text"]?.stringValue ?? "")
            case "image":
                if let data = block["data"]?.stringValue { images.append(ClientMCPImage(base64: data, mimeType: block["mimeType"]?.stringValue ?? "image/png")) }
            default: break
            }
        }
        return CallResult(text: texts.joined(separator: "\n"), images: images, isError: result["isError"]?.boolValue ?? false)
    }

    public func close() async {
        reader?.cancel()
        await transport.close()
        closed()
    }

    // MARK: Wire

    private func request(_ method: String, params: JSONValue, timeout: Duration,
                         authorization: BrowserCallAuthorization? = nil) async throws -> JSONValue {
        try Task.checkCancellation()
        guard !isClosed else { throw Failure.closed }
        if authorization?.isRevoked == true { throw Failure.revoked }
        guard pending.count + unregistered.count < Self.maxPending else { throw Failure.protocolError("too many calls in flight") }
        nextID += 1
        let id = nextID
        unregistered.insert(id)
        let message = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params])
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        Task { await self.register(id, continuation, message: message, authorization: authorization) }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw Failure.timedOut
                }
                defer { group.cancelAll() }
                do {
                    guard let first = try await group.next() else { throw Failure.closed }
                    return first
                } catch {
                    self.abandon(id, reason: error)
                    throw error
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    /// Registers and sends one request, in one step on this actor: refused if it was cancelled or timed out before
    /// (its ID is no longer unregistered), if the client closed, or if its authorization was withdrawn.
    private func register(_ id: Int, _ continuation: CheckedContinuation<JSONValue, any Error>, message: JSONValue,
                          authorization: BrowserCallAuthorization?) async {
        guard unregistered.remove(id) != nil else { return continuation.resume(throwing: CancellationError()) }
        guard !isClosed else { return continuation.resume(throwing: Failure.closed) }
        if let authorization, !authorization.beginSend() { return continuation.resume(throwing: Failure.revoked) }
        pending[id] = continuation
        do {
            try await transport.send(Self.encode(message))
        } catch {
            pending.removeValue(forKey: id)?.resume(throwing: Failure.closed)
        }
        authorization?.endSend()
    }

    private func abandon(_ id: Int, reason: any Error) {
        unregistered.remove(id)
        pending.removeValue(forKey: id)?.resume(throwing: reason)
    }

    private func cancelRequest(_ id: Int) async {
        // Not registered yet: it never will be (nothing was sent, so nothing to cancel downstream).
        if unregistered.remove(id) != nil { return }
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
        try? await notify("notifications/cancelled", params: .object(["requestId": .number(Double(id)), "reason": .string("cancelled by BelloCode")]))
    }

    private func notify(_ method: String, params: JSONValue?) async throws {
        var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params { message["params"] = params }
        try await transport.send(Self.encode(.object(message)))
    }

    private func receive(_ line: Data) {
        guard let message = try? JSONValue.parse(line), let id = message["id"]?.numberValue else { return }  // notifications/logs: ignored
        guard let key = Int(exactly: id), let continuation = pending.removeValue(forKey: key) else { return }  // a non-integral or huge id from the child is ignored, not trapped
        if let error = message["error"] {
            continuation.resume(throwing: Failure.protocolError(error["message"]?.stringValue ?? "unknown"))
        } else {
            continuation.resume(returning: message["result"] ?? .null)
        }
    }

    private func closed() {
        isClosed = true
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: Failure.closed) }
    }

    static func encode(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        data.append(0x0a)
        return data
    }
}

/// `browse-mcp` as a non-TTY exec in the browser container (never on the Mac). Lines are bounded (32 MiB: a full-page
/// screenshot in base64 fits; a longer line ends the process rather than growing without bound).
public final class ExecBrowseTransport: BrowseMCPTransport {
    let session: ExecSession
    static let maxLine = 32 << 20

    public init(client: EngineClient, container: String) async throws {
        session = try await ExecSession.start(client: client, container: container, argv: ["/usr/local/bin/browse-mcp"], workingDir: nil,
                                              environment: [:], user: nil, tty: false)
    }

    public func send(_ line: Data) async throws { try await session.write(line) }

    public func lines() -> AsyncThrowingStream<Data, any Error> {
        let output = session.output()
        return AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = Data()
                do {
                    for try await chunk in output where chunk.stream == .stdout {
                        buffer.append(chunk.bytes)
                        while let newline = buffer.firstIndex(of: 0x0a) {
                            continuation.yield(Data(buffer[buffer.startIndex..<newline]))
                            buffer = Data(buffer[buffer.index(after: newline)...])
                        }
                        if buffer.count > Self.maxLine { throw BrowseMCPClient.Failure.protocolError("a reply exceeded 32 MiB") }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func close() async {
        session.closeStdin()
        session.close()
    }
}
