import BelloCore
import Foundation
import OpenCodeKit
import os

/// What the broker asks the app (the main-actor `SharedBrowserService`, or a test double).
public protocol SharedBrowserHost: Sendable {
    /// Whether agents in this location may use the shared Chrome: nil = yes; otherwise why not.
    func access(session: String, directory: String) async -> BrowserAccess
    /// What a location's tools listing advertises (no session: listings are per directory).
    func toolAccess(directory: String) async -> BrowserToolAccess
    /// Raises the approval card (the server needs a person, even in Auto or Full access).
    func requestAccess(session: String, directory: String) async -> ClientMCPResult
    /// The thread's binding (created and stored on first use).
    func binding(session: String, directory: String) async -> BrowserBinding
    func save(_ binding: BrowserBinding) async
    /// Tabs shared with / by this thread, and the owner's thread title by tab.
    func shares(session: String) async -> (withMe: Set<String>, byMe: Set<String>, owners: [String: String])
    /// Starts the browser if needed and counts one call; false with a reason when it cannot start.
    func beginCall() async throws
    func endCall() async
    /// A transport to a fresh `browse mcp` in the browser container.
    func makeTransport() async throws -> any BrowseMCPTransport
    func generation() async -> Int
    func threadTitle(session: String) async -> String
}

public enum BrowserAccess: Sendable, Equatable {
    case allowed
    case needsApproval
    case unavailable(String)
}

/// A directory's tools listing: allowed for the project, allowed for some of its threads only (Allow Once), or not.
public enum BrowserToolAccess: Sendable, Equatable {
    case allowed
    case someSessions
    case needsApproval
    case unavailable(String)
}

extension SharedBrowserHost {
    /// Hosts without per-session approvals: the project-level answer.
    public func toolAccess(directory: String) async -> BrowserToolAccess {
        switch await access(session: "", directory: directory) {
        case .allowed: .allowed
        case .needsApproval: .needsApproval
        case .unavailable(let reason): .unavailable(reason)
        }
    }
}

/// The client-MCP provider behind the agents' `chrome_*` tools (docs/features/shared-browser.md "Multi-agent model").
/// One pooled `browse mcp` in the container serves every thread; this broker attributes each call to its opencode
/// session (`_meta["ai.opencode/sessionID"]`, refused when missing), checks the person's approval, binds it to the
/// thread's tab group and tab (`BrowserCallPolicy`), serialises calls per tab with the driver lease (`BrowserTabGate`),
/// and passes images and cancellation through. A browser restart fails what was in flight ("outcome unknown") and every
/// thread that used the browser is told plainly with its next result.
public actor SharedBrowserBroker: ClientMCPToolProvider {
    public static let serverName = "chrome"
    public static let requestAccessTool = "request_access"
    public static let releaseTool = "release_tab"

    private let host: any SharedBrowserHost
    public let gate: BrowserTabGate
    private var client: BrowseMCPClient?
    private var clientGeneration = -1
    private var starting: Task<BrowseMCPClient, any Error>?
    private var ensured: Set<String> = []          // "<generation>|<tab>"
    private var numeric: [Int: String] = [:]       // bounded
    private var notices: [String: [String]] = [:]  // session → notices for its next result
    private var activeSessions: Set<String> = []   // sessions that used the browser this generation
    private var cachedTools: [ClientMCPTool]
    /// Dispatched downstream calls by ticket, so Take Over can cancel them (R22).
    private var operations: [Int: (tab: String, task: Task<(outcome: Outcome, value: ClientMCPResult), Never>)] = [:]
    private let toolsCache: (@Sendable ([ClientMCPTool]) -> Void)?
    /// Every admitted call until it returns, by call ID: its project, the revocation sequence it was admitted under,
    /// its work (so a revocation cancels it while it waits or runs), and whether it reached the browser (AV05).
    private var admitted: [Int: AdmittedCall] = [:]
    private var nextCallID = 0
    /// Revocations, in order: a call admitted at sequence `n` is stale once its project was revoked after `n`.
    /// Entries matter only to admitted calls, so they are dropped when none is left (bounded, rule 5).
    private var revocationSequence = 0
    private var lastRevoked: [String: Int] = [:]
    private static let log = Logger(subsystem: "app.bellocode", category: "shared-browser")

    public init(host: any SharedBrowserHost, gate: BrowserTabGate = BrowserTabGate(), cachedTools: [ClientMCPTool] = [],
                toolsCache: (@Sendable ([ClientMCPTool]) -> Void)? = nil) {
        self.host = host
        self.gate = gate
        self.cachedTools = cachedTools
        self.toolsCache = toolsCache
    }

    // MARK: Tools

    /// The listing is per directory. With Allow Once for one of its threads the chrome_* tools are listed (with
    /// request_access for the other threads); every call is still checked against its exact session and directory.
    public func tools(directory: String) async -> [ClientMCPTool] {
        switch await host.toolAccess(directory: directory) {
        case .unavailable: return []
        case .needsApproval: return [Self.requestAccessDefinition]
        case .allowed:
            return await agentToolList()
        case .someSessions:
            return await agentToolList() + [Self.requestAccessDefinition]
        }
    }

    private func agentToolList() async -> [ClientMCPTool] {
        if cachedTools.isEmpty, let started = try? await currentClient() { cachedTools = await started.tools }
        return Self.agentTools(from: cachedTools)
    }

    static let requestAccessDefinition = ClientMCPTool(
        name: requestAccessTool,
        description: "Ask the person to let agents in this project use BelloCode's shared Chrome (a real Chromium in a container, signed in to the person's accounts, shared by all threads). Call it once when you need a real browser; then end your turn and wait to be woken.",
        inputSchema: .object(["type": .string("object"), "properties": .object(["reason": .object(["type": .string("string"), "description": .string("What you need the browser for")])])]))

    static let releaseDefinition = ClientMCPTool(
        name: releaseTool,
        description: "Give back the driver role of a tab the person shared with you (or that you shared), so another thread can drive it.",
        inputSchema: .object(["type": .string("object"), "properties": .object(["tab": .object(["type": .string("string")])]), "required": .array([.string("tab")])]))

    /// browse's tools minus the hidden ones, with BelloCode's binding stated where it matters.
    static func agentTools(from downstream: [ClientMCPTool]) -> [ClientMCPTool] {
        downstream.filter { !BrowserCallPolicy.hiddenTools.contains($0.name) }.map { tool in
            var tool = tool
            switch tool.name {
            case "tabs":
                tool.description += "\nBelloCode: you have your own tab group; `new` tabs land in it, `list` shows only your tabs and tabs shared with you."
            case "navigate":
                tool.description += "\nBelloCode: without `tab` this navigates your default tab (never a stray background tab)."
            default: break
            }
            return tool
        } + [releaseDefinition]
    }

    // MARK: Calls

    private struct AdmittedCall {
        var directory: String
        var sequence: Int
        var work: Task<(outcome: Outcome, value: ClientMCPResult), Never>?
        var dispatched = false
        /// Checked by the MCP client as each of the call's requests is registered and sent (AV05).
        let authorization = BrowserCallAuthorization()
    }

    public func call(_ call: ClientMCPCall) async -> ClientMCPResult {
        guard let session = call.sessionID, !session.isEmpty else {
            return .error("BelloCode could not tell which thread made this call, so the shared Chrome refused it.")
        }
        // Registered before the access check, so a revocation at any later point is seen by this call (AV05).
        nextCallID += 1
        let callID = nextCallID
        admitted[callID] = AdmittedCall(directory: call.directory, sequence: revocationSequence)
        defer { finish(callID) }
        switch await host.access(session: session, directory: call.directory) {
        case .unavailable(let reason): return .error(reason)
        case .needsApproval:
            if call.tool == Self.requestAccessTool { return await host.requestAccess(session: session, directory: call.directory) }
            return .error("The shared Chrome needs the person's approval for this project first: call \(Self.serverName)_\(Self.requestAccessTool).")
        case .allowed: break
        }
        if call.tool == Self.requestAccessTool { return ClientMCPResult(text: "The shared Chrome is already allowed here; use the \(Self.serverName)_* tools.") }
        if call.tool == Self.releaseTool {
            guard let tab = call.arguments["tab"]?.stringValue else { return .error("Give tab.") }
            await gate.yield(tab: tab, session: session)
            return ClientMCPResult(text: "Released the driver role of \(tab).")
        }
        await gate.setName(await host.threadTitle(session: session), for: session)
        var binding = await host.binding(session: session, directory: call.directory)
        let shares = await host.shares(session: session)
        let context = BrowserCallPolicy.Context(binding: binding, sharedWithMe: shares.withMe, sharedByMe: shares.byMe, numeric: numeric,
                                                ownerName: { shares.owners[$0] })
        let plan = BrowserCallPolicy.plan(tool: call.tool, arguments: call.arguments, context: context)
        guard case .forward(let tool, let arguments, let tab, let shared, let ensure, let remember) = plan else {
            if case .refuse(let message) = plan { return .error(message) }
            return .error("Refused.")
        }
        guard !isRevoked(callID) else { return .error(Self.revokedMessage(dispatched: false)) }
        do {
            try await host.beginCall()
        } catch {
            return .error("The shared Chrome could not start: \(BrowserSupervisor.describe(error))")
        }
        let directory = call.directory
        guard let authorization = admitted[callID]?.authorization else { return .error(Self.revokedMessage(dispatched: false)) }
        let work = Task {
            await self.perform(tool: tool, arguments: arguments, tab: tab, shared: shared, ensure: ensure, session: session,
                               directory: directory, binding: binding, callID: callID, authorization: authorization)
        }
        admitted[callID]?.work = work
        // Revoked between admission and here: the work is cancelled before it waits for its tab.
        if isRevoked(callID) { work.cancel() }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        await host.endCall()
        // A result is returned only under a grant that is still current: page content read after the person revoked
        // the project never reaches the agent (AV05).
        let access = await host.access(session: session, directory: directory)
        if isRevoked(callID) || access == .needsApproval {
            return .error(Self.revokedMessage(dispatched: admitted[callID]?.dispatched == true))
        }
        if case .unavailable(let reason) = access {
            return .error(reason + " The call's result was withheld; it may or may not have taken effect.")
        }
        if case .success = result.outcome, let remember {
            binding.remember(remember)
            await host.save(binding)
        }
        var text = result.value.text
        if let pending = notices.removeValue(forKey: session), !pending.isEmpty {
            text = pending.map { "[BelloCode] \($0)" }.joined(separator: "\n") + "\n\n" + text
        }
        return ClientMCPResult(text: text, isError: result.value.isError, images: result.value.images)
    }

    private enum Outcome { case success, failure }

    /// Revokes the project's access for calls already admitted (Settings ▸ Browser): those waiting for a tab are
    /// cancelled and never sent; those running are cancelled and their results withheld (AV05). New calls are refused
    /// by the host's access check.
    ///
    /// Each admitted call's authorization is withdrawn at the transport, so none of them puts a request on the browser's
    /// wire after this returns: not a first operation still waiting for the pooled client to start, not a retry. A
    /// request whose bytes were being written when this was called has been written by the time it returns.
    public func revoke(directory: String) async {
        revocationSequence += 1
        lastRevoked[directory] = revocationSequence
        let affected = admitted.values.filter { $0.directory == directory }
        for call in affected { call.work?.cancel() }
        for call in affected { await call.authorization.revoke() }
    }

    private func isRevoked(_ callID: Int) -> Bool {
        guard let call = admitted[callID] else { return true }
        return (lastRevoked[call.directory] ?? 0) > call.sequence
    }

    private func finish(_ callID: Int) {
        admitted[callID] = nil
        if admitted.isEmpty { lastRevoked = [:] }
    }

    static func revokedMessage(dispatched: Bool) -> String {
        dispatched
            ? "The person revoked this project's access to the shared Chrome while this call ran. It may or may not have taken effect, and its result was withheld. Do not use the browser again unless the person allows it (\(serverName)_\(requestAccessTool))."
            : "The person revoked this project's access to the shared Chrome, so this call was not sent. Do not use the browser again unless the person allows it (\(serverName)_\(requestAccessTool))."
    }

    /// Whether the call may still reach the browser: its project not revoked since it was admitted, and the host still
    /// allows it (checked after the wait for its tab, right before dispatch).
    private func mayDispatch(_ callID: Int, session: String, directory: String) async -> Bool {
        guard !isRevoked(callID), !Task.isCancelled else { return false }
        guard await host.access(session: session, directory: directory) == .allowed else { return false }
        return !isRevoked(callID) && !Task.isCancelled
    }

    private func perform(tool: String, arguments: JSONValue, tab: String, shared: Bool, ensure: Bool, session: String,
                         directory: String, binding: BrowserBinding, callID: Int,
                         authorization: BrowserCallAuthorization) async -> (outcome: Outcome, value: ClientMCPResult) {
        let ticket: BrowserTabGate.Ticket
        do {
            ticket = try await gate.acquire(tab: tab, session: session, shared: shared)
        } catch let busy as BrowserTabGate.Busy {
            return (.failure, .error(busy.description))
        } catch {
            return (.failure, .error("The call was cancelled."))
        }
        // Access is checked again at execution time: a call queued behind a busy tab may have waited past a revocation.
        guard await mayDispatch(callID, session: session, directory: directory) else {
            await gate.release(ticket)
            return (.failure, .error(Self.revokedMessage(dispatched: false)))
        }
        admitted[callID]?.dispatched = true
        activeSessions.insert(session)
        let work = Task {
            await self.run(tool: tool, arguments: arguments, tab: tab, ensure: ensure, binding: binding, ticket: ticket, authorization: authorization)
        }
        operations[ticket.id] = (tab, work)
        let value = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        operations[ticket.id] = nil
        await gate.release(ticket)
        return value
    }

    /// Take Over (R22): closes admission for `tab` ("*": the whole browser), cancels the agent calls already sent to
    /// it, and returns once they have settled (true) or `deadline` passed with one still running (false). Only then
    /// does the service hand control to the person.
    public func takeOver(_ tab: String, deadline: Duration = .seconds(10)) async -> Bool {
        await gate.takeOver(tab)
        for operation in operations.values where tab == "*" || operation.tab == tab { operation.task.cancel() }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { [gate] in
                await gate.waitUntilIdle(tab)
                return !Task.isCancelled
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Every browser operation of the call goes through the client with the call's authorization (AV05): the pooled
    /// client may have taken long to start, and a revocation meanwhile stops each request at the transport.
    private func run(tool: String, arguments: JSONValue, tab: String, ensure: Bool, binding: BrowserBinding,
                     ticket: BrowserTabGate.Ticket, authorization: BrowserCallAuthorization) async -> (outcome: Outcome, value: ClientMCPResult) {
        do {
            let client = try await currentClient()
            let generation = clientGeneration
            if ensure, !ensured.contains("\(generation)|\(tab)") {
                _ = try await client.call("tabs", arguments: .object([
                    "action": .string("new"), "id": .string(tab), "group": .string(binding.group),
                ]), timeout: .seconds(60), authorization: authorization)
                ensured.insert("\(generation)|\(tab)")
            }
            var result = try await client.call(tool, arguments: arguments, authorization: authorization)
            if ensure, result.isError, result.text.contains("No tab has the id") {
                // The tab vanished (closed by the person, or the browser restarted): open it again once, then retry.
                _ = try await client.call("tabs", arguments: .object([
                    "action": .string("new"), "id": .string(tab), "group": .string(binding.group),
                ]), timeout: .seconds(60), authorization: authorization)
                result = try await client.call(tool, arguments: arguments, authorization: authorization)
            }
            guard await gate.isCurrent(ticket) else { return (.failure, .error(BrowserTabGate.Busy.restarted.description)) }
            // Taken over while it ran: the person has the tab now, so the agent must not act on this result as if
            // nothing happened.
            if await gate.isHumanControlled(tab) {
                return (.failure, .error(BrowserTabGate.Busy.humanControl(tab: tab).description + " Your last call may or may not have taken effect."))
            }
            learn(result.text)
            return (result.isError ? .failure : .success, ClientMCPResult(text: result.text, isError: result.isError, images: result.images))
        } catch is CancellationError {
            if await gate.isHumanControlled(tab) {
                return (.failure, .error("The person took over the shared Chrome, so this call was cancelled; it may or may not have taken effect."))
            }
            return (.failure, .error("The call was cancelled."))
        } catch BrowseMCPClient.Failure.revoked {
            return (.failure, .error(Self.revokedMessage(dispatched: false)))
        } catch let failure as BrowseMCPClient.Failure {
            if failure == .closed { client = nil }
            return (.failure, .error(failure == .closed ? BrowserTabGate.Busy.restarted.description : failure.description))
        } catch {
            return (.failure, .error("The shared Chrome call failed: \(error)"))
        }
    }

    private func learn(_ text: String) {
        for (key, value) in BrowserCallPolicy.learnTabIDs(from: text) { numeric[key] = value }
        if numeric.count > 512 { numeric = Dictionary(uniqueKeysWithValues: numeric.suffix(256).map { ($0.key, $0.value) }) }
    }

    /// The pooled client for the current browser generation (one start at a time).
    private func currentClient() async throws -> BrowseMCPClient {
        let generation = await host.generation()
        if let client, clientGeneration == generation, await !client.isClosed { return client }
        if let starting { return try await starting.value }
        let task = Task<BrowseMCPClient, any Error> {
            try await self.host.beginCall()
            defer { Task { await self.host.endCall() } }
            let transport = try await self.host.makeTransport()
            let fresh = BrowseMCPClient(transport: transport)
            _ = try await fresh.start()
            return fresh
        }
        starting = task
        defer { starting = nil }
        let fresh = try await task.value
        await client?.close()
        // A new browse process may face a new browser: named tabs must be opened again.
        ensured = []
        client = fresh
        clientGeneration = generation
        let tools = await fresh.tools
        if !tools.isEmpty, tools != cachedTools {
            cachedTools = tools
            toolsCache?(tools)
        }
        return fresh
    }

    // MARK: Restarts and takeover

    /// The browser restarted (or its data was cleared): everything in flight fails, the pooled client is replaced, and
    /// every thread that used the browser hears why with its next result.
    public func browserRestarted(generation: Int, reason: String) async {
        _ = await gate.newGeneration()
        await client?.close()
        client = nil
        ensured = []
        numeric = [:]
        for session in activeSessions {
            var list = notices[session] ?? []
            list.append(reason + " Your tabs need to be opened again; take a fresh snapshot before acting.")
            notices[session] = Array(list.suffix(3))
        }
        activeSessions = []
    }

    public func pendingNotices(for session: String) -> [String] { notices[session] ?? [] }

    /// Closes a finished thread's `tabs` (NF11) in the browser this client already drives: closing never starts
    /// Chrome (a stopped browser has no tabs), and the person's control wins (nothing closes while they hold it).
    /// Returns the tabs closed.
    public func closeTabs(_ tabs: [String], session: String, group: String) async -> [String] {
        guard !tabs.isEmpty, let client, await !client.isClosed, clientGeneration == (await host.generation()) else { return [] }
        // A group operation of that thread: serialised with its other calls.
        guard let ticket = try? await gate.acquire(tab: "group:" + group, session: session, shared: false) else { return [] }
        var closing: [String] = []
        for tab in tabs where await !gate.isHumanControlled(tab) { closing.append(tab) }
        var closed: [String] = []
        if !closing.isEmpty,
            let result = try? await client.call("tabs", arguments: .object(["action": .string("close"), "tabs": .array(closing.map(JSONValue.string))]),
                                                timeout: .seconds(30)),
            !result.isError
        {
            closed = closing
            for tab in closed { ensured.remove("\(clientGeneration)|\(tab)") }
        }
        await gate.release(ticket)
        return closed
    }

    public func tabActivity() async -> [String: BrowserTabGate.TabActivity] { await gate.activity() }

    public func shutdown() async {
        await client?.close()
        client = nil
    }
}
