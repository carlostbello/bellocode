import AppKit

/// A reversible action: applied at once, undoable from the toast (5 s) and from Edit > Undo (⌘Z), redoable with
/// ⇧⌘Z. Routine actions never ask for confirmation (AGENTS.md UX rule 3).
@MainActor
struct ReversibleAction {
    /// Edit menu name: "Undo <name>".
    var name: String
    /// Toast text: "Archived “Fix tests”".
    var message: String
    var apply: @MainActor () -> Void
    var revert: @MainActor () -> Void
}

/// One registered action. The token is the undo target, so a toast's Undo removes exactly its own entry from the
/// undo manager (`removeAllActions(withTarget:)`), even when typing has added entries above it.
@MainActor
final class UndoToken {
    let action: ReversibleAction
    fileprivate(set) var isUndone = false
    init(_ action: ReversibleAction) { self.action = action }
}

/// Performs reversible actions against an `UndoManager` and feeds the toast.
@MainActor
final class UndoCoordinator {
    private let undoManager: () -> UndoManager?
    private(set) var toasts = ToastQueue()
    /// Called when the visible toast changes (nil hides it).
    var onToastChange: ((ToastQueue.Entry?) -> Void)?
    private var expiryTask: Task<Void, Never>?

    init(undoManager: @escaping () -> UndoManager?) {
        self.undoManager = undoManager
    }

    @discardableResult
    func perform(_ action: ReversibleAction, now: Date = Date()) -> UndoToken {
        let token = UndoToken(action)
        action.apply()
        register(token, undo: true)
        let id = ObjectIdentifier(token)
        toasts.show(message: action.message, token: id, now: now)
        tokens = [id: token]
        publish()
        scheduleExpiry()
        return token
    }

    /// Shows a notice without Undo (for example a failure), replacing any toast.
    func showNotice(_ message: String, now: Date = Date()) {
        tokens.removeAll()
        toasts.show(message: message, token: nil, now: now)
        publish()
        scheduleExpiry()
    }

    /// The toast's Undo button.
    func undoFromToast() {
        guard let id = toasts.current?.token, let token = tokens[id] else { return }
        undoManager()?.removeAllActions(withTarget: token)
        if !token.isUndone {
            token.isUndone = true
            token.action.revert()
        }
        dismissToast()
    }

    func dismissToast() {
        if let id = toasts.current?.token { tokens[id] = nil }
        toasts.dismiss()
        publish()
    }

    private var tokens: [ObjectIdentifier: UndoToken] = [:]

    private func register(_ token: UndoToken, undo: Bool) {
        guard let manager = undoManager() else { return }
        manager.registerUndo(withTarget: token) { [weak self] token in
            MainActor.assumeIsolated {
                if undo {
                    token.isUndone = true
                    token.action.revert()
                    if let current = self?.toasts.current, current.token == ObjectIdentifier(token) { self?.dismissToast() }
                } else {
                    token.isUndone = false
                    token.action.apply()
                }
                self?.register(token, undo: !undo)
            }
        }
        manager.setActionName(token.action.name)
    }

    private func publish() { onToastChange?(toasts.current) }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let current = toasts.current else { return }
        let delay = current.expires.timeIntervalSinceNow
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled, let self else { return }
            if self.toasts.expire(now: Date()) {
                self.tokens.removeAll()
                self.publish()
            }
        }
    }
}

/// The toast model: one visible entry, replaced by a newer action, expiring after `duration`. Pure.
struct ToastQueue: Equatable {
    struct Entry: Equatable {
        var message: String
        /// nil for a plain notice (no Undo button), such as a failure.
        var token: ObjectIdentifier?
        var expires: Date
    }

    static let duration: TimeInterval = 5
    private(set) var current: Entry?

    @discardableResult
    mutating func show(message: String, token: ObjectIdentifier?, now: Date) -> Entry {
        let entry = Entry(message: message, token: token, expires: now.addingTimeInterval(Self.duration))
        current = entry
        return entry
    }

    /// Removes the current entry if it has expired; returns whether it did.
    mutating func expire(now: Date) -> Bool {
        guard let current, current.expires <= now else { return false }
        self.current = nil
        return true
    }

    mutating func dismiss() { current = nil }
}
