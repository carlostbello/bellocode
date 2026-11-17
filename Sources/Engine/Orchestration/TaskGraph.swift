import BelloCore
import Foundation
import OpenCodeKit

/// How a session came to exist, for the Agents panel and the sidebar (docs/features/orchestration.md).
public enum TaskKind: String, Hashable, Sendable {
    /// A top-level thread the person started.
    case thread
    /// A child from opencode's native `subagent` tool (or a child created by any other client).
    case subagent
    /// A child from the plugin's `delegate_task`.
    case delegated
    /// A top-level thread an agent created with `create_threads` (a fan-out group).
    case created

    public var label: String {
        switch self {
        case .thread: "Thread"
        case .subagent: "Sub-agent"
        case .delegated: "Delegated task"
        case .created: "Created thread"
        }
    }
}

/// What the plugin records on a session (`metadata.bellocode`; `Plugin/src/logic.ts` `BelloMeta`).
public struct OrchestrationMetadata: Hashable, Sendable, Decodable {
    public var kind: String?
    public var by: String?
    public var group: String?
    public var description: String?
    public var workspace: String?
    public var background: Bool?
    public var summary: String?
    public var outcome: String?
    public var settledAt: Double?

    /// Decodes `metadata.bellocode` from a session's metadata JSON; nil when absent or malformed.
    public static func from(_ metadata: RawJSON?) -> OrchestrationMetadata? {
        guard let metadata, let data = metadata.text.data(using: .utf8),
            let root = try? JSONDecoder().decode([String: JSONValue].self, from: data),
            let value = root[OrchestrationContract.metadataKey], let encoded = try? value.encodedData()
        else { return nil }
        return try? JSONDecoder().decode(OrchestrationMetadata.self, from: encoded)
    }
}

/// One node of a lineage tree: a session and what the Agents panel shows for it.
public struct TaskNode: Hashable, Sendable, Identifiable {
    public var id: SessionID
    public var parentID: SessionID?
    public var projectID: ProjectID
    public var directory: String
    public var title: String
    public var kind: TaskKind
    /// This session's state including its children (`waitingOnChildren` when its own run ended first).
    public var status: ChildTaskStatus
    /// Its own run only.
    public var ownStatus: ChildTaskStatus
    /// The last meaningful update: the plugin's summary of the last finished round, else nil.
    public var summary: String?
    public var agent: String?
    public var model: ModelSelection?
    public var created: Timestamp
    /// Start of the current or last run.
    public var startedAt: Timestamp?
    /// When the status last changed (attention `since`, else the session's update time).
    public var since: Timestamp
    /// The thread whose tool call created it (`delegate_task`, `create_threads`).
    public var createdBy: SessionID?
    /// Threads from one `create_threads` call.
    public var group: String?
    public var inWorktree: Bool
    /// The child that blocks this thread (an approval or question somewhere below), from the attention model.
    public var blockingChildID: SessionID?

    /// "Running · build · opencode/big-pickle" style detail, words only.
    public var detail: String {
        var parts = [status.label]
        if let agent { parts.append("@" + agent) }
        if let model { parts.append(model.modelID + (model.variant.map { " " + $0 } ?? "")) }
        return parts.joined(separator: " · ")
    }
}

/// Counts over a lineage tree's descendants, for "2 running · 1 needs you".
public struct LineageAggregate: Hashable, Sendable {
    public var total = 0
    public var running = 0
    public var needsYou = 0
    public var failed = 0
    public var done = 0
    public var stopped = 0

    public init() {}

    /// Words only, zeros left out; empty when there are no children.
    public var text: String {
        guard total > 0 else { return "" }
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if needsYou > 0 { parts.append("\(needsYou) need\(needsYou == 1 ? "s" : "") you") }
        if failed > 0 { parts.append("\(failed) failed") }
        if parts.isEmpty {
            if done > 0 { parts.append("\(done) done") }
            if stopped > 0 { parts.append("\(stopped) stopped") }
        }
        if parts.isEmpty { parts.append("\(total) idle") }
        return parts.joined(separator: " · ")
    }

    mutating func add(_ status: ChildTaskStatus) {
        total += 1
        switch status {
        case .running, .waitingOnChildren, .stopping: running += 1
        case .needsApproval, .needsAnswer: needsYou += 1
        case .failed: failed += 1
        case .done: done += 1
        case .stopped: stopped += 1
        case .idle, .unknown: break
        }
    }
}

/// The task state machine: a session's own state from opencode's run state and the attention model, then the state
/// including its children. Pure; unit-tested.
public enum TaskStateMachine {
    /// Own state. A bubbled blocker (`blockingChildID` set) belongs to the child, not to this session.
    public static func ownStatus(session: Session, attention: SessionAttention?) -> ChildTaskStatus {
        if let attention, attention.blockingChildID == nil {
            switch attention.status {
            case .awaitingApproval: return .needsApproval
            case .awaitingAnswer: return .needsAnswer
            case .stopping: return .stopping
            case .running: return .running
            case .failed: return .failed
            case .unknown: return .unknown
            case .finishedUnread, .idle: break
            }
        } else if session.isRunning {
            return .running
        }
        switch session.outcome {
        case .succeeded: return .done
        case .interrupted: return .stopped
        case .failed: return .failed
        case nil: return session.isRunning ? .running : .idle
        }
    }

    /// State including children: a session whose own run ended while children still work is waiting on them, not done.
    public static func status(own: ChildTaskStatus, children: [ChildTaskStatus]) -> ChildTaskStatus {
        switch own {
        case .needsApproval, .needsAnswer, .running, .stopping, .failed, .unknown: return own
        case .done, .idle, .waitingOnChildren:
            return children.contains(where: \.isActive) ? .waitingOnChildren : (own == .waitingOnChildren ? .done : own)
        case .stopped:
            // A cascade in progress: the parent stopped, its children are being stopped.
            return children.contains(where: \.isActive) ? .stopping : .stopped
        }
    }

    public static func kind(session: Session, metadata: OrchestrationMetadata?) -> TaskKind {
        switch metadata?.kind {
        case "delegated": return .delegated
        case "created": return session.parentID == nil ? .created : .delegated
        default: return session.parentID == nil ? .thread : .subagent
        }
    }
}

/// The parent/child graph of every known session, with derived node states. A value: the service rebuilds the parts a
/// change touches (the changed sessions and their ancestors).
public struct TaskGraph: Sendable {
    public private(set) var sessions: [SessionID: Session] = [:]
    public private(set) var attention: [SessionID: SessionAttention] = [:]
    public private(set) var children: [SessionID: [SessionID]] = [:]
    public private(set) var nodes: [SessionID: TaskNode] = [:]
    private var metadata: [SessionID: OrchestrationMetadata] = [:]

    public init() {}

    /// Applies session and status changes; returns the IDs whose node changed (including ancestors whose derived status
    /// changed) and the roots whose tree changed shape or state.
    @discardableResult
    public mutating func apply(
        sessions changed: [Session], removed: [SessionID] = [], statuses: [SessionAttention] = []
    ) -> (nodes: Set<SessionID>, roots: Set<SessionID>) {
        var dirty: Set<SessionID> = []
        var roots: Set<SessionID> = []
        for id in removed {
            guard let old = sessions.removeValue(forKey: id) else { continue }
            roots.insert(root(of: old.parentID ?? id))
            if let parent = old.parentID {
                children[parent]?.removeAll { $0 == id }
                dirty.insert(parent)
            }
            attention[id] = nil
            metadata[id] = nil
            nodes[id] = nil
        }
        for session in changed {
            let old = sessions[session.id]
            if old?.parentID != session.parentID {
                if let previous = old?.parentID { children[previous]?.removeAll { $0 == session.id } }
                if let parent = session.parentID {
                    var list = children[parent] ?? []
                    if !list.contains(session.id) {
                        list.append(session.id)
                        list.sort { lhs, rhs in
                            let a = sessions[lhs]?.created ?? session.created
                            let b = sessions[rhs]?.created ?? session.created
                            return a == b ? lhs < rhs : a < b
                        }
                    }
                    children[parent] = list
                    dirty.insert(parent)
                }
            }
            sessions[session.id] = session
            if old?.metadata != session.metadata || old == nil { metadata[session.id] = OrchestrationMetadata.from(session.metadata) }
            dirty.insert(session.id)
        }
        for status in statuses {
            attention[status.sessionID] = status
            dirty.insert(status.sessionID)
        }
        // Recompute dirty nodes and walk up while the derived status changes (a parent's state depends on its children).
        var queue = Array(dirty)
        var changedNodes: Set<SessionID> = []
        var steps = 0
        while let id = queue.popLast(), steps < 20_000 {
            steps += 1
            guard let node = makeNode(id) else { continue }
            guard nodes[id] != node else { continue }
            let statusChanged = nodes[id]?.status != node.status
            nodes[id] = node
            changedNodes.insert(id)
            roots.insert(root(of: id))
            if statusChanged, let parent = node.parentID { queue.insert(parent, at: 0) }
        }
        return (changedNodes, roots)
    }

    private func makeNode(_ id: SessionID) -> TaskNode? {
        guard let session = sessions[id] else { return nil }
        let meta = metadata[id]
        let attention = attention[id]
        let own = TaskStateMachine.ownStatus(session: session, attention: attention)
        let childStatuses = (children[id] ?? []).compactMap { nodes[$0]?.status }
        let status = TaskStateMachine.status(own: own, children: childStatuses)
        let title = session.title.flatMap { $0.isEmpty ? nil : $0 } ?? meta?.description ?? session.displayTitle
        return TaskNode(
            id: id, parentID: session.parentID, projectID: session.projectID, directory: session.directory, title: title,
            kind: TaskStateMachine.kind(session: session, metadata: meta), status: status, ownStatus: own,
            summary: meta?.summary.flatMap { $0.isEmpty ? nil : $0 }, agent: session.agent, model: session.model,
            created: session.created, startedAt: session.busySince, since: attention?.since ?? session.updated,
            createdBy: meta?.by.map { SessionID($0) }, group: meta?.group, inWorktree: meta?.workspace == "worktree",
            blockingChildID: attention?.blockingChildID)
    }

    /// The top-level ancestor (itself when top-level or when the parent is unknown).
    public func root(of id: SessionID) -> SessionID {
        var current = id
        var guardCount = 0
        while let parent = sessions[current]?.parentID, sessions[parent] != nil, guardCount < 64 {
            current = parent
            guardCount += 1
        }
        return current
    }

    public func ancestors(of id: SessionID) -> [SessionID] {
        var result: [SessionID] = []
        var current = id
        while let parent = sessions[current]?.parentID, sessions[parent] != nil, result.count < 64 {
            result.append(parent)
            current = parent
        }
        return result
    }

    /// Depth-first rows under `root` (the root first, depth 0), children oldest first.
    public func rows(under root: SessionID) -> [LineageRow] {
        guard sessions[root] != nil else { return [] }
        var rows: [LineageRow] = []
        func visit(_ id: SessionID, _ depth: Int) {
            guard rows.count < 2_000 else { return }
            rows.append(LineageRow(id: id, depth: depth))
            for child in children[id] ?? [] { visit(child, depth + 1) }
        }
        visit(root, 0)
        return rows
    }

    /// Every descendant, parents before children.
    public func descendants(of id: SessionID) -> [SessionID] {
        rows(under: id).dropFirst().map(\.id)
    }

    public func aggregate(under root: SessionID) -> LineageAggregate {
        var aggregate = LineageAggregate()
        for id in descendants(of: root) {
            if let node = nodes[id] { aggregate.add(node.status) }
        }
        return aggregate
    }
}

public struct LineageRow: Hashable, Sendable, Identifiable {
    public var id: SessionID
    public var depth: Int
}
