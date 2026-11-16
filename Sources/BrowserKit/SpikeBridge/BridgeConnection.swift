// SPIKE (gate G3). The desktop end of one `experimental.browser` v4 attachment, modelled on the reference desktop
// (packages/gui-plugins/src/browser/pane.ts at v2.3.0):
//
//   1. subscribe to /api/event and wait for `server.connected`;
//   2. call `attach {sessionID, connectionID, version: 4}`, which stays pending for the attachment's lifetime;
//   3. the `attached` control event for our connectionID is the readiness barrier: publish `state`;
//   4. each `command` control names a requestID: fetch it with `command`, run it, answer with `result`;
//   5. `cancel` aborts a running request; `attach` returning `replaced` or `closed` ends the attachment.
//
// `state` and `result` go through one ordered outbox, so a `tabs.open` result never overtakes the state naming its tab.

import Foundation

/// Serializes sends in enqueue order. Each send's own completion can be awaited.
actor Outbox {
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task {
            await previous?.value
            await operation()
        }
        tail = task
        return task
    }
}

@MainActor
public final class BridgeConnection {
    public let sessionID: String
    public let connectionID = UUID().uuidString.lowercased()
    private let server: SpikeServer
    private let host: BrowserHost
    private let outbox = Outbox()
    private var running: [String: Task<Void, Never>] = [:]
    private var eventTask: Task<Void, Never>?
    private var attachTask: Task<Void, Never>?
    public private(set) var isAttached = false
    public private(set) var outcome: AttachOutcome?
    /// Protocol trace (control events, RPC calls), without payloads. Bounded.
    public private(set) var trace: [String] = []
    public var onEnded: ((AttachOutcome) -> Void)?

    public init(server: SpikeServer, host: BrowserHost, sessionID: String) {
        self.server = server
        self.host = host
        self.sessionID = sessionID
    }

    private func note(_ line: String) {
        trace.append(line)
        if trace.count > 2_000 { trace.removeFirst() }
    }

    private var attachment: [String: JSONValue] { ["sessionID": .string(sessionID), "connectionID": .string(connectionID)] }

    /// Connects and returns once the server confirmed the attachment and holds our first state.
    public func start(timeout: Duration = .seconds(20)) async throws {
        let (connected, connectedContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let (attached, attachedContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let events = server.events()
        eventTask = Task { [weak self] in
            do {
                for try await event in events {
                    guard let self else { return }
                    let type = event["type"]?.string ?? ""
                    if type == "server.connected" { connectedContinuation.yield() }
                    guard type == BrowserContract.controlEventType, let control = BrowserControl(json: event["data"] ?? .null) else { continue }
                    guard control.connectionID == self.connectionID else { continue }  // another desktop's attachment
                    switch control {
                    case .attached(_, let version):
                        self.note("control attached v\(version)")
                        self.isAttached = true
                        attachedContinuation.yield()
                    case .command(_, let requestID):
                        self.note("control command \(requestID.prefix(8))")
                        self.run(requestID)
                    case .cancel(_, let requestID):
                        self.note("control cancel \(requestID.prefix(8))")
                        self.running[requestID]?.cancel()
                    case .unrecognized(_, let type):
                        self.note("control \(type) (ignored)")
                    }
                }
            } catch {
                self?.note("event stream ended: \(error)")
            }
            self?.end(.closed)
        }
        try await withDeadline(.seconds(10)) { for await _ in connected { return } }

        host.statePublisher = { [weak self] state in
            guard let self else { return }
            await self.sendState(state).value
        }
        let input = JSONValue.object(attachment.merging(["version": .number(Double(BrowserContract.version))]) { $1 })
        let server = self.server
        attachTask = Task { [weak self] in
            let result: AttachOutcome
            do {
                let output = try await server.rpc("attach", input)
                result = AttachOutcome(rawValue: output.string ?? "closed") ?? .closed
            } catch is CancellationError {
                result = .closed
            } catch {
                self?.note("attach failed: \(error)")
                result = .unavailable
            }
            self?.note("attach returned \(result.rawValue)")
            self?.end(result)
        }
        note("attach sent \(connectionID.prefix(8))")
        try await withDeadline(timeout) { for await _ in attached { return } }
        await host.publishNow()
    }

    /// `state` is retried until it lands or the server says the attachment is gone (`unavailable`).
    private func sendState(_ state: BrowserState) async -> Task<Void, Never> {
        let server = self.server
        let input = JSONValue.object(attachment.merging(["state": state.json]) { $1 })
        let count = state.tabs.count
        return await outbox.enqueue { [weak self] in
            var delay = Duration.milliseconds(250)
            for _ in 0..<8 {
                do {
                    _ = try await server.rpc("state", input)
                    await self?.note("state sent (\(count) tabs)")
                    return
                } catch let error as SpikeServer.RPCError where error.type == "unavailable" {
                    await self?.note("state refused: unavailable")
                    return
                } catch {
                    try? await Task.sleep(for: delay)
                    delay = min(delay * 2, .seconds(10))
                }
            }
        }
    }

    private func run(_ requestID: String) {
        let server = self.server
        let request = JSONValue.object(attachment.merging(["requestID": .string(requestID)]) { $1 })
        running[requestID] = Task { [weak self] in
            defer { self?.running[requestID] = nil }
            let outcome: BrowserOutcome
            do {
                let raw = try await server.rpc("command", request)
                let command: BrowserCommand
                do { command = try BrowserCommand(json: raw) } catch {
                    self?.reply(requestID, .failure(BrowserFailure("unsupported", "This desktop app does not support the requested browser operation. Ask the user to update the desktop app, or use another operation.")))
                    return
                }
                guard let host = self?.host else { return }
                outcome = await host.perform(command)
            } catch {
                // Cancelled before retrieval, or the attachment is gone: nothing to answer.
                self?.note("command \(requestID.prefix(8)) unavailable: \(error)")
                return
            }
            self?.reply(requestID, outcome)
        }
    }

    private func reply(_ requestID: String, _ outcome: BrowserOutcome) {
        let server = self.server
        var fields = attachment
        fields["requestID"] = .string(requestID)
        fields["outcome"] = outcome.json
        let input = JSONValue.object(fields)
        let label: String
        switch outcome {
        case .success: label = "success"
        case .failure(let failure): label = "failure \(failure.code)"
        }
        Task {
            await outbox.enqueue { [weak self] in
                do {
                    _ = try await server.rpc("result", input)
                    await self?.note("result \(requestID.prefix(8)) \(label)")
                } catch {
                    await self?.note("result \(requestID.prefix(8)) not delivered: \(error)")
                }
            }.value
        }
    }

    private func end(_ result: AttachOutcome) {
        guard outcome == nil else { return }
        outcome = result
        isAttached = false
        for task in running.values { task.cancel() }
        running.removeAll()
        host.statePublisher = nil
        onEnded?(result)
    }

    /// Ends the attachment from this side: closing the pending `attach` request makes the server detach.
    public func stop() {
        attachTask?.cancel()
        eventTask?.cancel()
        end(.closed)
    }
}
