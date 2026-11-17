import Foundation
import os

/// How an attachment ended.
public enum BrowserAttachmentEnd: Error, Sendable, Equatable, CustomStringConvertible {
    /// `attach` returned `closed`: the session was deleted or moved, the plugin was disposed, or we stopped it.
    case closed
    /// Another desktop attached to the same session. The replaced side must not reclaim it on its own.
    case replaced
    /// The server refused or could not be reached. `retryable` is true for transport failures (server restarting).
    case unavailable(message: String, retryable: Bool)
    /// The server speaks another contract version (schema rejection of `version`, or `attached` with another version).
    case incompatible(serverVersion: Int?, message: String)

    public var description: String {
        switch self {
        case .closed: "closed"
        case .replaced: "replaced"
        case .unavailable(let message, let retryable): "unavailable\(retryable ? " (retryable)" : ""): \(message)"
        case .incompatible(let version, _): "incompatible (server version \(version.map(String.init) ?? "unknown"))"
        }
    }
}

/// What an attachment reports to its owner (for status and the visible activity line). Content-free.
public enum BrowserAttachmentEvent: Sendable, Equatable {
    case attached
    case commandStarted(requestID: String, operation: String)
    case commandFinished(requestID: String, operation: String, failureCode: String?)
    case commandCancelled(requestID: String)
    case stateRejected
    case ended(BrowserAttachmentEnd)
}

/// The desktop end of one `experimental.browser` v4 attachment for one session, modelled on the reference desktop
/// (packages/gui-plugins/src/browser/pane.ts at v2.3.0):
///
/// 1. the owner subscribes to `/api/event` (control events) before `start()`, and routes controls with our
///    `connectionID` to `receive(_:)`;
/// 2. `start()` calls `attach {sessionID, connectionID, version: 4}`, which stays pending for the attachment's life, and
///    returns once the `attached` control arrived and the first state was acknowledged;
/// 3. each `command` control names a request: fetch it with `command`, run it through `perform` (with a deadline and
///    cancellation), answer with `result`;
/// 4. `state` and `result` share one ordered outbox, so a `tabs.open` result never overtakes the state naming its tab.
///    `state` is retried until it lands or the server answers `unavailable`.
///
/// Tasks are owned by the actor and cancelled by `stop()` or when the attachment ends (AGENTS.md rules 8 and 9).
public actor BrowserAttachment {
    public nonisolated let sessionID: String
    public nonisolated let connectionID: String
    public nonisolated let directory: String

    public typealias Perform = @Sendable (BrowserCommand) async -> BrowserOutcome
    public typealias Inventory = @Sendable () async -> BrowserInventory
    public typealias Observer = @Sendable (BrowserAttachmentEvent) -> Void

    private let client: @Sendable () async throws -> OpenCodeClient
    private let perform: Perform
    private let inventory: Inventory
    private let observer: Observer
    private let commandTimeout: @Sendable (BrowserCommand) -> Duration
    private let log = Logger(subsystem: "app.bellocode.OpenCodeKit", category: "BrowserAttachment")
    private let signposter = OSSignposter(subsystem: "app.bellocode.OpenCodeKit", category: "BrowserAttachment")

    private var attachTask: Task<Void, Never>?
    private var running: [String: Task<Void, Never>] = [:]
    /// Requests the person (or our deadline) cancelled: these are answered with a failure; server cancels are not.
    private var locallyCancelled: Set<String> = []
    private var outboxTail: Task<Void, Never>?
    private var stateInFlight = false
    private var stateDirty = false
    private var attachedWaiters: [CheckedContinuation<Bool, Never>] = []
    public private(set) var isAttached = false
    public private(set) var end: BrowserAttachmentEnd?
    /// Bounded protocol trace (types and request ID prefixes only, never payloads), for diagnostics and tests.
    public private(set) var trace: [String] = []

    public init(
        sessionID: String, directory: String, connectionID: String = UUID().uuidString.lowercased(),
        client: @escaping @Sendable () async throws -> OpenCodeClient,
        inventory: @escaping Inventory, perform: @escaping Perform, observer: @escaping Observer = { _ in },
        commandTimeout: @escaping @Sendable (BrowserCommand) -> Duration = { _ in BrowserContract.defaultCommandTimeout }
    ) {
        self.sessionID = sessionID
        self.directory = directory
        self.connectionID = connectionID
        self.client = client
        self.inventory = inventory
        self.perform = perform
        self.observer = observer
        self.commandTimeout = commandTimeout
    }

    private var identity: [String: JSONValue] { ["sessionID": .string(sessionID), "connectionID": .string(connectionID)] }

    private func note(_ line: String) {
        trace.append(line)
        if trace.count > 400 { trace.removeFirst(trace.count - 400) }
    }

    // MARK: Lifecycle

    /// Attaches and returns once the server confirmed (`attached`) and holds our first state. Throws the end reason
    /// when the attachment could not be established within `readyTimeout`.
    public func start(readyTimeout: Duration = .seconds(20)) async throws(BrowserAttachmentEnd) {
        if let end { throw end }
        guard attachTask == nil else { return }
        let input = JSONValue.object(identity.merging(["version": .number(Double(BrowserContract.version))]) { $1 })
        let client = self.client
        attachTask = Task { [weak self] in
            let outcome: BrowserAttachmentEnd
            do {
                let output = try await client().browserRPC("attach", input, directory: self?.directory ?? "", longLived: true)
                outcome = output.stringValue == "replaced" ? .replaced : .closed
            } catch let error as BrowserRPCError {
                outcome = Self.end(for: error)
            } catch {
                outcome = .unavailable(message: "The server is not reachable.", retryable: true)
            }
            await self?.finish(outcome)
        }
        note("attach sent")
        let ready = await waitForAttached(timeout: readyTimeout)
        if let end { throw end }
        guard ready else {
            finish(.unavailable(message: "The server did not confirm the browser attachment in time.", retryable: true))
            throw end ?? .closed
        }
        await publishAndWait()
    }

    static func end(for error: BrowserRPCError) -> BrowserAttachmentEnd {
        switch error {
        case .cancelled: return .closed
        case .transport: return .unavailable(message: "The server is not reachable.", retryable: true)
        case .rpc(_, let message): return .unavailable(message: message.isEmpty ? "The server refused the browser attachment." : message, retryable: false)
        case .rejected(let status, let tag, let message):
            // The plugin's schema pins `version`; any mismatch fails input validation before the plugin runs.
            if tag == "InvalidRequestError" || status == 400 {
                return .incompatible(serverVersion: nil, message: message.isEmpty ? "The server rejected browser contract version \(BrowserContract.version)." : message)
            }
            return .unavailable(message: "\(tag) (\(status))", retryable: status >= 500)
        }
    }

    private func waitForAttached(timeout: Duration) async -> Bool {
        if isAttached { return true }
        if end != nil { return false }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.resumeAttachedWaiters(false)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { attachedWaiters.append($0) }
    }

    private func resumeAttachedWaiters(_ value: Bool) {
        let waiters = attachedWaiters
        attachedWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: value) }
    }

    /// Ends the attachment from this side: cancelling the pending `attach` request makes the server detach (`closed`).
    public func stop() {
        attachTask?.cancel()
        finish(.closed)
    }

    private func finish(_ outcome: BrowserAttachmentEnd) {
        guard end == nil else { return }
        end = outcome
        isAttached = false
        note("ended \(outcome)")
        attachTask?.cancel()
        for task in running.values { task.cancel() }
        running.removeAll()
        resumeAttachedWaiters(false)
        observer(.ended(outcome))
    }

    // MARK: Control events

    /// A control event for this connection (the owner filters by `connectionID`).
    public func receive(_ control: BrowserControl) {
        guard end == nil, control.connectionID == connectionID else { return }
        switch control {
        case .attached(_, let version):
            note("control attached v\(version)")
            guard version == BrowserContract.version else {
                finish(.incompatible(serverVersion: version, message: "The server's browser plugin speaks contract version \(version); this BelloCode speaks \(BrowserContract.version)."))
                return
            }
            isAttached = true
            resumeAttachedWaiters(true)
            observer(.attached)
        case .command(_, let requestID):
            note("control command \(requestID.prefix(8))")
            run(requestID)
        case .cancel(_, let requestID):
            note("control cancel \(requestID.prefix(8))")
            running[requestID]?.cancel()
        case .unrecognized(_, let type):
            note("control \(type) ignored")
        }
    }

    /// The event stream reconnected after a gap: controls may have been lost, so republish the inventory (a reconnect is
    /// not a replay; the server times out any command whose control we missed).
    public func eventStreamResynced() {
        guard isAttached else { return }
        note("resync")
        requestPublish()
    }

    // MARK: Commands

    /// Cancels a running request on our side (the person pressed Stop). It is answered with `cancelled`.
    public func cancel(requestID: String) {
        guard let task = running[requestID] else { return }
        locallyCancelled.insert(requestID)
        task.cancel()
    }

    /// Cancels every running request on our side.
    public func cancelAll() {
        for id in running.keys { cancel(requestID: id) }
    }

    public var runningRequestIDs: [String] { Array(running.keys) }

    private func run(_ requestID: String) {
        guard running[requestID] == nil else { return }
        let request = JSONValue.object(identity.merging(["requestID": .string(requestID)]) { $1 })
        let client = self.client
        let directory = self.directory
        let perform = self.perform
        let deadlineFor = self.commandTimeout
        running[requestID] = Task { [weak self] in
            let raw: JSONValue
            do {
                raw = try await client().browserRPC("command", request, directory: directory)
            } catch {
                // Cancelled before retrieval, or no longer pending: nothing to answer.
                await self?.completed(requestID, note: "command \(requestID.prefix(8)) not retrieved")
                return
            }
            let command: BrowserCommand
            do throws(BrowserFailure) {
                command = try BrowserCommand(json: raw)
            } catch {
                await self?.reply(requestID, .failure(error), operation: "?")
                return
            }
            guard let self else { return }
            let operation = command.type
            self.observer(.commandStarted(requestID: requestID, operation: operation))
            let outcome = await Self.withDeadline(deadlineFor(command), operation: operation) { await perform(command) }
            await self.settle(requestID, operation: operation, outcome: outcome)
        }
    }

    /// Runs `body` with a deadline; a cancelled body yields `cancelled`, an expired one `timeout`.
    static func withDeadline(_ deadline: Duration, operation: String, _ body: @escaping @Sendable () async -> BrowserOutcome) async -> BrowserOutcome {
        await withTaskGroup(of: BrowserOutcome?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: deadline)
                if Task.isCancelled { return nil }
                return .failure(BrowserFailure(.timeout, "browser.\(operation) did not finish within \(deadline.components.seconds) seconds and was stopped; it may have partially run. Call browser.tabs.list({}) and inspect the tab with browser.snapshot({tabID}) before repeating it."))
            }
            var result: BrowserOutcome = .failure(BrowserFailure(.cancelled, "browser.\(operation) was cancelled."))
            for await outcome in group {
                if let outcome {
                    result = outcome
                    break
                }
            }
            group.cancelAll()
            return result
        }
    }

    private func settle(_ requestID: String, operation: String, outcome: BrowserOutcome) {
        let cancelledHere = locallyCancelled.remove(requestID) != nil
        let task = running[requestID]
        if task?.isCancelled == true, !cancelledHere {
            // The server cancelled (its timeout, or the agent's turn was interrupted): it already settled the request.
            running[requestID] = nil
            note("command \(requestID.prefix(8)) cancelled by server")
            observer(.commandCancelled(requestID: requestID))
            return
        }
        var outcome = outcome
        if cancelledHere {
            outcome = .failure(BrowserFailure(.cancelled, "The user stopped browser.\(operation) in BelloCode; it may have partially run. Ask the user before repeating it, and inspect the tab with browser.snapshot({tabID}) first."))
        }
        reply(requestID, outcome, operation: operation)
    }

    private func completed(_ requestID: String, note line: String) {
        running[requestID] = nil
        locallyCancelled.remove(requestID)
        note(line)
    }

    private func reply(_ requestID: String, _ outcome: BrowserOutcome, operation: String) {
        running[requestID] = nil
        let outcome = Self.bounded(outcome, operation: operation)
        var fields = identity
        fields["requestID"] = .string(requestID)
        fields["outcome"] = outcome.json
        let input = JSONValue.object(fields)
        let failureCode = outcome.failure?.code.rawValue
        observer(.commandFinished(requestID: requestID, operation: operation, failureCode: failureCode))
        let client = self.client
        let directory = self.directory
        let label = failureCode.map { "failure \($0)" } ?? "success"
        enqueue { [weak self] in
            do {
                _ = try await client().browserRPC("result", input, directory: directory)
                await self?.note("result \(requestID.prefix(8)) \(label)")
            } catch {
                await self?.note("result \(requestID.prefix(8)) not delivered: \(error)")
            }
        }
    }

    /// Results above the reference desktop's limit are refused with an explanation instead of being sent.
    static func bounded(_ outcome: BrowserOutcome, operation: String) -> BrowserOutcome {
        guard case .success(let result) = outcome else { return outcome }
        let size = (try? result.value.encodedData().count) ?? 0
        guard size <= BrowserContract.maxResultCharacters else {
            return .failure(BrowserFailure(.tooLarge, "browser.\(operation) result exceeds \(BrowserContract.maxResultCharacters) JSON characters. Request fewer entries, reduce snapshot depth, or return only selected fields."))
        }
        return outcome
    }

    // MARK: State

    /// Publishes the current inventory soon; repeated requests while one is in flight collapse into one more send.
    public func requestPublish() {
        guard end == nil else { return }
        if stateInFlight {
            stateDirty = true
            return
        }
        stateInFlight = true
        enqueueStateSend()
    }

    /// Publishes the current inventory and returns once the server acknowledged it (or refused it). The server
    /// resolves tab IDs only from published state, so `tabs.open` and `tabs.close` wait for this before answering.
    public func publishAndWait() async {
        guard end == nil else { return }
        let task = enqueueStateTask()
        await task.value
    }

    private func enqueueStateSend() {
        _ = enqueueStateTask()
    }

    private func enqueueStateTask() -> Task<Void, Never> {
        let client = self.client
        let directory = self.directory
        let inventory = self.inventory
        let identity = self.identity
        return enqueue { [weak self] in
            let state = await inventory()
            let input = JSONValue.object(identity.merging(["state": state.json]) { $1 })
            var delay = Duration.milliseconds(250)
            for attempt in 0..<8 {
                if Task.isCancelled { break }
                do {
                    _ = try await client().browserRPC("state", input, directory: directory)
                    await self?.note("state sent (\(state.tabs.count) tabs)")
                    break
                } catch let error as BrowserRPCError where error.isUnavailable {
                    await self?.stateRefused()
                    break
                } catch {
                    if attempt == 7 { await self?.note("state not delivered") }
                    try? await Task.sleep(for: delay)
                    delay = min(delay * 2, .seconds(10))
                }
            }
            await self?.stateSendFinished()
        }
    }

    private func stateRefused() {
        note("state refused: unavailable")
        observer(.stateRejected)
    }

    private func stateSendFinished() {
        if stateDirty, end == nil {
            stateDirty = false
            enqueueStateSend()
        } else {
            stateInFlight = false
            stateDirty = false
        }
    }

    /// Serializes sends in enqueue order.
    @discardableResult
    private func enqueue(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = outboxTail
        let task = Task {
            await previous?.value
            await operation()
        }
        outboxTail = task
        return task
    }
}
