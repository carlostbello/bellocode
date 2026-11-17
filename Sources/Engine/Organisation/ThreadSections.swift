import BelloCore
import Foundation

/// A sidebar section (docs/features/navigation.md). Every thread is in exactly one.
public enum ThreadSection: String, CaseIterable, Hashable, Sendable, Codable {
    /// Kept at the top by the user, whatever its status.
    case pinned
    /// Needs the user or was recently active: everything not pinned, running, snoozed or settled.
    case active
    /// Running (or stopping, or status unknown), in the order the runs started: rows never reshuffle while agents work.
    case working
    /// Out of sight until a time, or until it needs the user or gets a new turn.
    case snoozed
    /// Done. Collapsed by default; un-settles on new activity that needs the user.
    case settled

    public var title: String {
        switch self {
        case .pinned: "Pinned"
        case .active: "Active"
        case .working: "Working"
        case .snoozed: "Snoozed"
        case .settled: "Settled"
        }
    }

    public var symbolName: String {
        switch self {
        case .pinned: "pin.fill"
        case .active: "tray"
        case .working: "circle.dotted"
        case .snoozed: "moon.zzz"
        case .settled: "checkmark.circle"
        }
    }

    /// Collapsed until the user expands it.
    public var isCollapsedByDefault: Bool { self == .snoozed || self == .settled }

    /// Whether a thread can be dropped here (Working follows the run state, not the user).
    public var acceptsDrops: Bool { self != .working }

    /// Whether rows are in a manual order the user can drag (else the order is derived).
    public var isManuallyOrdered: Bool { self == .pinned || self == .active }
}

/// Auto-settle and snooze defaults (Settings ▸ Threads). Stored by the engine (`app_preference`).
public struct OrganisationRules: Hashable, Sendable, Codable {
    /// Settle a finished thread this many hours after it was last viewed. nil: never.
    public var autoSettleAfterHours: Double?

    public init(autoSettleAfterHours: Double? = 7 * 24) {
        self.autoSettleAfterHours = autoSettleAfterHours
    }

    public static let `default` = OrganisationRules()
    /// The choices Settings offers, in hours (nil = never).
    public static let autoSettleChoices: [Double?] = [nil, 1, 8, 24, 72, 7 * 24]
}

/// What a sidebar section needs to know about one top-level thread.
public struct ThreadSectionInput: Hashable, Sendable {
    public var sessionID: SessionID
    public var created: Timestamp
    /// When the current (or last) run started.
    public var busySince: Timestamp?
    /// When the last run ended.
    public var idleAt: Timestamp?
    /// When the user last saw it: the later of opencode's `viewed` and the local visit watermark.
    public var seenAt: Timestamp?
    public var status: SessionStatus
    /// When the status began (request received, run ended, …).
    public var statusSince: Timestamp
    public var organisation: ThreadOrganisation

    public init(
        sessionID: SessionID, created: Timestamp, busySince: Timestamp? = nil, idleAt: Timestamp? = nil,
        seenAt: Timestamp? = nil, status: SessionStatus, statusSince: Timestamp? = nil,
        organisation: ThreadOrganisation = .none
    ) {
        self.sessionID = sessionID
        self.created = created
        self.busySince = busySince
        self.idleAt = idleAt
        self.seenAt = seenAt
        self.status = status
        self.statusSince = statusSince ?? idleAt ?? busySince ?? created
        self.organisation = organisation
    }

    public var isRunning: Bool { status == .running || status == .stopping || status == .unknown }
    /// The manual order key (creation time unless the user moved it).
    public var sortKey: Double { organisation.sortKey ?? created.milliseconds }
}

/// Why a snoozed or settled thread came back.
public enum WakeReason: String, Hashable, Sendable {
    case timeArrived, needsUser, failed, newTurn, finished
}

/// Section membership, ordering, wake rules and auto-settle. Pure (the clock is a parameter); tested directly.
///
/// Rules:
/// - Pinned wins over everything. Otherwise a snoozed thread stays snoozed until its time, or until it is blocked on
///   the user, fails or starts a run after it was snoozed. A settled thread stays settled until it is blocked, fails,
///   starts a run, or finishes a run after it was settled. Then running threads are Working, the rest Active.
/// - Order: Pinned and Active by the manual key, larger first (default: newest created first); Working by run start,
///   oldest first (new runs join at the end); Snoozed by wake time, soonest first; Settled by settle time, newest first.
public enum ThreadSections {
    public static func wakeReason(_ input: ThreadSectionInput, now: Timestamp) -> WakeReason? {
        let org = input.organisation
        if let until = org.snoozedUntil {
            let since = org.snoozedAt ?? Timestamp(milliseconds: 0)
            if until <= now { return .timeArrived }
            if let reason = activityReason(input, after: since, includesFinish: false) { return reason }
            return nil
        }
        if org.settled {
            return activityReason(input, after: org.settledAt ?? Timestamp(milliseconds: 0), includesFinish: true)
        }
        return nil
    }

    private static func activityReason(_ input: ThreadSectionInput, after since: Timestamp, includesFinish: Bool) -> WakeReason? {
        if input.status.isBlocking { return .needsUser }
        if input.status == .failed, input.statusSince > since { return .failed }
        if input.isRunning, let busy = input.busySince, busy > since { return .newTurn }
        if includesFinish, input.status == .finishedUnread, input.statusSince > since { return .finished }
        return nil
    }

    public static func section(_ input: ThreadSectionInput, now: Timestamp) -> ThreadSection {
        let org = input.organisation
        if org.pinned { return .pinned }
        let woken = wakeReason(input, now: now) != nil
        if org.snoozedUntil != nil, !woken { return .snoozed }
        if org.settled, !woken { return .settled }
        return input.isRunning ? .working : .active
    }

    /// Every section's threads in display order (empty sections included, in `ThreadSection.allCases` order).
    public static func derive(_ inputs: [ThreadSectionInput], now: Timestamp) -> [ThreadSection: [SessionID]] {
        var grouped: [ThreadSection: [ThreadSectionInput]] = [:]
        for input in inputs { grouped[section(input, now: now), default: []].append(input) }
        var result: [ThreadSection: [SessionID]] = [:]
        for section in ThreadSection.allCases {
            result[section] = order(grouped[section] ?? [], in: section).map(\.sessionID)
        }
        return result
    }

    public static func order(_ inputs: [ThreadSectionInput], in section: ThreadSection) -> [ThreadSectionInput] {
        func byID(_ a: ThreadSectionInput, _ b: ThreadSectionInput) -> Bool { a.sessionID > b.sessionID }
        switch section {
        case .pinned, .active:
            return inputs.sorted { $0.sortKey != $1.sortKey ? $0.sortKey > $1.sortKey : byID($0, $1) }
        case .working:
            return inputs.sorted {
                let a = $0.busySince ?? $0.created
                let b = $1.busySince ?? $1.created
                return a != b ? a < b : byID($0, $1)
            }
        case .snoozed:
            return inputs.sorted {
                let a = $0.organisation.snoozedUntil ?? $0.created
                let b = $1.organisation.snoozedUntil ?? $1.created
                return a != b ? a < b : byID($0, $1)
            }
        case .settled:
            return inputs.sorted {
                let a = $0.organisation.settledAt ?? $0.created
                let b = $1.organisation.settledAt ?? $1.created
                return a != b ? a > b : byID($0, $1)
            }
        }
    }

    /// Whether the auto-settle rule settles this thread now: finished and seen, not pinned, snoozed, settled or opted
    /// out, nothing pending, and both the run's end and the last view at least `hours` ago.
    public static func shouldAutoSettle(_ input: ThreadSectionInput, rules: OrganisationRules, now: Timestamp) -> Bool {
        guard let deadline = autoSettleDeadline(input, rules: rules) else { return false }
        return deadline <= now
    }

    /// When the auto-settle rule will settle this thread (nil: it will not, as things stand).
    public static func autoSettleDeadline(_ input: ThreadSectionInput, rules: OrganisationRules) -> Timestamp? {
        let org = input.organisation
        guard let hours = rules.autoSettleAfterHours, !org.pinned, !org.settled, org.snoozedUntil == nil,
              !org.neverAutoSettle, !org.markedUnread, input.status == .idle
        else { return nil }
        let reference = max(input.idleAt ?? input.created, input.seenAt ?? input.created)
        return Timestamp(milliseconds: reference.milliseconds + hours * 3_600_000)
    }

    /// The next time a timed rule (snooze end, auto-settle) changes something, for the engine's timer.
    public static func nextDeadline(_ inputs: [ThreadSectionInput], rules: OrganisationRules, now: Timestamp) -> Timestamp? {
        var next: Timestamp?
        for input in inputs {
            var candidate: Timestamp?
            if let until = input.organisation.snoozedUntil, until > now, !input.organisation.pinned {
                candidate = until
            } else if let deadline = autoSettleDeadline(input, rules: rules), deadline > now {
                candidate = deadline
            }
            if let candidate, next.map({ candidate < $0 }) ?? true { next = candidate }
        }
        return next
    }

    /// The organisation changes the rules make now: wakes (snooze or settle cleared; the thread returns to the top of
    /// Active) and auto-settles. Applied and persisted by the engine so a resolved blocker never re-hides the thread.
    public static func pendingChanges(
        _ inputs: [ThreadSectionInput], rules: OrganisationRules, now: Timestamp
    ) -> [SessionID: ThreadOrganisation] {
        var changes: [SessionID: ThreadOrganisation] = [:]
        for input in inputs {
            var org = input.organisation
            if org.pinned, org.snoozedUntil != nil || org.settled {
                // Pinned wins; drop a stale snooze or settle.
                org.snoozedUntil = nil
                org.snoozedAt = nil
                org.settled = false
                org.settledAt = nil
            } else if wakeReason(input, now: now) != nil {
                org.apply(.wake, now: now)
            } else if shouldAutoSettle(input, rules: rules, now: now) {
                org.apply(.settle, now: now)
            }
            if org != input.organisation { changes[input.sessionID] = org }
        }
        return changes
    }
}

/// A user action on a thread's organisation.
public enum OrganisationTransition: Hashable, Sendable {
    case pin, unpin, settle, unsettle, wake
    case snooze(until: Timestamp)
    /// Into Active: unpinned, not snoozed or settled.
    case activate
    case setNeverAutoSettle(Bool)
    case setMarkedUnread(Bool)
    /// A manual position (nil: back to the default order).
    case setSortKey(Double?)
}

extension ThreadOrganisation {
    public mutating func apply(_ transition: OrganisationTransition, now: Timestamp) {
        switch transition {
        case .pin:
            pinned = true
            clearShelves()
        case .unpin:
            pinned = false
        case .settle:
            settled = true
            settledAt = now
            pinned = false
            snoozedUntil = nil
            snoozedAt = nil
        case .unsettle, .wake:
            // Back at the top of Active.
            clearShelves()
            sortKey = now.milliseconds
        case .snooze(let until):
            snoozedUntil = until
            snoozedAt = now
            pinned = false
            settled = false
            settledAt = nil
        case .activate:
            pinned = false
            clearShelves()
        case .setNeverAutoSettle(let never):
            neverAutoSettle = never
        case .setMarkedUnread(let unread):
            markedUnread = unread
        case .setSortKey(let key):
            sortKey = key
        }
    }

    public func applying(_ transition: OrganisationTransition, now: Timestamp) -> ThreadOrganisation {
        var copy = self
        copy.apply(transition, now: now)
        return copy
    }

    private mutating func clearShelves() {
        snoozedUntil = nil
        snoozedAt = nil
        settled = false
        settledAt = nil
    }

    public var isSnoozed: Bool { snoozedUntil != nil }
}

/// Snooze presets (later today, tomorrow, next week), computed in the user's calendar. Pure.
public enum SnoozePreset: String, CaseIterable, Hashable, Sendable {
    case laterToday, tomorrow, nextWeek

    public var title: String {
        switch self {
        case .laterToday: "Later Today"
        case .tomorrow: "Tomorrow"
        case .nextWeek: "Next Week"
        }
    }

    /// Later today: three hours from now, rounded up to the hour, or 18:00 when that is sooner and at least an hour away;
    /// when that would be 22:00 or later it is tomorrow morning. Tomorrow: 09:00 tomorrow. Next week: 09:00 on the
    /// coming Monday.
    public func date(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .laterToday:
            // Never past 22:00 or into tomorrow: then it is tomorrow morning.
            let inThree = now.addingTimeInterval(3 * 3600)
            let rounded = calendar.nextDate(after: inThree, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? inThree
            let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? rounded
            let candidate = evening > now.addingTimeInterval(3600) && evening < rounded ? evening : rounded
            if !calendar.isDate(candidate, inSameDayAs: now) || calendar.component(.hour, from: candidate) >= 22 {
                return Self.tomorrow.date(from: now, calendar: calendar)
            }
            return candidate
        case .tomorrow:
            let start = calendar.startOfDay(for: now)
            let day = calendar.date(byAdding: .day, value: 1, to: start) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        case .nextWeek:
            let monday = calendar.nextDate(
                after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime) ?? now
            // From a Monday morning before 9, the Monday after.
            return calendar.isDate(monday, inSameDayAs: now) ? monday.addingTimeInterval(7 * 86_400) : monday
        }
    }
}
