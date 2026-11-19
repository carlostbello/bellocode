import Foundation

/// Admission for calls into the shared browser (docs/features/shared-browser.md "Multi-agent model"):
/// - calls to the same tab run one at a time, in arrival order (browse itself only reserves a top-level string tab and
///   two calls can still interleave a snapshot and the click that uses it);
/// - a deliberately shared tab has one **driver** at a time: the first thread to call holds the lease while it keeps
///   calling (renewed per call) until it yields, the person revokes it, or it has been idle for `leaseIdle`;
/// - **Take Over** gives a tab (or every tab) to the person: waiting calls fail with Busy and new ones are refused
///   until Give Back;
/// - at most `maxActive` calls run and `maxQueued` wait across all threads, at most `maxQueuedPerThread` per thread
///   (bounded, rule 5); overflow is refused with Busy at once, never silently queued;
/// - a browser restart (new generation) fails everything waiting or running with "outcome unknown".
///
/// Pure bookkeeping in an actor; waiting uses continuations that are always resumed (grant, Busy, or cancellation).
public actor BrowserTabGate {
    public struct Limits: Sendable, Equatable {
        public var maxActive = 4
        public var maxQueued = 16
        public var maxQueuedPerThread = 4
        public var leaseIdle: Duration = .seconds(60)
        public init() {}
    }

    public enum Busy: Error, Sendable, Equatable, CustomStringConvertible {
        /// Another thread drives this shared tab.
        case driven(by: String, tab: String)
        /// The person has taken over this tab (or the whole browser).
        case humanControl(tab: String)
        /// Too many calls are running and waiting.
        case overloaded
        /// This thread already has too many calls waiting.
        case threadQueueFull
        /// The browser restarted while the call waited or ran; whether it took effect is unknown.
        case restarted
        case cancelled

        public var description: String {
            switch self {
            case .driven(let by, let tab):
                "Busy: the shared tab \(tab) is being driven by the thread “\(by)”. Wait for it to finish (try again shortly) or work in your own tab."
            case .humanControl(let tab):
                "Busy: the person has taken over \(tab == "*" ? "the shared Chrome" : "the tab \(tab)") and is using it now. Do not retry until they give it back; continue with other work or end your turn."
            case .overloaded:
                "Busy: the shared Chrome is handling the maximum number of calls from all threads. Try again in a few seconds."
            case .threadQueueFull:
                "Busy: you already have several browser calls waiting. Wait for them to finish before starting more."
            case .restarted:
                "The shared Chrome restarted while this call was in progress; whether it took effect is unknown. Check the page state (snapshot) before repeating anything that changes data."
            case .cancelled: "The call was cancelled."
            }
        }
    }

    public struct Ticket: Sendable, Equatable, Hashable {
        public let id: Int
        public let tab: String
        public let session: String
        public let generation: Int
    }

    /// What the live view shows per tab.
    public struct TabActivity: Sendable, Equatable {
        public var running: String?
        public var driver: String?
        public var human: Bool
        public var queued: Int
        public var lastUsedBy: String?

        public init(running: String? = nil, driver: String? = nil, human: Bool = false, queued: Int = 0, lastUsedBy: String? = nil) {
            self.running = running
            self.driver = driver
            self.human = human
            self.queued = queued
            self.lastUsedBy = lastUsedBy
        }
    }

    private struct Waiter {
        var id: Int
        var tab: String
        var session: String
        var continuation: CheckedContinuation<Ticket, any Error>
    }

    private struct Lease {
        var session: String
        var renewed: ContinuousClock.Instant
    }

    public let limits: Limits
    private let now: @Sendable () -> ContinuousClock.Instant
    private var generation = 0
    private var nextID = 0
    private var running: [String: Ticket] = [:]          // tab → running ticket
    private var waiters: [Waiter] = []                    // arrival order
    private var leases: [String: Lease] = [:]             // shared tab → driver
    private var humanTabs: Set<String> = []               // "*" = every tab
    private var lastUsed: [String: String] = [:]
    private var names: [String: String] = [:]             // session → thread title (display only)
    private var lastGranted: String?
    private var idleWaiters: [(id: Int, tab: String, continuation: CheckedContinuation<Void, Never>)] = []

    public init(limits: Limits = .init(), now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.limits = limits
        self.now = now
    }

    public func setName(_ name: String, for session: String) { names[session] = name }
    private func name(_ session: String) -> String { names[session] ?? session }

    /// Waits for the tab, or throws `Busy`. `shared` marks a tab more than one thread may use (lease applies).
    public func acquire(tab: String, session: String, shared: Bool) async throws -> Ticket {
        if humanTabs.contains("*") { throw Busy.humanControl(tab: "*") }
        if humanTabs.contains(tab) { throw Busy.humanControl(tab: tab) }
        if shared {
            if let lease = leases[tab], lease.session != session, now() - lease.renewed < limits.leaseIdle {
                throw Busy.driven(by: name(lease.session), tab: tab)
            }
            leases[tab] = Lease(session: session, renewed: now())
        }
        nextID += 1
        let id = nextID
        if running[tab] == nil, running.count < limits.maxActive, !waiters.contains(where: { $0.tab == tab }) {
            let ticket = Ticket(id: id, tab: tab, session: session, generation: generation)
            running[tab] = ticket
            lastUsed[tab] = session
            lastGranted = session
            return ticket
        }
        guard waiters.count < limits.maxQueued else { throw Busy.overloaded }
        guard waiters.filter({ $0.session == session }).count < limits.maxQueuedPerThread else { throw Busy.threadQueueFull }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, tab: tab, session: session, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: Busy.cancelled)
    }

    /// Ends a call; the next waiter (first in arrival order whose tab is free, fair across threads) runs.
    public func release(_ ticket: Ticket) {
        if running[ticket.tab] == ticket { running[ticket.tab] = nil }
        if let lease = leases[ticket.tab], lease.session == ticket.session { leases[ticket.tab]?.renewed = now() }
        admit()
        resumeIdleWaiters()
    }

    /// Whether no call is running on `tab` ("*": on any tab).
    public func isIdle(_ tab: String) -> Bool {
        tab == "*" ? running.isEmpty : running[tab] == nil
    }

    /// Returns once no call runs on `tab` ("*": any tab), or when the caller is cancelled. Take Over uses it to hand
    /// control over only after already-dispatched agent calls have settled (R22).
    public func waitUntilIdle(_ tab: String) async {
        if isIdle(tab) { return }
        nextID += 1
        let id = nextID
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isIdle(tab) || Task.isCancelled { continuation.resume() } else { idleWaiters.append((id, tab, continuation)) }
            }
        } onCancel: {
            Task { await self.cancelIdleWaiter(id) }
        }
    }

    private func cancelIdleWaiter(_ id: Int) {
        guard let index = idleWaiters.firstIndex(where: { $0.id == id }) else { return }
        idleWaiters.remove(at: index).continuation.resume()
    }

    private func resumeIdleWaiters() {
        let ready = idleWaiters.filter { isIdle($0.tab) }
        idleWaiters.removeAll { waiter in ready.contains { $0.id == waiter.id } }
        for waiter in ready { waiter.continuation.resume() }
    }

    /// Grants free tabs to waiters, round-robin across threads: the next grant goes to the first waiting call of a
    /// thread other than the one served last, so one thread's burst cannot starve another's.
    private func admit() {
        while running.count < limits.maxActive {
            let eligible = waiters.indices.filter { running[waiters[$0].tab] == nil }
            guard let first = eligible.first else { return }
            let index = eligible.first { waiters[$0].session != lastGranted } ?? first
            let waiter = waiters.remove(at: index)
            let ticket = Ticket(id: waiter.id, tab: waiter.tab, session: waiter.session, generation: generation)
            running[waiter.tab] = ticket
            lastUsed[waiter.tab] = waiter.session
            lastGranted = waiter.session
            waiter.continuation.resume(returning: ticket)
        }
    }

    /// The person takes over `tab` ("*" = every tab): waiting calls on it fail with Busy; new calls are refused. The
    /// running call (if any) is left to the caller to cancel (then `waitUntilIdle`); returns the sessions affected.
    @discardableResult
    public func takeOver(_ tab: String) -> Set<String> {
        humanTabs.insert(tab)
        var affected: Set<String> = []
        waiters.removeAll { waiter in
            guard tab == "*" || waiter.tab == tab else { return false }
            affected.insert(waiter.session)
            waiter.continuation.resume(throwing: Busy.humanControl(tab: tab))
            return true
        }
        for (key, ticket) in running where tab == "*" || key == tab { affected.insert(ticket.session) }
        return affected
    }

    public func giveBack(_ tab: String) {
        humanTabs.remove(tab)
        if tab == "*" { humanTabs.removeAll() }
        // A new lease starts with the next call; the old driver's snapshot refs are stale.
        if tab == "*" { leases.removeAll() } else { leases[tab] = nil }
        admit()
    }

    public func isHumanControlled(_ tab: String) -> Bool { humanTabs.contains("*") || humanTabs.contains(tab) }

    /// A driver gives the lease back (or the person revokes it).
    public func yield(tab: String, session: String? = nil) {
        if let session, leases[tab]?.session != session { return }
        leases[tab] = nil
    }

    public func driver(of tab: String) -> String? {
        guard let lease = leases[tab], now() - lease.renewed < limits.leaseIdle else { return nil }
        return lease.session
    }

    /// The browser restarted: every waiting call fails, running tickets become stale (their results are dropped).
    public func newGeneration() -> Int {
        generation += 1
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.continuation.resume(throwing: Busy.restarted) }
        running = [:]
        leases = [:]
        resumeIdleWaiters()
        return generation
    }

    public func isCurrent(_ ticket: Ticket) -> Bool { ticket.generation == generation }

    public var currentGeneration: Int { generation }

    public func activity() -> [String: TabActivity] {
        var out: [String: TabActivity] = [:]
        let tabs = Set(running.keys).union(waiters.map(\.tab)).union(leases.keys).union(lastUsed.keys).union(humanTabs)
        for tab in tabs {
            out[tab] = TabActivity(running: running[tab].map { name($0.session) }, driver: driver(of: tab).map(name),
                                   human: isHumanControlled(tab), queued: waiters.filter { $0.tab == tab }.count,
                                   lastUsedBy: lastUsed[tab].map(name))
        }
        return out
    }

    public var counts: (running: Int, queued: Int) { (running.count, waiters.count) }
}
