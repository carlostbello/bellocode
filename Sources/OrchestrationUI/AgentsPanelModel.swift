import BelloCore
import DesignSystem
import Engine
import Foundation
import Observation

/// State of one window's Agents panel (docs/features/orchestration.md): the lineage tree of the displayed thread, the
/// selected row, and an inline follow-up draft. The tree and node states come from `OrchestrationService` models, so a
/// child changing state re-renders its row only.
///
/// Threading and ownership: `@MainActor`, owned by the app's `AgentsSurfaces` (one per window). Commands run in tasks
/// owned by the model and are cancelled with it.
@MainActor
@Observable
public final class AgentsPanelModel {
    public let orchestration: OrchestrationService
    /// The displayed thread; nil for a draft.
    public private(set) var threadID: SessionID?
    /// The row the keyboard acts on (defaults to the displayed thread).
    public var selection: SessionID?
    /// The row whose follow-up field is open, and its text.
    public var followUpTarget: SessionID?
    public var followUpText = ""
    public private(set) var isSending = false
    /// The last command failure, shown under the header until the next command.
    public private(set) var errorMessage: String?

    /// Shows a thread in the window (the shell changes the selection; Back returns).
    @ObservationIgnored public var onOpen: ((SessionID) -> Void)?
    @ObservationIgnored private var commandTask: Task<Void, Never>?

    public init(orchestration: OrchestrationService) {
        self.orchestration = orchestration
    }

    isolated deinit { commandTask?.cancel() }

    public func display(_ threadID: SessionID?) {
        guard threadID != self.threadID else { return }
        self.threadID = threadID
        selection = threadID
        followUpTarget = nil
        followUpText = ""
        errorMessage = nil
    }

    /// The tree containing the displayed thread.
    public var lineage: LineageModel? { threadID.map { orchestration.lineage(containing: $0) } }

    public var selectedNode: TaskNode? { (selection ?? threadID).flatMap { orchestration.node($0)?.node } }

    // MARK: Commands (menu items, buttons and keys call these)

    public func open(_ id: SessionID) {
        guard id != threadID else { return }
        onOpen?(id)
    }

    public func openSelected() {
        if let id = selection { open(id) }
    }

    /// Opens the parent of the displayed thread (the "back to parent" of a child).
    public func openParent() {
        guard let id = threadID, let parent = orchestration.node(id)?.node.parentID else { return }
        onOpen?(parent)
    }

    public func canStop(_ id: SessionID) -> Bool {
        guard let node = orchestration.node(id)?.node else { return false }
        return node.status.isActive && node.status != .stopping
    }

    /// Stops the thread and everything below it (a stop is reversible by sending again: no confirmation).
    public func stop(_ id: SessionID) {
        errorMessage = nil
        let orchestration = self.orchestration
        commandTask = Task { [weak self] in
            do { try await orchestration.stopTree(id) } catch {
                self?.errorMessage = (error as? EngineError)?.userMessage ?? "The thread could not be stopped."
            }
        }
    }

    public func beginFollowUp(_ id: SessionID) {
        followUpTarget = id
        selection = id
    }

    public func cancelFollowUp() {
        followUpTarget = nil
        followUpText = ""
    }

    /// Sends the follow-up (queued when the child is running). The text stays until the server accepts it.
    public func sendFollowUp() {
        guard let target = followUpTarget, !isSending else { return }
        let text = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        errorMessage = nil
        let orchestration = self.orchestration
        commandTask = Task { [weak self] in
            do {
                try await orchestration.sendFollowUp(text, to: target)
                guard let self, !Task.isCancelled else { return }
                self.isSending = false
                if self.followUpTarget == target { self.cancelFollowUp() }
            } catch {
                guard let self else { return }
                self.isSending = false
                self.errorMessage = (error as? EngineError)?.userMessage ?? "The follow-up was not sent."
            }
        }
    }

    /// Moves the selection through the visible rows (↑/↓ in the panel).
    public func moveSelection(by offset: Int) {
        guard let rows = lineage?.rows, !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == (selection ?? threadID) } ?? 0
        selection = rows[max(0, min(rows.count - 1, current + offset))].id
    }
}

// MARK: - Text shared by the panel, the header strip and the status line

public enum OrchestrationText {
    /// "Waiting on 2 children" for the thread status line; nil unless the thread waits on children. Reads observable
    /// models only, so a view rendering it refreshes when a child changes state.
    @MainActor
    public static func waitingStatus(_ orchestration: OrchestrationService, _ id: SessionID) -> String? {
        guard orchestration.node(id)?.node.status == .waitingOnChildren else { return nil }
        let lineage = orchestration.lineage(containing: id)
        let children = lineage.rows.filter { row in orchestration.node(row.id)?.node.parentID == id }
        let active = children.filter { orchestration.node($0.id)?.node.status.isActive == true }.count
        return active == 1 ? "Waiting on 1 child" : "Waiting on \(active) children"
    }

    /// The header strip: "Agents · 2 running · 1 needs you" for a top-level thread with children; "Child of “Title”"
    /// for a child; nil when the thread has no lineage.
    @MainActor
    public static func strip(_ orchestration: OrchestrationService, _ id: SessionID) -> (text: String, isChild: Bool)? {
        if let parent = orchestration.node(id)?.node.parentID {
            let title = orchestration.node(parent)?.node.title ?? "parent thread"
            return ("Child of “\(title)”", true)
        }
        let lineage = orchestration.lineage(containing: id)
        guard lineage.rootID == id, lineage.aggregate.total > 0 else { return nil }
        return ("Agents · " + lineage.aggregate.text, false)
    }

    /// "4 s", "2 m", "1 h 5 m" (elapsed since a run started).
    public static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) m" }
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(seconds / 3600) h" : "\(seconds / 3600) h \(minutes) m"
    }
}
