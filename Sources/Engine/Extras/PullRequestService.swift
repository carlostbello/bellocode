import BelloCore
import Foundation
import Observation
import OpenCodeKit
import os

/// What the PR service needs from the rest of the engine, injected so its rules are tested without a server.
@MainActor
public protocol PullRequestHost: AnyObject {
    /// Every known session (for links in metadata).
    func allSessions() async -> [Session]
    /// Replaces the thread's linked PRs in its metadata (read-modify-write on the server; other keys kept).
    func writeLinks(_ sessionID: SessionID, _ transform: @escaping @Sendable ([LinkedPullRequest]) -> [LinkedPullRequest]) async throws -> [LinkedPullRequest]
    /// Posts the labelled wake message (opencode `synthetic`, which starts a run).
    func wake(_ sessionID: SessionID, text: String, url: String) async throws
    /// Archived threads are not polled; settled threads absorb events without waking.
    func pause(_ sessionID: SessionID) -> PullRequestPause
    /// The checkout's branch and GitHub `owner/repo`, if any.
    func branch(of sessionID: SessionID) async -> (owner: String, repo: String, branch: String)?
}

public enum PullRequestPause: Sendable, Equatable {
    case none
    /// Settled: polling continues (chips stay current) but events are absorbed without waking.
    case settled
    /// Archived: no polling until restored.
    case archived
}

/// PR linking and watching (docs/features/orchestration-extras.md).
///
/// - Links live in the session's metadata (`bellocode_prs`): they travel with the session. This service mirrors them
///   from session changes (`.lineage` topic).
/// - Snapshots are fetched through `gh` or the public API with ETags (`GitHubCache`), off the main actor.
/// - A watch polls every `baseInterval` (doubling after failures up to `maxBackoff`, back to base after a success)
///   and wakes the thread once per event (checks finished, review submitted, new comments, merged or closed); what was
///   reported is persisted (`app_pr_watch`), so a relaunch never repeats a wake. A merged or closed PR, or eight
///   failures in a row, stop the watch with a visible reason.
///
/// Threading: `@MainActor` state; GitHub I/O and JSON parsing run in `PullRequestFetcher` off the main actor. The poll
/// loop is owned by this service and cancelled by `shutdown()`.
@MainActor
@Observable
public final class PullRequestService {
    public private(set) var access: GitHubAccess?
    /// Linked PRs by thread (from session metadata).
    public private(set) var links: [SessionID: [LinkedPullRequest]] = [:]
    /// Latest snapshot by PR URL.
    public private(set) var snapshots: [String: PullRequestSnapshot] = [:]
    /// Latest fetch problem by PR URL (cleared on success); shown, never hidden.
    public private(set) var problems: [String: String] = [:]
    /// Watch records by `sessionID|url`.
    public private(set) var watches: [String: PullRequestWatchRecord] = [:]

    public static let maxFailures = 8
    public static let refreshTTL: TimeInterval = 60
    public static let branchCheckTTL: TimeInterval = 600

    @ObservationIgnored public weak var host: (any PullRequestHost)?
    @ObservationIgnored private let store: ProjectionStore
    @ObservationIgnored private let clock: any WallClock
    @ObservationIgnored private let provider: any GitHubAccessProvider
    @ObservationIgnored private let fetcher = PullRequestFetcher(cache: GitHubCache())
    @ObservationIgnored private var transport: (any GitHubTransport)?
    @ObservationIgnored private let baseInterval: TimeInterval
    @ObservationIgnored private let maxBackoff: TimeInterval
    @ObservationIgnored private var nextPoll: [String: Date] = [:]
    @ObservationIgnored private var interval: [String: TimeInterval] = [:]
    @ObservationIgnored private var lastFetch: [String: Date] = [:]
    @ObservationIgnored private var branchChecked: [SessionID: Date] = [:]
    @ObservationIgnored private var seenOutputParts: Set<String> = []
    @ObservationIgnored private var fetches: [String: Task<PullRequestSnapshot?, Never>] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "app.bellocode", category: "pull-requests")

    /// Off in tests that drive `pollDue()` themselves.
    @ObservationIgnored private let autoPoll: Bool
    @ObservationIgnored private var polling: Set<String> = []

    public init(
        store: ProjectionStore, clock: any WallClock, provider: any GitHubAccessProvider, baseInterval: TimeInterval = 120,
        maxBackoff: TimeInterval = 1800, autoPoll: Bool = true
    ) {
        self.autoPoll = autoPoll
        self.store = store
        self.clock = clock
        self.provider = provider
        self.baseInterval = baseInterval
        self.maxBackoff = maxBackoff
    }

    // MARK: Lifecycle

    public func start() async {
        for record in (try? await store.pullRequestWatches()) ?? [] { watches[Self.key(record.sessionID, record.url)] = record }
        if let host { ingest(await host.allSessions()) }
        for (key, record) in watches where record.stoppedReason == nil { nextPoll[key] = clock.now() }
        restartLoop()
    }

    public func shutdown() {
        loop?.cancel()
        loop = nil
        for task in fetches.values { task.cancel() }
        fetches.removeAll()
    }

    /// Session changes (metadata): links follow the server's copy.
    public func ingest(_ sessions: [Session]) {
        for session in sessions {
            let list = LinkedPullRequest.decode(fromMetadata: session.metadata)
            if list.isEmpty { if links[session.id] != nil { links[session.id] = nil } } else if links[session.id] != list { links[session.id] = list }
            for link in list where link.watching {
                let key = Self.key(session.id, link.ref.url)
                if watches[key] == nil {
                    watches[key] = PullRequestWatchRecord(sessionID: session.id, url: link.ref.url)
                    nextPoll[key] = clock.now()
                }
            }
        }
    }

    public func removed(_ ids: Set<SessionID>) {
        for id in ids {
            links[id] = nil
            for (key, record) in watches where record.sessionID == id {
                watches[key] = nil
                nextPoll[key] = nil
                Task { [store] in try? await store.deletePullRequestWatch(sessionID: id, url: record.url) }
            }
        }
    }

    // MARK: Reads

    public func links(for id: SessionID) -> [LinkedPullRequest] { links[id] ?? [] }

    public func watch(_ id: SessionID, _ url: String) -> PullRequestWatchRecord? { watches[Self.key(id, url)] }

    static func key(_ id: SessionID, _ url: String) -> String { id.rawValue + "|" + url }

    // MARK: Commands

    /// Links PRs to a thread (idempotent). `watch` also starts watching them.
    @discardableResult
    public func link(_ refs: [PullRequestRef], to id: SessionID, source: PullRequestLinkSource, watch: Bool = false) async throws -> [LinkedPullRequest] {
        guard let host else { throw ExtrasError("BelloCode is not connected.") }
        let now = clock.now()
        let updated = try await host.writeLinks(id) { current in
            var list = current
            for ref in refs {
                if let index = list.firstIndex(where: { $0.ref == ref }) {
                    if watch { list[index].watching = true }
                } else {
                    list.append(LinkedPullRequest(ref: ref, source: source, watching: watch, linked: now))
                }
            }
            return list
        }
        apply(updated, for: id)
        for ref in refs where fetches[ref.url] == nil {
            let task = Task { [weak self] () -> PullRequestSnapshot? in await self?.fetch(ref) }
            fetches[ref.url] = task
            Task { [weak self] in
                _ = await task.value
                if self?.fetches[ref.url] == task { self?.fetches[ref.url] = nil }
            }
        }
        return updated
    }

    public func unlink(_ refs: [PullRequestRef], from id: SessionID) async throws {
        guard let host else { throw ExtrasError("BelloCode is not connected.") }
        let gone = Set(refs)
        let updated = try await host.writeLinks(id) { $0.filter { !gone.contains($0.ref) } }
        apply(updated, for: id)
        for ref in refs { await dropWatch(id, ref.url) }
    }

    /// Starts or stops watching a linked PR (linking it first when needed).
    public func setWatching(_ ref: PullRequestRef, for id: SessionID, _ watching: Bool) async throws {
        guard let host else { throw ExtrasError("BelloCode is not connected.") }
        if watching, !links(for: id).contains(where: { $0.ref == ref }) {
            try await link([ref], to: id, source: .agent, watch: true)
        } else {
            let updated = try await host.writeLinks(id) { list in
                list.map { link in
                    var link = link
                    if link.ref == ref { link.watching = watching }
                    return link
                }
            }
            apply(updated, for: id)
        }
        let key = Self.key(id, ref.url)
        if watching {
            var record = watches[key] ?? PullRequestWatchRecord(sessionID: id, url: ref.url)
            record.stoppedReason = nil
            record.consecutiveFailures = 0
            watches[key] = record
            try? await store.savePullRequestWatch(record)
            nextPoll[key] = clock.now()
            interval[key] = baseInterval
            restartLoop()
        } else {
            await dropWatch(id, ref.url)
        }
    }

    private func dropWatch(_ id: SessionID, _ url: String) async {
        let key = Self.key(id, url)
        watches[key] = nil
        nextPoll[key] = nil
        try? await store.deletePullRequestWatch(sessionID: id, url: url)
    }

    private func apply(_ list: [LinkedPullRequest], for id: SessionID) {
        links[id] = list.isEmpty ? nil : list
    }

    /// Fetches the thread's linked PRs if their snapshots are older than `refreshTTL` (the thread is on screen), and
    /// checks once in a while whether its branch has an open PR to auto-link.
    public func refresh(thread id: SessionID) async {
        for link in links(for: id) {
            if let last = lastFetch[link.ref.url], clock.now().timeIntervalSince(last) < Self.refreshTTL { continue }
            await refresh(link.ref)
        }
        await autoLinkBranch(id)
    }

    /// Fetches one PR now (joins a fetch already in flight for it).
    @discardableResult
    public func refresh(_ ref: PullRequestRef) async -> PullRequestSnapshot? {
        if let running = fetches[ref.url] { return await running.value }
        let task = Task { [weak self] () -> PullRequestSnapshot? in
            guard let self else { return nil }
            return await self.fetch(ref)
        }
        fetches[ref.url] = task
        let result = await task.value
        if fetches[ref.url] == task { fetches[ref.url] = nil }
        return result
    }

    private func fetch(_ ref: PullRequestRef) async -> PullRequestSnapshot? {
        guard let transport = await resolveTransport() else {
            problems[ref.url] = access?.label ?? "GitHub is unavailable."
            return nil
        }
        do {
            let snapshot = try await fetcher.snapshot(ref, via: transport, now: clock.now())
            snapshots[ref.url] = snapshot
            problems[ref.url] = nil
            lastFetch[ref.url] = clock.now()
            return snapshot
        } catch {
            problems[ref.url] = (error as? GitHubError)?.description ?? "GitHub could not be reached."
            if case .notFound = error as? GitHubError, access == .publicAPI {
                problems[ref.url] = "Not visible without signing in. Connect GitHub: install the GitHub CLI and run gh auth login."
            }
            self.transport = nil  // re-resolve next time (gh may have been signed in meanwhile)
            return nil
        }
    }

    private func resolveTransport() async -> (any GitHubTransport)? {
        if let transport { return transport }
        let resolved = await provider.resolve()
        access = resolved.access
        transport = resolved.transport
        return transport
    }

    // MARK: Auto-linking

    /// Links the open PR(s) whose head is the thread's branch (checked at most every `branchCheckTTL`).
    public func autoLinkBranch(_ id: SessionID) async {
        if let checked = branchChecked[id], clock.now().timeIntervalSince(checked) < Self.branchCheckTTL { return }
        branchChecked[id] = clock.now()
        guard let host, let place = await host.branch(of: id), !["main", "master", "HEAD", "trunk", "develop"].contains(place.branch),
            let transport = await resolveTransport()
        else { return }
        guard let refs = try? await fetcher.openPullRequests(owner: place.owner, repo: place.repo, branch: place.branch, via: transport) else { return }
        let fresh = refs.filter { ref in !links(for: id).contains { $0.ref == ref } }
        if !fresh.isEmpty { _ = try? await link(fresh, to: id, source: .branch) }
    }

    /// A finished command's output in a thread: PR URLs printed by `gh pr create` (or `gh pr view`) are linked. Each
    /// tool part is looked at once.
    public func noticeCommand(partID: String, sessionID: SessionID, command: String, output: String) async {
        guard !seenOutputParts.contains(partID) else { return }
        seenOutputParts.insert(partID)
        if seenOutputParts.count > 4_096 { seenOutputParts.removeAll() }
        guard command.contains("gh pr create") || command.contains("gh pr view") || command.contains("hub pull-request") else { return }
        let refs = PullRequestRef.find(in: output, limit: 4).filter { ref in !links(for: sessionID).contains { $0.ref == ref } }
        guard !refs.isEmpty else { return }
        _ = try? await link(refs, to: sessionID, source: .output)
    }

    // MARK: Watching

    private func restartLoop() {
        loop?.cancel()
        guard autoPoll, !nextPoll.isEmpty else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let due = self.nextPoll.values.min() ?? self.clock.now().addingTimeInterval(3_600)
                do { try await self.clock.sleep(until: due) } catch { return }
                await self.pollDue()
            }
        }
    }

    /// Polls every watch that is due now (the loop, and tests).
    public func pollDue() async {
        let now = clock.now()
        for (key, date) in nextPoll where date <= now && !polling.contains(key) {
            guard let record = watches[key], record.stoppedReason == nil else {
                nextPoll[key] = nil
                continue
            }
            polling.insert(key)
            await poll(key, record)
            polling.remove(key)
        }
    }

    private func poll(_ key: String, _ start: PullRequestWatchRecord) async {
        guard let ref = PullRequestRef.parse(start.url) else { return }
        let pause = host?.pause(start.sessionID) ?? .none
        let base = interval[key] ?? baseInterval
        if pause == .archived {
            nextPoll[key] = clock.now().addingTimeInterval(baseInterval)
            return
        }
        guard let snapshot = await refresh(ref) else {
            var record = watches[key] ?? start
            record.consecutiveFailures += 1
            if record.consecutiveFailures >= Self.maxFailures {
                record.stoppedReason = "GitHub could not be reached \(Self.maxFailures) times in a row"
                nextPoll[key] = nil
            } else {
                let next = min(maxBackoff, base * 2)
                interval[key] = next
                nextPoll[key] = clock.now().addingTimeInterval(next)
            }
            watches[key] = record
            try? await store.savePullRequestWatch(record)
            return
        }
        interval[key] = baseInterval
        nextPoll[key] = clock.now().addingTimeInterval(baseInterval)
        var record = watches[key] ?? start
        record.consecutiveFailures = 0
        guard let baseline = record.baseline else {
            record.baseline = .initial(snapshot)
            watches[key] = record
            try? await store.savePullRequestWatch(record)
            return
        }
        let (events, next) = baseline.diff(snapshot)
        guard !events.isEmpty else {
            if next != baseline {
                record.baseline = next
                watches[key] = record
                try? await store.savePullRequestWatch(record)
            }
            return
        }
        let terminal = events.contains { if case .closed = $0 { true } else { false } }
        if pause == .none, let host {
            do {
                try await host.wake(start.sessionID, text: PullRequestWakeText.message(snapshot, events: events), url: start.url)
                record.wakes += 1
                record.lastWake = clock.now()
                record.lastWakeText = events.map(\.text).joined(separator: " ")
                log.info("pull request wake posted")
            } catch {
                // Not delivered: keep the old baseline so the same events wake at the next poll.
                watches[key] = record
                return
            }
        }
        record.baseline = next
        if terminal {
            record.stoppedReason = snapshot.state == .merged ? "merged" : "closed"
            nextPoll[key] = nil
        }
        watches[key] = record
        try? await store.savePullRequestWatch(record)
        if terminal, let host {
            _ = try? await host.writeLinks(start.sessionID) { list in
                list.map { link in
                    var link = link
                    if link.ref == ref { link.watching = false }
                    return link
                }
            }
        }
    }

    /// Waits for fetches in flight (tests).
    public func waitForFetches() async {
        for task in Array(fetches.values) { _ = await task.value }
    }

    /// When a watch polls next (tests, the PR section's "Next check").
    public func nextPollDate(_ id: SessionID, _ url: String) -> Date? { nextPoll[Self.key(id, url)] }
}
