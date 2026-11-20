import BelloCore
import Foundation
import Observation
import os

/// What a scheduled run does, injected so the scheduler is tested without a server.
@MainActor
public protocol ScheduleRunner: AnyObject {
    /// Creates a thread in `directory` and sends `prompt`; returns once the server accepted the prompt.
    func startThread(
        directory: String, title: String, prompt: String, agent: String?, model: ModelSelection?, permissionMode: PermissionMode?
    ) async throws -> SessionID
    /// Sends `prompt` into an existing thread (queued while it runs).
    func send(_ prompt: String, to thread: SessionID) async throws
    /// The thread exists (not deleted).
    func threadExists(_ id: SessionID) -> Bool
}

/// BelloCode's scheduler (docs/features/orchestration-extras.md): task definitions and bounded run history in the app
/// store (`app_schedule`, `app_schedule_run`), timing from `ScheduleCalendar`, runs through a `ScheduleRunner`.
///
/// Runs happen while BelloCode is running, with or without a window. While it is quit nothing runs; at the next launch
/// (and after the Mac wakes) each overdue task runs once if its catch-up is on, else a skipped run is recorded: never a
/// burst of missed runs.
///
/// Threading: `@MainActor` (presentation state); store I/O is awaited on the store actor. The timer loop sleeps on the
/// injected `WallClock` until the earliest due time and is owned (and cancelled) by this service.
@MainActor
@Observable
public final class SchedulerService {
    /// Every task, by name. Changes on any edit or run.
    public private(set) var tasks: [ScheduledTask] = []
    /// Projects where agents may create tasks without asking (`app_grant`).
    public private(set) var grantedProjects: Set<String> = []
    /// Tasks whose run is in flight (shown as "Running…"; a second run waits).
    public private(set) var running: Set<String> = []
    public private(set) var lastError: String?
    /// Due runs may be dispatched. The engine arms this after its first successful reconcile with opencode and disarms
    /// it while disconnected, so a launch catch-up never runs into a server that is not ready yet.
    public private(set) var isDispatchArmed = true
    /// Tasks whose due run could not reach opencode (offline): the occurrence is kept and retried, not recorded.
    public private(set) var deferred: Set<String> = []
    /// How long a deferred task waits before it is tried again while still armed.
    @ObservationIgnored public var deferralRetry: TimeInterval = 30
    @ObservationIgnored private var deferredUntil: [String: Date] = [:]

    @ObservationIgnored public let clock: any WallClock
    @ObservationIgnored private let store: ProjectionStore
    @ObservationIgnored public weak var runner: (any ScheduleRunner)?
    /// Called when a task was found changed after its approval (it is now pending): the hub raises a card.
    @ObservationIgnored public var needsApproval: (@MainActor (ScheduledTask) async -> Void)?
    /// The model of a new-thread run whose task names none (Settings ▸ Models ▸ Delegated threads and scheduled tasks;
    /// nil: opencode's default, or the agent's own model).
    @ObservationIgnored public var defaultModel: (@MainActor (ScheduledTask) async -> ModelSelection?)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private let log = Logger(subsystem: "app.bellocode", category: "scheduler")

    public init(store: ProjectionStore, clock: any WallClock = SystemWallClock()) {
        self.store = store
        self.clock = clock
    }

    // MARK: Lifecycle

    /// Loads the tasks, applies the catch-up policy once (when `armed`), then keeps the timer running. With
    /// `armed: false` the definitions are shown at once and nothing runs until `setDispatchArmed(true)`.
    public func start(armed: Bool = true) async {
        guard !started else { return }
        started = true
        isDispatchArmed = armed
        do {
            tasks = try await store.schedules().sorted(by: Self.order)
            grantedProjects = try await store.grants(.schedule)
            // Tasks saved before approvals were bound to a definition: the user's own keep theirs; an agent's approved
            // task cannot prove what was approved, so it asks again (ExtrasHub raises the card).
            for var task in tasks where task.approved == nil && task.approval == .approved {
                if task.createdBy == nil { task.approved = task.definition } else { task.approval = .pending }
                try? await persist(task)
            }
        } catch {
            lastError = "Scheduled tasks could not be read: \(error.localizedDescription)"
        }
        await tick()
        restartLoop()
    }

    /// Arms or disarms dispatch. Arming retries deferred runs at once (their original occurrence) and applies catch-up.
    public func setDispatchArmed(_ armed: Bool) async {
        guard armed != isDispatchArmed else { return }
        isDispatchArmed = armed
        guard armed, started else { return }
        deferredUntil.removeAll()
        await tick()
        restartLoop()
    }

    public func shutdown() {
        loop?.cancel()
        loop = nil
        started = false
    }

    private func restartLoop() {
        loop?.cancel()
        guard started else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let due = self.tasks.filter(\.isActive).compactMap { task in
                    task.nextRun.map { max($0, self.deferredUntil[task.id] ?? .distantPast) }
                }.min()
                let wake = min(due ?? .distantFuture, self.clock.now().addingTimeInterval(3_600))
                do { try await self.clock.sleep(until: wake) } catch { return }
                await self.tick()
            }
        }
    }

    /// Runs whatever is due now (the timer, a wake from sleep, launch). Each task runs at most once per tick.
    public func tick() async {
        guard isDispatchArmed else { return }
        let now = clock.now()
        for task in tasks where !running.contains(task.id) {
            if let until = deferredUntil[task.id], until > now { continue }
            guard let decision = ScheduleCalendar.decide(task, now: now), let due = task.nextRun else { continue }
            switch decision {
            case .run(let trigger, let missed):
                await execute(task.id, trigger: trigger, due: due, missed: missed)
            case .skip(let missed):
                let run = ScheduleRun(
                    scheduleID: task.id, started: now, due: due, trigger: .catchUp,
                    outcome: .skipped(missed == 1 ? "missed while BelloCode was not running" : "\(missed) runs missed while BelloCode was not running"),
                    missed: missed)
                await finish(task.id, run: run, advanceFrom: now)
            }
        }
    }

    // MARK: Reads

    public func task(_ id: String) -> ScheduledTask? { tasks.first { $0.id == id } }

    public func tasks(inProject directory: String) -> [ScheduledTask] { tasks.filter { $0.directory == directory } }

    /// The next active run across every task.
    public var nextRun: (task: ScheduledTask, date: Date)? {
        tasks.filter(\.isActive).compactMap { task in task.nextRun.map { (task, $0) } }.min { $0.1 < $1.1 }
    }

    /// Newest first, bounded.
    public func runs(_ id: String) async -> [ScheduleRun] { (try? await store.scheduleRuns(id)) ?? [] }

    // MARK: Commands

    /// Adds a task (validated). Its first run is computed from now.
    @discardableResult
    public func create(_ draft: ScheduledTask) async throws -> ScheduledTask {
        if let problem = draft.rule.problem { throw ExtrasError(problem) }
        guard !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ExtrasError("The prompt is empty.") }
        var task = draft
        // The user's own tasks and tasks created under a project grant are approved as they are now.
        task.approved = task.approval == .approved ? task.definition : nil
        let now = clock.now()
        task.created = now
        task.updated = now
        task.anchor = now
        task.nextRun = ScheduleCalendar.next(after: now, rule: task.rule, timeZone: task.timeZone, anchor: now)
        if case .once = task.rule, task.nextRun == nil { throw ExtrasError("That time has already passed.") }
        try await persist(task)
        restartLoop()
        return task
    }

    /// Replaces a task's definition. A changed rule or time zone re-anchors and recomputes the next run.
    ///
    /// `consent`: the user made the change (Settings), so an approved task stays approved with its new definition. An
    /// agent's change (`consent: false`) that alters the definition, or turns the task back on, puts it back to
    /// pending: it does not run until the user approves the new definition. Returns true when it now waits.
    @discardableResult
    public func update(_ edited: ScheduledTask, consent: Bool = true) async throws -> Bool {
        guard let old = task(edited.id) else { throw ExtrasError("No scheduled task \(edited.id).") }
        if let problem = edited.rule.problem { throw ExtrasError(problem) }
        var task = edited
        task.approved = old.approved
        task.approval = old.approval
        if consent {
            if task.approval == .approved { task.approved = task.definition }
        } else if task.definition != old.approved || (task.enabled && !old.enabled) {
            task.approval = .pending
        }
        let now = clock.now()
        task.updated = now
        if task.rule != old.rule || task.timeZoneID != old.timeZoneID || (task.enabled && !old.enabled) {
            task.anchor = now
            task.nextRun = ScheduleCalendar.next(after: now, rule: task.rule, timeZone: task.timeZone, anchor: now)
        }
        try await persist(task)
        restartLoop()
        return task.approval == .pending
    }

    public func setEnabled(_ id: String, _ enabled: Bool) async throws {
        guard var task = task(id) else { return }
        task.enabled = enabled
        try await update(task)
    }

    /// Deletes a task (its run history too). Returns it so the caller can offer Undo (`restore`).
    @discardableResult
    public func delete(_ id: String) async throws -> ScheduledTask? {
        guard let task = task(id) else { return nil }
        try await store.deleteSchedule(id)
        tasks.removeAll { $0.id == id }
        restartLoop()
        return task
    }

    /// Undo of `delete`: the same task, next run recomputed from now (run history is not restored).
    public func restore(_ task: ScheduledTask) async throws {
        var restored = task
        let now = clock.now()
        if let next = restored.nextRun, next <= now {
            restored.nextRun = ScheduleCalendar.next(after: now, rule: restored.rule, timeZone: restored.timeZone, anchor: restored.anchor)
        }
        try await persist(restored)
        restartLoop()
    }

    /// Runs a task now ("Run Now"); its schedule is unchanged.
    public func runNow(_ id: String) async throws {
        guard let task = task(id) else { throw ExtrasError("No scheduled task \(id).") }
        guard task.isApprovedAsDefined else { throw ExtrasError("This task waits for your approval.") }
        guard !running.contains(id) else { throw ExtrasError("It is already running.") }
        let now = clock.now()
        await execute(id, trigger: .manual, due: now, missed: 0)
    }

    /// Approves an agent-created task as the card showed it (and, with `always`, lets agents create tasks in its
    /// project without asking; edits still ask). `digest` is the definition the card showed: if the task changed since,
    /// nothing is approved.
    public func approve(_ id: String, digest: String?, always: Bool) async throws {
        guard var task = task(id) else { throw ExtrasError("That scheduled task no longer exists.") }
        guard let digest, digest == task.definition.digest else {
            throw ExtrasError("“\(task.name)” changed after this card was shown; nothing was approved. The current version has its own card.")
        }
        task.approval = .approved
        task.approved = task.definition
        if always { try await setProjectGrant(task.directory, true) }
        try await persist(task)
        restartLoop()
    }

    /// Declining an agent's change: back to the definition the user approved (approved again), or nil when there was
    /// never one (the caller deletes the task).
    @discardableResult
    public func revertToApproved(_ id: String) async throws -> ScheduledTask? {
        guard var task = task(id), let approved = task.approved else { return nil }
        let ruleChanged = approved.rule != task.rule || approved.timeZoneID != task.timeZoneID
        task.definition = approved
        task.approval = .approved
        if ruleChanged {
            let now = clock.now()
            task.anchor = now
            task.nextRun = ScheduleCalendar.next(after: now, rule: task.rule, timeZone: task.timeZone, anchor: now)
        }
        try await persist(task)
        restartLoop()
        return task
    }

    public func setProjectGrant(_ directory: String, _ granted: Bool) async throws {
        try await store.setGrant(.schedule, scope: directory, granted: granted)
        if granted { grantedProjects.insert(directory) } else { grantedProjects.remove(directory) }
    }

    // MARK: Running

    private func execute(_ id: String, trigger: ScheduleRun.Trigger, due: Date, missed: Int) async {
        guard var task = task(id) else { return }
        // The definition must be exactly the approved one (whatever path changed it).
        guard task.isApprovedAsDefined else {
            task.approval = .pending
            try? await persist(task)
            let run = ScheduleRun(
                scheduleID: id, started: clock.now(), due: due, trigger: trigger,
                outcome: .failed("it changed after it was approved; it waits for approval"), missed: missed)
            try? await store.recordScheduleRun(run)
            restartLoop()
            await needsApproval?(task)
            return
        }
        running.insert(id)
        defer { running.remove(id) }
        let started = clock.now()
        let outcome: ScheduleRun.Outcome
        var unreachable = runner == nil
        if let runner {
            let prompt = "[Scheduled task “\(task.name)”]\n" + task.prompt
            do {
                switch task.destination {
                case .newThread:
                    let title = "\(task.name) · \(Self.runTitle(started, timeZone: task.timeZone))"
                    var model = task.model
                    if model == nil, let defaultModel { model = await defaultModel(task) }
                    let id = try await runner.startThread(
                        directory: task.directory, title: title, prompt: prompt, agent: task.agent, model: model,
                        permissionMode: task.permissionMode)
                    outcome = .started(id)
                case .thread(let thread):
                    if runner.threadExists(thread) {
                        try await runner.send(prompt, to: thread)
                        outcome = .started(thread)
                    } else {
                        outcome = .failed("its thread no longer exists")
                    }
                }
            } catch {
                unreachable = Self.isDeferrable(error)
                outcome = .failed(ExtrasError.message(error))
            }
        } else {
            outcome = .failed("BelloCode is not connected")
        }
        // Nothing reached opencode: keep this occurrence (nextRun, enabled one-off) and try again later instead of
        // recording a failure that advances or disables the task. A manual run reports the failure as before.
        if unreachable, trigger != .manual {
            log.info("scheduled run \(task.id, privacy: .public) deferred: opencode unreachable")
            deferred.insert(id)
            deferredUntil[id] = clock.now().addingTimeInterval(deferralRetry)
            restartLoop()
            return
        }
        deferred.remove(id)
        deferredUntil[id] = nil
        log.info("scheduled run \(task.id, privacy: .public): \(trigger.rawValue, privacy: .public)")
        let run = ScheduleRun(scheduleID: task.id, started: started, due: due, trigger: trigger, outcome: outcome, missed: missed)
        await finish(task.id, run: run, advanceFrom: trigger == .manual ? nil : clock.now())
    }

    /// Records a run and moves the task to its next time (a past one-off is disabled; a thread that no longer exists
    /// disables the task, so it does not fail forever).
    private func finish(_ id: String, run: ScheduleRun, advanceFrom now: Date?) async {
        try? await store.recordScheduleRun(run)
        guard var task = task(id) else { return }
        task.lastRun = run
        if let now {
            task.nextRun = ScheduleCalendar.next(after: now, rule: task.rule, timeZone: task.timeZone, anchor: task.anchor)
            if task.nextRun == nil { task.enabled = false }
        }
        if case .failed(let reason) = run.outcome, reason == "its thread no longer exists" { task.enabled = false }
        try? await persist(task)
        restartLoop()
    }

    /// opencode was not reached (no endpoint, connection refused, 503): retrying cannot run the prompt twice. A timeout or
    /// an unknown delivery may have reached it, and a rejection is permanent, so those are recorded as failures.
    static func isDeferrable(_ error: any Error) -> Bool {
        switch EngineError.from(error) {
        case .offline, .cancelled: true
        default: false
        }
    }

    private func persist(_ task: ScheduledTask) async throws {
        do {
            try await store.saveSchedule(task)
            lastError = nil
        } catch {
            lastError = "Scheduled tasks are not being saved: \(error.localizedDescription)"
            throw ExtrasError(lastError ?? "")
        }
        if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task } else { tasks.append(task) }
        tasks.sort(by: Self.order)
    }

    private static func order(_ lhs: ScheduledTask, _ rhs: ScheduledTask) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending || (lhs.name == rhs.name && lhs.id < rhs.id)
    }

    static func runTitle(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM HH:mm"
        return formatter.string(from: date)
    }
}
