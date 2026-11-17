import BelloCore
import Foundation

// Scheduled tasks (docs/features/orchestration-extras.md): definitions, run records and the pure arithmetic that
// decides when a task is due. BelloCode's own scheduler (not opencode's experimental schedules, which bind to one
// existing session, cannot start a new thread per run, cannot be edited and keep no history).

/// When a task runs.
public enum ScheduleRule: Hashable, Sendable, Codable {
    /// Every `minutes` (at least 1), counted from the task's anchor (creation, or the last edit of the rule).
    case interval(minutes: Int)
    /// At `hour:minute` local time (the task's time zone) on `weekdays` (Calendar numbering: 1 = Sunday … 7 =
    /// Saturday); empty means every day.
    case daily(hour: Int, minute: Int, weekdays: [Int])
    /// Once, at a date.
    case once(Date)

    public static let minimumIntervalMinutes = 1

    /// "Every 30 minutes", "Weekdays at 09:00", "Once on 17 Nov 2026 at 09:00".
    public func summary(timeZone: TimeZone) -> String {
        switch self {
        case .interval(let minutes):
            if minutes % 1440 == 0 { return minutes == 1440 ? "Every day" : "Every \(minutes / 1440) days" }
            if minutes % 60 == 0 { return minutes == 60 ? "Every hour" : "Every \(minutes / 60) hours" }
            return minutes == 1 ? "Every minute" : "Every \(minutes) minutes"
        case .daily(let hour, let minute, let weekdays):
            let time = String(format: "%02d:%02d", hour, minute)
            let days = Set(weekdays)
            if days.isEmpty || days.count == 7 { return "Every day at \(time)" }
            if days == [2, 3, 4, 5, 6] { return "Weekdays at \(time)" }
            if days == [1, 7] { return "Weekends at \(time)" }
            let symbols = Calendar(identifier: .gregorian).shortWeekdaySymbols
            let ordered = [2, 3, 4, 5, 6, 7, 1].filter(days.contains).map { symbols[$0 - 1] }
            return ordered.joined(separator: ", ") + " at \(time)"
        case .once(let date):
            let formatter = DateFormatter()
            formatter.timeZone = timeZone
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return "Once, \(formatter.string(from: date))"
        }
    }

    /// A reason the rule is invalid, or nil.
    public var problem: String? {
        switch self {
        case .interval(let minutes):
            minutes < Self.minimumIntervalMinutes ? "The interval must be at least \(Self.minimumIntervalMinutes) minute." : nil
        case .daily(let hour, let minute, let weekdays):
            if !(0...23).contains(hour) || !(0...59).contains(minute) { "The time must be between 00:00 and 23:59." }
            else if weekdays.contains(where: { !(1...7).contains($0) }) { "Weekdays are 1 (Sunday) to 7 (Saturday)." }
            else { nil }
        case .once: nil
        }
    }
}

/// Where a run goes.
public enum ScheduleDestination: Hashable, Sendable, Codable {
    /// A new thread per run in this project directory.
    case newThread
    /// A message into an existing thread (queued if it is running).
    case thread(SessionID)
}

/// An agent-created task waits for the user's approval (first time in a project) before it can run.
public enum ScheduleApproval: String, Hashable, Sendable, Codable {
    case approved
    case pending
}

public struct ScheduledTask: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var prompt: String
    public var rule: ScheduleRule
    /// IANA identifier; times of day are in this zone (DST-aware).
    public var timeZoneID: String
    /// The project directory the task belongs to (new threads start here).
    public var directory: String
    public var destination: ScheduleDestination
    public var agent: String?
    public var model: ModelSelection?
    public var permissionMode: PermissionMode?
    public var enabled: Bool
    public var approval: ScheduleApproval
    /// Missed while BelloCode was quit (or asleep): run once at launch when overdue. Off: skip to the next time.
    public var catchUp: Bool
    /// The agent thread that created it (nil: the user).
    public var createdBy: SessionID?
    public var created: Date
    public var updated: Date
    /// Interval anchor (creation or last rule edit).
    public var anchor: Date
    public var nextRun: Date?
    public var lastRun: ScheduleRun?

    public init(
        id: String = ScheduledTask.makeID(), name: String, prompt: String, rule: ScheduleRule,
        timeZoneID: String = TimeZone.current.identifier, directory: String, destination: ScheduleDestination = .newThread,
        agent: String? = nil, model: ModelSelection? = nil, permissionMode: PermissionMode? = nil, enabled: Bool = true,
        approval: ScheduleApproval = .approved, catchUp: Bool = true, createdBy: SessionID? = nil, created: Date
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.rule = rule
        self.timeZoneID = timeZoneID
        self.directory = directory
        self.destination = destination
        self.agent = agent
        self.model = model
        self.permissionMode = permissionMode
        self.enabled = enabled
        self.approval = approval
        self.catchUp = catchUp
        self.createdBy = createdBy
        self.created = created
        self.updated = created
        self.anchor = created
    }

    public static func makeID() -> String { "bsch_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased() }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }
    public var isActive: Bool { enabled && approval == .approved }
    public var summary: String { rule.summary(timeZone: timeZone) }
}

/// One run (or a skipped one) of a task. History is bounded (`historyLimit` per task).
public struct ScheduleRun: Hashable, Sendable, Codable, Identifiable {
    public enum Trigger: String, Hashable, Sendable, Codable {
        case scheduled
        /// Overdue at launch or after sleep: the catch-up run.
        case catchUp
        case manual
    }

    public enum Outcome: Hashable, Sendable, Codable {
        /// The prompt was accepted by the server in this thread.
        case started(SessionID)
        case failed(String)
        /// Not run (catch-up off, missed while quit).
        case skipped(String)
    }

    public static let historyLimit = 50

    public var id: String
    public var scheduleID: String
    public var started: Date
    /// The time it was due (equal to `started` for manual runs).
    public var due: Date
    public var trigger: Trigger
    public var outcome: Outcome
    /// Occurrences missed and folded into this run (catch-up never bursts).
    public var missed: Int

    public init(scheduleID: String, started: Date, due: Date, trigger: Trigger, outcome: Outcome, missed: Int = 0) {
        id = "bsrun_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        self.scheduleID = scheduleID
        self.started = started
        self.due = due
        self.trigger = trigger
        self.outcome = outcome
        self.missed = missed
    }

    public var sessionID: SessionID? { if case .started(let id) = outcome { id } else { nil } }

    /// "Started", "Failed: …", "Skipped: …".
    public var label: String {
        switch outcome {
        case .started: trigger == .catchUp ? "Caught up" : "Started"
        case .failed(let message): "Failed: \(message)"
        case .skipped(let reason): "Skipped: \(reason)"
        }
    }

    public var succeeded: Bool { if case .started = outcome { true } else { false } }
}

/// The scheduling arithmetic. Pure, so time zones, DST, weekdays and catch-up are tested with fixed dates.
///
/// DST rule: a time of day that does not exist on a spring-forward day runs at the same minutes after the gap
/// (02:30 → 03:30); a time that occurs twice on a fall-back day runs at the first occurrence only.
public enum ScheduleCalendar {
    /// The first due time strictly after `date`, or nil (a past one-off).
    public static func next(after date: Date, rule: ScheduleRule, timeZone: TimeZone, anchor: Date) -> Date? {
        switch rule {
        case .interval(let minutes):
            let step = Double(max(ScheduleRule.minimumIntervalMinutes, minutes)) * 60
            if date < anchor { return anchor }
            let elapsed = date.timeIntervalSince(anchor)
            let steps = (elapsed / step).rounded(.down) + 1
            return anchor.addingTimeInterval(steps * step)
        case .daily(let hour, let minute, let weekdays):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let days = Set(weekdays.filter { (1...7).contains($0) })
            let targets: [Int?] = days.isEmpty || days.count == 7 ? [nil] : days.sorted().map(Optional.some)
            return targets.compactMap { weekday -> Date? in
                var components = DateComponents(hour: hour, minute: minute, second: 0)
                components.weekday = weekday
                return calendar.nextDate(
                    after: date, matching: components, matchingPolicy: .nextTimePreservingSmallerComponents,
                    repeatedTimePolicy: .first, direction: .forward)
            }.min()
        case .once(let at):
            return at > date ? at : nil
        }
    }

    /// Occurrences in `(after, through]`, counted up to `cap` (for "missed N" in catch-up records).
    public static func occurrences(after: Date, through: Date, rule: ScheduleRule, timeZone: TimeZone, anchor: Date, cap: Int = 1_000) -> Int {
        var count = 0
        var cursor = after
        while count < cap, let next = next(after: cursor, rule: rule, timeZone: timeZone, anchor: anchor), next <= through {
            count += 1
            cursor = next
        }
        return count
    }

    /// What to do with a task whose `nextRun` is at or before `now`.
    public enum Decision: Equatable, Sendable {
        /// Run now. `missed` is how many earlier occurrences are folded into this one (0 when on time).
        case run(trigger: ScheduleRun.Trigger, missed: Int)
        /// Record a skipped run (catch-up off) and move on.
        case skip(missed: Int)
    }

    /// How late a run may start and still count as on time (timer slack, a short sleep).
    public static let onTimeGrace: TimeInterval = 120

    /// The catch-up policy: on time → run; overdue (missed while quit or asleep) → run once if the task allows
    /// catch-up, else skip. Never more than one run, however many occurrences were missed.
    public static func decide(_ task: ScheduledTask, now: Date) -> Decision? {
        guard task.isActive, let due = task.nextRun, due <= now else { return nil }
        let missed = occurrences(after: due, through: now, rule: task.rule, timeZone: task.timeZone, anchor: task.anchor)
        if now.timeIntervalSince(due) <= onTimeGrace && missed == 0 { return .run(trigger: .scheduled, missed: 0) }
        return task.catchUp ? .run(trigger: .catchUp, missed: missed) : .skip(missed: missed + 1)
    }
}

/// A refusal or failure of an extras command, already phrased for the person (and the agent).
public struct ExtrasError: Error, Sendable, Hashable, CustomStringConvertible, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }

    /// The message of any error, preferring ours.
    public static func message(_ error: any Error) -> String {
        if let error = error as? ExtrasError { return error.message }
        return EngineError.from(error).userMessage
    }
}
