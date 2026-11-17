import BelloCore
import Engine
import Foundation

/// A drop of threads onto a sidebar section, resolved into organisation changes or a reason it is not allowed. Pure;
/// tested at model level (a real drag needs a person at the screen).
enum SidebarDrop {
    struct Proposal: Equatable, Sendable {
        /// The dragged threads, in display order, with their project directories and current organisation.
        var threads: [SessionID]
        var projectOf: [SessionID: String]
        var organisation: [SessionID: ThreadOrganisation]
        /// Where: a section of a project (`targetProject` nil when grouped by state), before `index` of the section's
        /// current rows `sectionRows` (top to bottom, the dragged rows included if they are in it).
        var targetProject: String?
        var targetSection: ThreadSection
        var index: Int
        var sectionRows: [SessionID]
        /// Each row's current manual sort key (creation time unless moved).
        var sortKeys: [SessionID: Double]
        var now: Timestamp
    }

    enum Outcome: Equatable, Sendable {
        /// The new organisation of each changed thread, and the short label for the drop badge ("Pin", "Settle").
        case move([SessionID: ThreadOrganisation], badge: String)
        case forbidden(String)

        var isAllowed: Bool { if case .move = self { true } else { false } }

        var badge: String {
            switch self {
            case .move(_, let badge): badge
            case .forbidden(let reason): reason
            }
        }
    }

    static let crossProjectReason = "Threads stay in their project’s folder"
    static let workingReason = "Working lists running threads; it follows the agent"

    static func resolve(_ proposal: Proposal, snoozeUntil: @autoclosure () -> Timestamp) -> Outcome {
        guard !proposal.threads.isEmpty else { return .forbidden("Nothing to move") }
        if let project = proposal.targetProject, proposal.threads.contains(where: { proposal.projectOf[$0] != project }) {
            return .forbidden(crossProjectReason)
        }
        guard proposal.targetSection.acceptsDrops else { return .forbidden(workingReason) }
        let transition: OrganisationTransition
        let badge: String
        let sources = Set(proposal.threads.map { section(of: proposal.organisation[$0] ?? .none) })
        switch proposal.targetSection {
        case .pinned:
            transition = .pin
            badge = sources == [.pinned] ? "Move" : "Pin"
        case .active:
            transition = .activate
            badge = switch sources.first {
            case .pinned where sources.count == 1: "Unpin"
            case .settled where sources.count == 1: "Un-settle"
            case .snoozed where sources.count == 1: "Wake"
            default: "Move"
            }
        case .settled:
            transition = .settle
            badge = "Settle"
        case .snoozed:
            let until = snoozeUntil()
            transition = .snooze(until: until)
            badge = "Snooze until \(ThreadRowPresentation.wakeText(until.date, now: proposal.now.date))"
        case .working:
            return .forbidden(workingReason)
        }
        var changes: [SessionID: ThreadOrganisation] = [:]
        for id in proposal.threads {
            changes[id] = (proposal.organisation[id] ?? .none).applying(transition, now: proposal.now)
        }
        if proposal.targetSection.isManuallyOrdered {
            let keys = sortKeys(
                inserting: proposal.threads, before: proposal.index, in: proposal.sectionRows, keys: proposal.sortKeys)
            for (id, key) in keys { changes[id, default: proposal.organisation[id] ?? .none].sortKey = key }
        }
        // A drop that changes nothing (same place) still succeeds; the caller skips the write.
        changes = changes.filter { $0.value != (proposal.organisation[$0.key] ?? .none) }
        return .move(changes, badge: badge)
    }

    /// The section a stored organisation puts a thread in, ignoring run state and wakes (for the badge wording).
    private static func section(of organisation: ThreadOrganisation) -> ThreadSection {
        if organisation.pinned { return .pinned }
        if organisation.snoozedUntil != nil { return .snoozed }
        if organisation.settled { return .settled }
        return .active
    }

    /// Manual keys (larger = higher) placing `moving` before position `index` of `rows`. Keys between the neighbours;
    /// when the neighbours leave no room, the whole section is renumbered (every row gets a key).
    static func sortKeys(
        inserting moving: [SessionID], before index: Int, in rows: [SessionID], keys: [SessionID: Double]
    ) -> [SessionID: Double] {
        let movingSet = Set(moving)
        // The index counts rows including the dragged ones; find the neighbours among the rows that stay.
        let clamped = max(0, min(index, rows.count))
        let above = rows[..<clamped].last { !movingSet.contains($0) }
        let below = rows[clamped...].first { !movingSet.contains($0) }
        let upper = above.flatMap { keys[$0] }
        let lower = below.flatMap { keys[$0] }
        let count = Double(moving.count)
        let step: Double
        let start: Double
        switch (upper, lower) {
        case (nil, nil):
            return Dictionary(uniqueKeysWithValues: moving.enumerated().map { ($1, Double(moving.count - $0) * 1_000) })
        case (let top?, nil):
            step = 1_000
            start = top - step
        case (nil, let bottom?):
            step = 1_000
            start = bottom + step * count
        case (let top?, let bottom?):
            step = (top - bottom) / (count + 1)
            start = top - step
        }
        // Room left? Keys must stay strictly between the neighbours and distinct.
        if step.magnitude < 1e-6 || !(start.isFinite) {
            var remaining = rows.filter { !movingSet.contains($0) }
            remaining.insert(contentsOf: moving, at: max(0, min(remaining.count, above.flatMap { remaining.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)))
            return Dictionary(uniqueKeysWithValues: remaining.enumerated().map { ($1, Double(remaining.count - $0) * 1_000) })
        }
        return Dictionary(uniqueKeysWithValues: moving.enumerated().map { ($1, start - Double($0) * step) })
    }
}
