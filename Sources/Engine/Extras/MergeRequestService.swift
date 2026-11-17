import BelloCore
import Foundation
import Observation
import os

/// What the MR service needs from the rest of the engine, injected so its rules are tested without a server.
@MainActor
public protocol MergeRequestHost: AnyObject {
    func allSessions() async -> [Session]
    /// Replaces the thread's linked MRs in its metadata (read-modify-write on the server; other keys kept).
    func writeLinks(_ sessionID: SessionID, _ transform: @escaping @Sendable ([LinkedMergeRequest]) -> [LinkedMergeRequest]) async throws -> [LinkedMergeRequest]
    /// Posts the labelled wake (opencode `synthetic`, which starts a run).
    func wake(_ sessionID: SessionID, text: String, url: String) async throws
    /// Archived threads are not polled; settled threads absorb events without waking.
    func pause(_ sessionID: SessionID) -> MergeRequestPause
    /// The thread checkout's `origin` remote and branch.
    func checkout(of sessionID: SessionID) async -> (remote: String, branch: String)?
}

public enum MergeRequestPause: Sendable, Equatable {
    case none
    case settled
    case archived
}

/// Merge-request linking and watching on GitLab (docs/features/orchestration-extras.md).
///
/// - Instances (base URLs, path prefixes allowed) are app preferences; each one's access token is in the Keychain
///   (`GitLabProvider.tokenService`), never in the store, logs or the model's context.
/// - Links live in the session's metadata (`bellocode_mrs`) and travel with the session.
/// - A watch polls every `baseInterval` (doubling after failures up to `maxBackoff`; a 429 waits at least its
///   `Retry-After`) with conditional requests, and wakes the thread once per event (pipeline finished, approval given
///   or revoked, new comments, merged or closed); what was reported is persisted (`app_mr_watch`). Merged/closed, eight
///   failures in a row, or an invalid token stop or hold the watch with a visible reason.
///
/// Threading: `@MainActor` state; HTTP and JSON in `GitLabProvider` off the main actor. The poll loop is owned here.
@MainActor
@Observable
public final class MergeRequestService {
    public private(set) var instances: [GitLabInstance] = []
    /// Instances with a token in the Keychain (never the token).
    public private(set) var instancesWithToken: Set<String> = []
    /// Per instance: "token invalid or expired" and the like (cleared when the token is replaced or works again).
    public private(set) var instanceProblems: [String: String] = [:]
    public private(set) var links: [SessionID: [LinkedMergeRequest]] = [:]
    public private(set) var snapshots: [String: MergeRequestSnapshot] = [:]
    public private(set) var problems: [String: String] = [:]
    public private(set) var watches: [String: MergeRequestWatchRecord] = [:]

    public static let maxFailures = 8
    public static let refreshTTL: TimeInterval = 60
    public static let branchCheckTTL: TimeInterval = 600
    static let instancesKey = "gitlab.instances"

    @ObservationIgnored public weak var host: (any MergeRequestHost)?
    @ObservationIgnored private let store: ProjectionStore
    @ObservationIgnored private let clock: any WallClock
    @ObservationIgnored private let provider: any ForgeProvider
    @ObservationIgnored private let tokens: any SecretVault
    @ObservationIgnored private let baseInterval: TimeInterval
    @ObservationIgnored private let maxBackoff: TimeInterval
    @ObservationIgnored private let autoPoll: Bool
    @ObservationIgnored private var nextPoll: [String: Date] = [:]
    @ObservationIgnored private var interval: [String: TimeInterval] = [:]
    @ObservationIgnored private var lastFetch: [String: Date] = [:]
    @ObservationIgnored private var branchChecked: [SessionID: Date] = [:]
    @ObservationIgnored private var seenOutputParts: Set<String> = []
    @ObservationIgnored private var fetches: [String: Task<Result<MergeRequestSnapshot, ForgeError>, Never>] = [:]
    @ObservationIgnored private var polling: Set<String> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "app.bellocode", category: "merge-requests")

    public init(
        store: ProjectionStore, clock: any WallClock, transport: any ForgeTransport, tokens: any SecretVault, baseInterval: TimeInterval = 120,
        maxBackoff: TimeInterval = 1800, autoPoll: Bool = true
    ) {
        self.store = store
        self.clock = clock
        self.tokens = tokens
        provider = GitLabProvider(transport: transport, tokens: tokens)
        self.baseInterval = baseInterval
        self.maxBackoff = maxBackoff
        self.autoPoll = autoPoll
    }

    // MARK: Lifecycle

    public func start() async {
        let saved = (try? await store.preference(Self.instancesKey, as: [String].self)) ?? []
        instances = saved.compactMap(GitLabInstance.init(baseURL:))
        refreshTokenPresence()
        for record in (try? await store.mergeRequestWatches()) ?? [] { watches[Self.key(record.sessionID, record.url)] = record }
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

    public func ingest(_ sessions: [Session]) {
        for session in sessions {
            let list = LinkedMergeRequest.decode(fromMetadata: session.metadata)
            if list.isEmpty { if links[session.id] != nil { links[session.id] = nil } } else if links[session.id] != list { links[session.id] = list }
            for link in list where link.watching {
                let key = Self.key(session.id, link.ref.url)
                if watches[key] == nil {
                    watches[key] = MergeRequestWatchRecord(sessionID: session.id, url: link.ref.url)
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
                Task { [store] in try? await store.deleteMergeRequestWatch(sessionID: id, url: record.url) }
            }
        }
    }

    // MARK: Instances and tokens (Settings ▸ GitLab)

    /// Adds (or updates the token of) an instance. The token goes straight to the Keychain.
    public func saveInstance(baseURL: String, token: SecretValue?) async throws -> GitLabInstance {
        guard let instance = GitLabInstance(baseURL: baseURL) else {
            throw ExtrasError("Enter the GitLab address, like https://gitlab.example.com (a path such as /gitlab is fine).")
        }
        if let token, !token.isEmpty {
            try tokens.store(account: instance.baseURL, label: "GitLab token for \(instance.baseURL)", value: token)
            instanceProblems[instance.baseURL] = nil
            for (key, record) in watches where MergeRequestRef.parse(record.url, instances: [instance]) != nil { nextPoll[key] = clock.now() }
        }
        if !instances.contains(instance) {
            instances.append(instance)
            instances.sort { $0.baseURL < $1.baseURL }
            try? await store.setPreference(Self.instancesKey, instances.map(\.baseURL))
        }
        refreshTokenPresence()
        restartLoop()
        return instance
    }

    /// Removes an instance and deletes its token from the Keychain.
    public func removeInstance(_ instance: GitLabInstance) async {
        try? tokens.delete(account: instance.baseURL)
        instances.removeAll { $0 == instance }
        instanceProblems[instance.baseURL] = nil
        try? await store.setPreference(Self.instancesKey, instances.map(\.baseURL))
        refreshTokenPresence()
    }

    /// The token's user name ("Test Connection"); records a problem on failure.
    public func testConnection(_ instance: GitLabInstance) async -> Result<String, ForgeError> {
        do {
            let user = try await provider.currentUser(instance)
            instanceProblems[instance.baseURL] = nil
            return .success(user)
        } catch {
            let failure = error as? ForgeError ?? .network(error.localizedDescription)
            if failure.needsPerson { instanceProblems[instance.baseURL] = failure.description }
            return .failure(failure)
        }
    }

    private func refreshTokenPresence() {
        instancesWithToken = Set(instances.filter { ((try? tokens.read(account: $0.baseURL)) ?? nil)?.isEmpty == false }.map(\.baseURL))
    }

    // MARK: Reads

    public func links(for id: SessionID) -> [LinkedMergeRequest] { links[id] ?? [] }
    public func watch(_ id: SessionID, _ url: String) -> MergeRequestWatchRecord? { watches[Self.key(id, url)] }
    public func nextPollDate(_ id: SessionID, _ url: String) -> Date? { nextPoll[Self.key(id, url)] }
    static func key(_ id: SessionID, _ url: String) -> String { id.rawValue + "|" + url }

    /// An MR from a URL on a configured instance, or `!iid` in the thread's own project (from its `origin` remote).
    public func resolve(_ text: String, for sessionID: SessionID) async throws -> MergeRequestRef {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("!"), let iid = Int(trimmed.dropFirst()) {
            guard let host, let checkout = await host.checkout(of: sessionID) else {
                throw ExtrasError("!\(iid) needs this thread's folder to have an origin remote.")
            }
            guard let project = ForgeProject.resolve(remote: checkout.remote, instances: instances) else {
                throw ExtrasError(ForgeError.noInstance(Self.remoteHost(checkout.remote)).description)
            }
            return MergeRequestRef(instance: project.instance.baseURL, projectPath: project.projectPath, iid: iid)
        }
        if let ref = MergeRequestRef.parse(trimmed, instances: instances) { return ref }
        if trimmed.contains("/-/merge_requests/"), let host = URL(string: trimmed)?.host() { throw ExtrasError(ForgeError.noInstance(host).description) }
        throw ExtrasError("Not a merge request: give its URL (https://gitlab.example.com/group/project/-/merge_requests/12) or !12.")
    }

    static func remoteHost(_ remote: String) -> String {
        if let host = URL(string: remote)?.host() { return host }
        if let at = remote.firstIndex(of: "@"), let colon = remote[at...].firstIndex(of: ":") { return String(remote[remote.index(after: at)..<colon]) }
        return remote
    }

    // MARK: Commands

    @discardableResult
    public func link(_ refs: [MergeRequestRef], to id: SessionID, source: MergeRequestLinkSource, watch: Bool = false) async throws -> [LinkedMergeRequest] {
        guard let host else { throw ExtrasError("BelloCode is not connected.") }
        let now = clock.now()
        let updated = try await host.writeLinks(id) { current in
            var list = current
            for ref in refs {
                if let index = list.firstIndex(where: { $0.ref == ref }) {
                    if watch { list[index].watching = true }
                } else {
                    list.append(LinkedMergeRequest(ref: ref, source: source, watching: watch, linked: now))
                }
            }
            return list
        }
        apply(updated, for: id)
        for ref in refs where fetches[ref.url] == nil { startFetch(ref) }
        return updated
    }

    public func unlink(_ refs: [MergeRequestRef], from id: SessionID) async throws {
        guard let host else { throw ExtrasError("BelloCode is not connected.") }
        let gone = Set(refs)
        apply(try await host.writeLinks(id) { $0.filter { !gone.contains($0.ref) } }, for: id)
        for ref in refs { await dropWatch(id, ref.url) }
    }

    public func setWatching(_ ref: MergeRequestRef, for id: SessionID, _ watching: Bool) async throws {
        guard let host else { throw ExtrasError("BelloCode is not connected.") }
        if watching, !links(for: id).contains(where: { $0.ref == ref }) {
            try await link([ref], to: id, source: .agent, watch: true)
        } else {
            apply(
                try await host.writeLinks(id) { list in
                    list.map { link in
                        var link = link
                        if link.ref == ref { link.watching = watching }
                        return link
                    }
                }, for: id)
        }
        let key = Self.key(id, ref.url)
        if watching {
            var record = watches[key] ?? MergeRequestWatchRecord(sessionID: id, url: ref.url)
            record.stoppedReason = nil
            record.consecutiveFailures = 0
            watches[key] = record
            try? await store.saveMergeRequestWatch(record)
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
        try? await store.deleteMergeRequestWatch(sessionID: id, url: url)
    }

    private func apply(_ list: [LinkedMergeRequest], for id: SessionID) { links[id] = list.isEmpty ? nil : list }

    /// The thread is on screen: refresh stale snapshots and, now and then, auto-link its branch's open MR.
    public func refresh(thread id: SessionID) async {
        for link in links(for: id) {
            if let last = lastFetch[link.ref.url], clock.now().timeIntervalSince(last) < Self.refreshTTL { continue }
            await refresh(link.ref)
        }
        await autoLinkBranch(id)
    }

    @discardableResult
    public func refresh(_ ref: MergeRequestRef) async -> MergeRequestSnapshot? {
        if case .success(let snapshot) = await fetch(ref) { return snapshot }
        return nil
    }

    /// Waits for fetches in flight (tests, harnesses).
    public func waitForFetches() async {
        for task in Array(fetches.values) { _ = await task.value }
    }

    private func startFetch(_ ref: MergeRequestRef) {
        let provider = self.provider
        let now = clock.now()
        let task = Task { () -> Result<MergeRequestSnapshot, ForgeError> in
            do { return .success(try await provider.mergeRequest(ref, now: now)) } catch {
                return .failure(error as? ForgeError ?? .network(error.localizedDescription))
            }
        }
        fetches[ref.url] = task
        Task { [weak self] in
            let result = await task.value
            self?.record(ref, result)
            if self?.fetches[ref.url] == task { self?.fetches[ref.url] = nil }
        }
    }

    /// Fetches one MR (joining a fetch in flight).
    private func fetch(_ ref: MergeRequestRef) async -> Result<MergeRequestSnapshot, ForgeError> {
        if fetches[ref.url] == nil { startFetch(ref) }
        guard let task = fetches[ref.url] else { return .failure(.unexpected("No fetch.")) }
        let result = await task.value
        record(ref, result)
        return result
    }

    private func record(_ ref: MergeRequestRef, _ result: Result<MergeRequestSnapshot, ForgeError>) {
        switch result {
        case .success(let snapshot):
            snapshots[ref.url] = snapshot
            problems[ref.url] = nil
            instanceProblems[ref.instance] = nil
            lastFetch[ref.url] = clock.now()
        case .failure(let error):
            problems[ref.url] = error.description
            if error.needsPerson { instanceProblems[ref.instance] = error.description }
        }
    }

    // MARK: Auto-linking

    public func autoLinkBranch(_ id: SessionID) async {
        if let checked = branchChecked[id], clock.now().timeIntervalSince(checked) < Self.branchCheckTTL { return }
        branchChecked[id] = clock.now()
        guard let host, let checkout = await host.checkout(of: id), !["main", "master", "HEAD", "trunk", "develop"].contains(checkout.branch),
            let project = ForgeProject.resolve(remote: checkout.remote, instances: instances), instancesWithToken.contains(project.instance.baseURL)
        else { return }
        guard let refs = try? await provider.openMergeRequests(project, sourceBranch: checkout.branch) else { return }
        let fresh = refs.filter { ref in !links(for: id).contains { $0.ref == ref } }
        if !fresh.isEmpty { _ = try? await link(fresh, to: id, source: .branch) }
    }

    /// A finished `git push` in a thread: GitLab prints the MR's URL ("View merge request for …"); it is linked. Each
    /// tool part is looked at once; `…/merge_requests/new` links are not MRs.
    public func noticeCommand(partID: String, sessionID: SessionID, command: String, output: String) async {
        guard !seenOutputParts.contains(partID) else { return }
        seenOutputParts.insert(partID)
        if seenOutputParts.count > 4_096 { seenOutputParts.removeAll() }
        guard command.contains("git push") || command.contains("git-push") else { return }
        let refs = MergeRequestRef.find(in: output, instances: instances, limit: 4).filter { ref in !links(for: sessionID).contains { $0.ref == ref } }
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

    private func poll(_ key: String, _ start: MergeRequestWatchRecord) async {
        guard let ref = MergeRequestRef.parse(start.url, instances: instances) else {
            nextPoll[key] = clock.now().addingTimeInterval(maxBackoff)  // its instance was removed: wait for it to return
            return
        }
        let pause = host?.pause(start.sessionID) ?? .none
        let base = interval[key] ?? baseInterval
        if pause == .archived {
            nextPoll[key] = clock.now().addingTimeInterval(baseInterval)
            return
        }
        let snapshot: MergeRequestSnapshot
        switch await fetch(ref) {
        case .success(let value):
            snapshot = value
        case .failure(let error):
            var record = watches[key] ?? start
            switch error {
            case .tokenInvalid, .noToken, .noInstance, .forbidden:
                // Nothing a retry fixes: hold until the person updates Settings ▸ GitLab (saving a token re-arms it).
                nextPoll[key] = clock.now().addingTimeInterval(maxBackoff)
            case .rateLimited(let after):
                let next = min(maxBackoff, max(base * 2, after ?? 0))
                interval[key] = next
                nextPoll[key] = clock.now().addingTimeInterval(max(next, after ?? 0))
            default:
                record.consecutiveFailures += 1
                if record.consecutiveFailures >= Self.maxFailures {
                    record.stoppedReason = "GitLab could not be reached \(Self.maxFailures) times in a row"
                    nextPoll[key] = nil
                } else {
                    let next = min(maxBackoff, base * 2)
                    interval[key] = next
                    nextPoll[key] = clock.now().addingTimeInterval(next)
                }
            }
            watches[key] = record
            try? await store.saveMergeRequestWatch(record)
            return
        }
        interval[key] = baseInterval
        nextPoll[key] = clock.now().addingTimeInterval(baseInterval)
        var record = watches[key] ?? start
        record.consecutiveFailures = 0
        guard let baseline = record.baseline else {
            record.baseline = .initial(snapshot)
            watches[key] = record
            try? await store.saveMergeRequestWatch(record)
            return
        }
        let (events, next) = baseline.diff(snapshot)
        guard !events.isEmpty else {
            if next != baseline {
                record.baseline = next
                watches[key] = record
                try? await store.saveMergeRequestWatch(record)
            }
            return
        }
        let terminal = events.contains { if case .closed = $0 { true } else { false } }
        if pause == .none, let host {
            do {
                try await host.wake(start.sessionID, text: MergeRequestWakeText.message(snapshot, events: events), url: start.url)
                record.wakes += 1
                record.lastWake = clock.now()
                record.lastWakeText = events.map(\.text).joined(separator: " ")
                log.info("merge request wake posted")
            } catch {
                watches[key] = record  // not delivered: the same events wake at the next poll
                return
            }
        }
        record.baseline = next
        if terminal {
            record.stoppedReason = snapshot.state == .merged ? "merged" : "closed"
            nextPoll[key] = nil
        }
        watches[key] = record
        try? await store.saveMergeRequestWatch(record)
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
}
