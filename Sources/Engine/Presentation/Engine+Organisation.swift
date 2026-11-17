import BelloCore
import Foundation

/// Sidebar organisation commands (docs/features/navigation.md). App-owned state: applied at once, persisted by the
/// write-behind, never sent to opencode, so they cannot fail on the network. Undo restores the previous values with
/// `setOrganisation(_:)`.
extension Engine {
    /// The organisation of a thread (`.none` when it has none).
    public func organisation(of id: SessionID) -> ThreadOrganisation { root.organisation[id] ?? .none }

    /// Applies a transition to several threads; returns their previous values (for Undo).
    @discardableResult
    public func organise(_ ids: [SessionID], _ transition: OrganisationTransition, now: Timestamp = .now) -> [SessionID: ThreadOrganisation] {
        var previous: [SessionID: ThreadOrganisation] = [:]
        var next: [SessionID: ThreadOrganisation] = [:]
        for id in ids {
            let current = organisation(of: id)
            previous[id] = current
            next[id] = current.applying(transition, now: now)
        }
        setOrganisation(next)
        return previous
    }

    /// Replaces the organisation of threads (drops, undo). Shown at once; persisted behind.
    public func setOrganisation(_ values: [SessionID: ThreadOrganisation]) {
        guard !values.isEmpty else { return }
        // Optimistic in the root (the change also arrives through the store's topic, with the same values).
        var root = self.root.organisation
        for (id, value) in values { root[id] = value == .none ? nil : value }
        if root != self.root.organisation { self.root.organisation = root }
        let core = self.core
        let previous = organisationWrite
        let write = Task {
            await previous?.value
            await core.setOrganisation(values)
        }
        organisationWrite = write
        track(write)
    }

    /// Changes the auto-settle rules and applies them at once.
    public func setOrganisationRules(_ rules: OrganisationRules) {
        root.organisationRules = rules
        let core = self.core
        track(Task { await core.setOrganisationRules(rules) })
    }

    /// Runs the wake and auto-settle rules now (tests; the engine also runs them on events and on a timer).
    public func organiseNow() async {
        await organisationWrite?.value
        await core.organise()
    }

    /// Pending approvals and questions of a thread and its sub-agents, oldest first, from the engine's state (the
    /// thread need not be open). For notification actions, which must check the request is still pending.
    public func pendingRequests(for id: SessionID) async -> [PendingRequest] { await core.pendingRequests(for: id) }

    /// Section inputs for every top-level, unarchived thread, from the engine's state.
    public func sectionInputs() async -> [ThreadSectionInput] { await core.organisationInputs() }
}
