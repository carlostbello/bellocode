import AppKit
import BelloCore
import Engine
import Observation
import os

/// A window that shows threads and takes part in deferred deletes (its `WorkspaceController`).
@MainActor
protocol PendingDeletionListener: AnyObject {
    var undo: UndoCoordinator { get }
    /// Threads were hidden (deleted, Undo still possible): leave them if shown.
    func pendingDeletionHid(_ ids: [SessionID])
    /// A pending delete was undone: show the threads again (and go back to one this window left).
    func pendingDeletionRestored(_ ids: [SessionID])
    /// The delete is being sent: drop any open model of these threads.
    func pendingDeletionCommitted(_ ids: [SessionID])
}

/// Deferred thread deletes for the whole app (review M5): one pending operation per delete, shared by every window of
/// one Engine, not per-window state.
///
/// - Every window hides the rows at once (`hidden`, observed) and leaves a thread it was showing, so no window can
///   keep editing or sending to it while the delete is pending.
/// - Every window gets an Undo entry (toast and ⌘Z); Undo from any of them restores the threads everywhere and retires
///   the others' entries.
/// - After the Undo window (5 s) the delete is sent, exactly once per thread (`Entry.phase`); from then on it cannot be
///   undone. Closing the last window or quitting sends every pending delete deliberately, and quit awaits the results
///   (`drain`) before the engine stops. A failure shows the thread again and is reported in the window that deleted
///   it, else in any window, else by the quit alert (`drain` returns the failures).
///
/// Threading: `@MainActor`. Its tasks (timers, sends) are owned here and cancelled or awaited here.
@MainActor
@Observable
final class PendingThreadDeletions {
    typealias Send = @MainActor (SessionID) async throws -> Void
    typealias Wait = @Sendable (Duration) async throws -> Void

    enum Phase { case pending, sending, finished }

    @MainActor
    final class Entry {
        let ids: [SessionID]
        let name: String
        let message: String
        fileprivate(set) var phase: Phase = .pending
        fileprivate var timer: Task<Void, Never>?
        /// Undo entries per window (by listener identity). Weak: each window's undo coordinator keeps its token (and
        /// through the token's closures, this entry) alive while it can still be undone or redone.
        fileprivate var tokens: [ObjectIdentifier: WeakToken] = [:]
        fileprivate weak var origin: (any PendingDeletionListener)?
        init(ids: [SessionID], name: String, message: String) {
            self.ids = ids
            self.name = name
            self.message = message
        }
    }

    struct WeakListener {
        weak var value: (any PendingDeletionListener)?
    }

    struct WeakToken {
        weak var listener: (any PendingDeletionListener)?
        weak var token: UndoToken?
    }

    /// Threads deleted and not yet confirmed gone (pending or being sent): hidden in every window.
    private(set) var hidden: Set<SessionID> = []
    @ObservationIgnored private var byThread: [SessionID: Entry] = [:]
    @ObservationIgnored private var listeners: [WeakListener] = []
    @ObservationIgnored private var sending: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Threads whose delete failed while no window could show it (reported by `drain`).
    @ObservationIgnored private var unreported: [SessionID] = []
    /// Delete requests sent to the server (for tests: never more than one per thread).
    @ObservationIgnored private(set) var sentCount = 0
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private let wait: Wait
    @ObservationIgnored private let send: Send
    private static let log = Logger(subsystem: "dev.bellocode.app", category: "deletions")

    init(delay: Duration = .seconds(ToastQueue.duration), wait: @escaping Wait = { try await Task.sleep(for: $0) }, send: @escaping Send) {
        self.delay = delay
        self.wait = wait
        self.send = send
    }

    // MARK: Shared instance per engine

    private struct Shared {
        weak var engine: Engine?
        let deletions: PendingThreadDeletions
    }

    private static var shared: [ObjectIdentifier: Shared] = [:]

    /// The app-level instance for `engine` (every window of one engine shares it).
    static func shared(for engine: Engine) -> PendingThreadDeletions {
        shared = shared.filter { $0.value.engine != nil }
        if let existing = shared[ObjectIdentifier(engine)] { return existing.deletions }
        let deletions = PendingThreadDeletions { [weak engine] id in
            guard let engine else { throw CancellationError() }
            try await engine.deleteThread(id)
        }
        shared[ObjectIdentifier(engine)] = Shared(engine: engine, deletions: deletions)
        return deletions
    }

    // MARK: Windows

    func register(_ listener: any PendingDeletionListener) {
        listeners.removeAll { $0.value == nil || $0.value === listener }
        listeners.append(WeakListener(value: listener))
    }

    /// A window closed. When it was the last one, every pending delete is sent now (its Undo went with the windows).
    func unregister(_ listener: any PendingDeletionListener) {
        listeners.removeAll { $0.value == nil || $0.value === listener }
        if listeners.isEmpty { commitAll() }
    }

    private var live: [any PendingDeletionListener] { listeners.compactMap(\.value) }

    func isPending(_ id: SessionID) -> Bool { byThread[id]?.phase == .pending }

    // MARK: Delete, Undo, Redo

    /// Hides `ids` everywhere and schedules their delete. Returns nil when every thread is already being deleted.
    @discardableResult
    func delete(_ ids: [SessionID], name: String, message: String, from origin: (any PendingDeletionListener)?) -> Entry? {
        let ids = ids.filter { !hidden.contains($0) }
        guard !ids.isEmpty else { return nil }
        let entry = Entry(ids: ids, name: name, message: message)
        entry.origin = origin
        hide(entry)
        // The origin first, so its toast is the one it just caused.
        let ordered = live.sorted { a, _ in a === origin }
        for listener in ordered { offerUndo(entry, in: listener) }
        return entry
    }

    private func hide(_ entry: Entry) {
        entry.phase = .pending
        hidden.formUnion(entry.ids)
        for id in entry.ids { byThread[id] = entry }
        for listener in live { listener.pendingDeletionHid(entry.ids) }
        entry.timer?.cancel()
        let wait = self.wait
        let delay = self.delay
        entry.timer = Task { @MainActor [weak self, weak entry] in
            do { try await wait(delay) } catch { return }
            guard !Task.isCancelled, let self, let entry else { return }
            self.commit(entry)
        }
    }

    private func offerUndo(_ entry: Entry, in listener: any PendingDeletionListener) {
        let key = ObjectIdentifier(listener)
        var applied = false
        let token = listener.undo.perform(
            ReversibleAction(
                name: entry.name, message: entry.message,
                apply: { [weak self] in
                    guard applied else {
                        applied = true
                        return
                    }
                    self?.redo(entry, by: key)
                },
                revert: { [weak self] in
                    self?.restore(entry, by: key)
                }))
        entry.tokens[key] = WeakToken(listener: listener, token: token)
    }

    /// Undo: brings the threads back in every window, if the delete has not been sent.
    func restore(_ entry: Entry, by key: ObjectIdentifier? = nil) {
        guard entry.phase == .pending else { return }
        entry.timer?.cancel()
        entry.timer = nil
        entry.phase = .finished
        retireTokens(of: entry, except: key)
        hidden.subtract(entry.ids)
        for id in entry.ids where byThread[id] === entry { byThread[id] = nil }
        for listener in live { listener.pendingDeletionRestored(entry.ids) }
    }

    /// Cancels the pending delete of one thread (Reopen Closed Thread); false when it is not pending.
    @discardableResult
    func restore(thread id: SessionID) -> Bool {
        guard let entry = byThread[id], entry.phase == .pending else { return false }
        restore(entry)
        return true
    }

    /// Redo of an undone delete (from the window whose ⌘Z history holds it).
    private func redo(_ entry: Entry, by key: ObjectIdentifier) {
        guard entry.phase == .finished, entry.ids.allSatisfy({ !hidden.contains($0) && byThread[$0] == nil }) else { return }
        hide(entry)
    }

    // MARK: Sending

    /// Sends a pending delete now; it can no longer be undone.
    func commit(_ entry: Entry) {
        guard entry.phase == .pending else { return }
        entry.phase = .sending
        entry.timer?.cancel()
        entry.timer = nil
        retireTokens(of: entry, except: nil)
        for listener in live { listener.pendingDeletionCommitted(entry.ids) }
        let key = ObjectIdentifier(entry)
        sending[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            var failures: [(SessionID, any Error)] = []
            for id in entry.ids {
                self.sentCount += 1
                do { try await self.send(id) } catch { failures.append((id, error)) }
            }
            self.finish(entry, failures: failures)
            self.sending[key] = nil
        }
    }

    func commitAll() {
        var seen: Set<ObjectIdentifier> = []
        for entry in byThread.values where entry.phase == .pending && seen.insert(ObjectIdentifier(entry)).inserted { commit(entry) }
    }

    /// Sends every pending delete and waits for all sends to finish (quit). Returns the threads whose delete failed and
    /// that no window reported; they still exist on the server.
    func drain() async -> [SessionID] {
        commitAll()
        while let task = sending.values.first {
            await task.value
        }
        defer { unreported.removeAll() }
        return unreported
    }

    private func finish(_ entry: Entry, failures: [(SessionID, any Error)]) {
        entry.phase = .finished
        hidden.subtract(entry.ids)
        for id in entry.ids where byThread[id] === entry { byThread[id] = nil }
        guard let (_, error) = failures.first else { return }
        Self.log.error("deferred delete failed for \(failures.count, privacy: .public) thread(s)")
        // The engine restored the rows; they show again. Say why where someone can see it.
        let message = (error as? EngineError)?.userMessage ?? "The thread could not be deleted."
        let origin = entry.origin.flatMap { origin in live.contains { $0 === origin } ? origin : nil }
        if let reporter = origin ?? live.first {
            reporter.undo.showNotice(message)
        } else {
            unreported.append(contentsOf: failures.map(\.0))
        }
    }

    private func retireTokens(of entry: Entry, except key: ObjectIdentifier?) {
        for (listenerKey, pair) in entry.tokens where listenerKey != key {
            if let token = pair.token { pair.listener?.undo.retire(token) }
        }
        entry.tokens = entry.tokens.filter { $0.key == key }
    }
}
