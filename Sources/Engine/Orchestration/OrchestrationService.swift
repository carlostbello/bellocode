import BelloCore
import Foundation
import Observation
import OpenCodeKit

/// One node for the UI. Observed per node, so one child changing state re-renders one row.
@MainActor
@Observable
public final class TaskNodeModel: Identifiable {
    public let id: SessionID
    public private(set) var node: TaskNode

    init(_ node: TaskNode) {
        id = node.id
        self.node = node
    }

    func update(_ newer: TaskNode) {
        if newer != node { node = newer }
    }
}

/// A lineage tree (a top-level thread and everything below it), for the Agents panel and the header strip.
/// `rows` changes only when the shape changes; `aggregate` only when a count changes.
@MainActor
@Observable
public final class LineageModel: Identifiable {
    public let rootID: SessionID
    public nonisolated var id: SessionID { rootID }
    /// Depth-first, the root first (depth 0).
    public private(set) var rows: [LineageRow] = []
    public private(set) var aggregate = LineageAggregate()

    init(rootID: SessionID) {
        self.rootID = rootID
    }

    func update(rows newRows: [LineageRow], aggregate newAggregate: LineageAggregate) {
        if newRows != rows { rows = newRows }
        if newAggregate != aggregate { aggregate = newAggregate }
    }

    public var hasChildren: Bool { rows.count > 1 }
}

/// Whether the bundled plugin answers for a location (its tools exist only when it does).
public enum OrchestrationPluginStatus: Hashable, Sendable {
    case unknown
    case ready(tools: Int)
    /// Loaded but a different contract version or tools missing: the tools may misbehave.
    case incompatible(String)
    case unavailable(String)

    public var label: String {
        switch self {
        case .unknown: "Checking orchestration tools…"
        case .ready(let tools): "Orchestration tools ready (\(tools))"
        case .incompatible(let reason): "Orchestration tools incompatible: \(reason)"
        case .unavailable(let reason): "Orchestration tools unavailable: \(reason)"
        }
    }

    public var isReady: Bool { if case .ready = self { true } else { false } }
}

/// The orchestration model (docs/features/orchestration.md): the task graph over every session (parent/child from
/// opencode, kind and summary from `metadata.bellocode`), node states with "waiting on children", aggregates, cascade
/// stop, follow-ups, and the app-hosted client-MCP tools.
///
/// Threading and ownership: `@MainActor`, owned by `Engine` (`engine.orchestration`). It subscribes to the `.lineage`
/// topic only (session and status changes, never tokens) and updates the node and lineage models a change touches.
/// Persistence: none of its own. The graph is rebuilt from the cached sessions at launch and from the server on resync;
/// opencode keeps parent links and the plugin's metadata, so children survive app restarts.
@MainActor
@Observable
public final class OrchestrationService {
    /// Bumps when any parent/child link or fan-out group changes (the sidebar re-nests then, never on state changes).
    public private(set) var structureRevision = 0
    public private(set) var pluginStatus: OrchestrationPluginStatus = .unknown

    /// The UI's handler for the `open_thread` app tool; returns false when no window can show it.
    @ObservationIgnored public var revealThread: (@MainActor (SessionID) -> Bool)?

    @ObservationIgnored public private(set) var graph = TaskGraph()
    @ObservationIgnored private var nodeModels: [SessionID: TaskNodeModel] = [:]
    @ObservationIgnored private var lineages: [SessionID: LineageModel] = [:]
    @ObservationIgnored private let core: EngineCore
    @ObservationIgnored private let store: ProjectionStore
    @ObservationIgnored private weak var engine: Engine?
    @ObservationIgnored private let tasks = TaskBox()
    @ObservationIgnored private var hosts: [String: ClientMCPHost] = [:]
    @ObservationIgnored private var started = false

    /// The client-MCP server name: tools appear to the agent as `bellocode_app_<tool>`.
    public static let appServerName = "bellocode_app"
    /// Locations served at once (each holds one WebSocket).
    public static let maxHostedLocations = 8

    init(core: EngineCore, store: ProjectionStore, engine: Engine) {
        self.core = core
        self.store = store
        self.engine = engine
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        let subscription = store.observe(.lineage)
        tasks.set(
            "lineage",
            Task { [weak self] in
                for await change in subscription {
                    guard let self else { return }
                    self.apply(change)
                }
            })
        reload()
    }

    func shutdown() async {
        tasks.cancelAll()
        let all = Array(hosts.values)
        hosts.removeAll()
        for host in all { await host.stop() }
        started = false
    }

    private func reload() {
        let core = self.core
        tasks.set(
            "reload",
            Task { [weak self] in
                let (sessions, statuses) = await core.allSessions()
                guard let self, !Task.isCancelled else { return }
                var graph = TaskGraph()
                graph.apply(sessions: sessions, statuses: statuses)
                self.replace(graph)
            })
    }

    private func replace(_ newGraph: TaskGraph) {
        let oldChildren = graph.children
        graph = newGraph
        for (id, node) in graph.nodes { nodeModels[id]?.update(node) }
        for id in nodeModels.keys where graph.nodes[id] == nil { nodeModels[id] = nil }
        for root in lineages.keys { refreshLineage(root) }
        if oldChildren != graph.children { structureRevision += 1 }
        refreshOpenThreads(Set(graph.nodes.keys))
    }

    func apply(_ change: ChangeSet) {
        if change.overflowed {
            reload()
            return
        }
        let before = graph.children
        let beforeGroups = Set(change.sessions.keys.compactMap { graph.nodes[$0]?.group })
        let result = graph.apply(
            sessions: Array(change.sessions.values), removed: Array(change.removedSessions), statuses: Array(change.statuses.values))
        for id in result.nodes {
            if let node = graph.nodes[id] { nodeModels[id]?.update(node) } else { nodeModels[id] = nil }
        }
        for root in result.roots where lineages[root] != nil { refreshLineage(root) }
        // A session that moved under a new root (rare) leaves its old lineage stale: refresh all then.
        let afterGroups = Set(change.sessions.keys.compactMap { graph.nodes[$0]?.group })
        if before != graph.children || beforeGroups != afterGroups {
            structureRevision += 1
            for root in lineages.keys { refreshLineage(root) }
        }
        refreshOpenThreads(result.nodes)
    }

    private func refreshLineage(_ root: SessionID) {
        lineages[root]?.update(rows: graph.rows(under: root), aggregate: graph.aggregate(under: root))
    }

    /// Re-decorates sub-agent cards in open parent threads whose child changed state.
    private func refreshOpenThreads(_ changed: Set<SessionID>) {
        guard let engine else { return }
        var byParent: [SessionID: Set<SessionID>] = [:]
        for id in changed { if let parent = graph.nodes[id]?.parentID { byParent[parent, default: []].insert(id) } }
        for (parent, children) in byParent { engine.loadedThread(parent)?.refreshChildStatus(children) }
    }

    // MARK: - Reads

    public func node(_ id: SessionID) -> TaskNodeModel? {
        if let model = nodeModels[id] { return model }
        guard let node = graph.nodes[id] else { return nil }
        let model = TaskNodeModel(node)
        nodeModels[id] = model
        return model
    }

    /// The lineage tree containing `id` (rooted at its top-level thread).
    public func lineage(containing id: SessionID) -> LineageModel {
        let root = graph.root(of: id)
        if let model = lineages[root] { return model }
        let model = LineageModel(rootID: root)
        model.update(rows: graph.rows(under: root), aggregate: graph.aggregate(under: root))
        lineages[root] = model
        if lineages.count > 64, let evict = lineages.keys.first(where: { $0 != root }) { lineages[evict] = nil }
        return model
    }

    public func children(of id: SessionID) -> [SessionID] { graph.children[id] ?? [] }
    public func rootID(of id: SessionID) -> SessionID { graph.root(of: id) }
    public func ancestors(of id: SessionID) -> [SessionID] { graph.ancestors(of: id) }
    public func status(of id: SessionID) -> ChildTaskStatus? { graph.nodes[id]?.status }

    /// The thread's own run ended while children still work (the thread status line says so).
    public func isWaitingOnChildren(_ id: SessionID) -> Bool { graph.nodes[id]?.status == .waitingOnChildren }

    /// Descendant counts, words ready ("2 running · 1 needs you"); empty without children.
    public func aggregate(under id: SessionID) -> LineageAggregate { graph.aggregate(under: id) }

    /// Top-level threads this thread created with `create_threads` (its fan-out), oldest first. Observable through
    /// `structureRevision`.
    public func createdThreads(by id: SessionID) -> [SessionID] {
        _ = structureRevision
        return graph.nodes.values.filter { $0.createdBy == id && $0.parentID == nil && $0.kind == .created }
            .sorted { $0.created == $1.created ? $0.id < $1.id : $0.created < $1.created }.map(\.id)
    }

    /// Top-level threads created by one `create_threads` call, oldest first.
    public func groupMembers(_ group: String) -> [SessionID] {
        graph.nodes.values.filter { $0.group == group && $0.parentID == nil }.sorted { $0.created < $1.created }.map(\.id)
    }

    // MARK: - Commands

    /// Stops a thread and every running descendant, deepest first (the plugin does the same for stops from any client;
    /// both are idempotent). A child's cancelled report would wake its parent: the plugin cuts that restart.
    public func stopTree(_ id: SessionID) async throws {
        let order = graph.descendants(of: id).reversed().filter { graph.nodes[$0]?.ownStatus.isActive == true }
        for child in order { try? await core.interrupt(child) }
        try await core.interrupt(id)
    }

    /// A follow-up to a child (or any thread): queued when it is running, else delivered now.
    @discardableResult
    public func sendFollowUp(_ text: String, to id: SessionID) async throws -> MessageID {
        let delivery: PromptDelivery? = graph.nodes[id]?.ownStatus.isActive == true ? .queue : nil
        return try await core.sendPrompt(id, text: text, attachments: .none, delivery: delivery)
    }

    /// Asks the plugin for its contract and tools in `directory` (call once the connection is live).
    public func checkPlugin(directory: String) async {
        do {
            let client = try await core.currentClient()
            let info = try await client.orchestrationInfo(directory: directory)
            if !info.isCompatible {
                pluginStatus = .incompatible("contract \(info.contract), expected \(OrchestrationContract.version)")
            } else if !info.missingTools.isEmpty {
                pluginStatus = .incompatible("missing \(info.missingTools.joined(separator: ", "))")
            } else {
                pluginStatus = .ready(tools: info.tools.count)
            }
        } catch let error as BrowserRPCError {
            if case .rpc(let type, _) = error, type.hasSuffix("unavailable") {
                pluginStatus = .unavailable("the bellocode plugin is not loaded")
            } else {
                pluginStatus = .unavailable(error.description)
            }
        } catch {
            pluginStatus = .unavailable("not connected")
        }
    }

    // MARK: - App-hosted tools (client MCP)

    /// Serves the app tools for these locations (at most `maxHostedLocations`; others are dropped first-in). Tools exist
    /// only while the app is connected; they vanish when it quits.
    public func hostAppTools(directories: [String]) async {
        let wanted = Array(directories.prefix(Self.maxHostedLocations))
        for (directory, host) in hosts where !wanted.contains(directory) {
            hosts[directory] = nil
            await host.stop()
        }
        guard let client = try? await core.currentClient() else { return }
        for directory in wanted where hosts[directory] == nil {
            let host = ClientMCPHost(
                name: Self.appServerName, directory: directory, dialer: WebSocketClientMCPDialer(connection: client.connection),
                provider: AppToolProvider(service: self))
            hosts[directory] = host
            await host.start()
        }
    }

    public var hostedDirectories: [String] { Array(hosts.keys).sorted() }

    /// Runs one app tool call. Calls must be attributed to a session; targets must be in the caller's project.
    func handleAppTool(_ call: ClientMCPCall) async -> ClientMCPResult {
        guard let caller = call.sessionID.map({ SessionID($0) }), let callerNode = graph.nodes[caller] else {
            return .error("BelloCode could not tell which thread made this call.")
        }
        let raw = call.arguments["threadID"]?.stringValue
        let id = raw.map { SessionID($0) } ?? caller
        guard let node = graph.nodes[id] else { return .error("No thread \(raw ?? id.rawValue).") }
        guard node.projectID == callerNode.projectID else {
            return .error("That thread is in another project; app tools act only within this project.")
        }
        if ExtrasTools.all.contains(call.tool), let engine {
            let project = engine.root.projects.first { $0.projectID == callerNode.projectID }?.directory ?? callerNode.directory
            let mode = await core.knownSession(caller)?.permissionMode
            let extrasCaller = ExtrasCaller(
                sessionID: caller, projectID: callerNode.projectID, directory: callerNode.directory, projectDirectory: project,
                permissionMode: mode)
            return await engine.extras.handle(call, caller: extrasCaller)
        }
        switch call.tool {
        case AppTools.openThread:
            guard raw != nil else { return .error("Give threadID.") }
            guard let reveal = revealThread, reveal(node.id) else { return .error("No BelloCode window is open.") }
            return ClientMCPResult(text: "Showing \"\(node.title)\" in BelloCode.")
        case AppTools.queue:
            return await queueTool(node, action: call.arguments["action"]?.stringValue ?? "list", item: call.arguments["messageID"]?.stringValue)
        default:
            return .error("Unknown tool \(call.tool).")
        }
    }

    private func queueTool(_ node: TaskNode, action: String, item: String?) async -> ClientMCPResult {
        let queued = await core.queuedPrompts(node.id)
        switch action {
        case "list":
            guard !queued.isEmpty else { return ClientMCPResult(text: "No queued messages for \"\(node.title)\".") }
            return ClientMCPResult(
                text: queued.map { "- \($0.id.rawValue) [\($0.delivery == .steer ? "steer" : "queue")] \(String($0.text.prefix(200)))" }
                    .joined(separator: "\n"))
        case "cancel", "steer":
            guard let item, queued.contains(where: { $0.id.rawValue == item }) else {
                return .error("No queued message \(item ?? "(missing messageID)") in that thread.")
            }
            do {
                if action == "cancel" { try await core.cancelQueued(MessageID(item)) } else { try await core.steerQueued(MessageID(item)) }
                return ClientMCPResult(text: action == "cancel" ? "Cancelled \(item)." : "\(item) will be delivered at the next step.")
            } catch {
                return .error(EngineError.from(error).userMessage)
            }
        default:
            return .error("Unknown action \(action): use list, cancel or steer.")
        }
    }
}

/// The app's client-MCP tools (`bellocode_app_*`). Later packages add HTML preview, secret requests and pull-request
/// tools here: a definition in `definitions` and a case in `OrchestrationService.handleAppTool`.
public enum AppTools {
    public static let openThread = "open_thread"
    public static let queue = "queue"

    public static let definitions: [ClientMCPTool] = [
        ClientMCPTool(
            name: openThread,
            description: "Show a thread of this project in the BelloCode window (for example a thread you created or delegated). Only while the app is open.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["threadID": .object(["type": .string("string"), "description": .string("Thread to show.")])]),
                "required": .array([.string("threadID")]),
            ])),
        ClientMCPTool(
            name: queue,
            description: "List, cancel or steer the queued messages of this thread or another thread of this project.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "threadID": .object(["type": .string("string"), "description": .string("Default: this thread.")]),
                    "action": .object(["type": .string("string"), "enum": .array([.string("list"), .string("cancel"), .string("steer")])]),
                    "messageID": .object(["type": .string("string"), "description": .string("For cancel and steer.")]),
                ]),
            ])),
    ]
}

/// Forwards client-MCP calls to the main-actor service.
struct AppToolProvider: ClientMCPToolProvider {
    let service: OrchestrationService

    func tools(directory: String) async -> [ClientMCPTool] { AppTools.definitions + ExtrasTools.definitions }
    func call(_ call: ClientMCPCall) async -> ClientMCPResult { await service.handleAppTool(call) }
}
