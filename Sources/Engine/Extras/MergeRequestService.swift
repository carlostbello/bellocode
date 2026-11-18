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
    /// Whether a wake with this ID is already in the thread (true/false), or unknown (nil: the server cannot be asked).
    /// Used after a relaunch or a lost answer, so an observed event is not posted twice.
    func wakeDelivered(_ sessionID: SessionID, wakeID: String) async -> Bool?
}

extension MergeRequestHost {
    public func wakeDelivered(_ sessionID: SessionID, wakeID: String) async -> Bool? { false }
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
    /// Per instance: user, version, edition, probed capabilities, token scopes and expiry (persisted; never the token).
    public private(set) var instanceStatus: [String: GitLabInstanceStatus] = [:]
    /// Per instance: write actions and approve/merge switches (Settings ▸ GitLab; off by default).
    public private(set) var instanceSettings: [String: GitLabInstanceSettings] = [:]
    public private(set) var babysitPolicy = BabysitPolicy()
    /// Per MR URL: the family of the last failure (the panel and chips say "Offline", "Token invalid", … beside the
    /// cached data, which stays).
    public private(set) var failureKinds: [String: ForgeErrorKind] = [:]
    /// Visible wake log per watch key (`session|url`), newest first, loaded on demand.
    public private(set) var wakeLogs: [String: [MergeRequestWakeLogEntry]] = [:]
    /// Approval rules per MR URL (Premium/Ultimate instances only; loaded on demand).
    public private(set) var approvalRules: [String: [ApprovalRuleDigest]] = [:]

    public static let maxFailures = 8
    public static let refreshTTL: TimeInterval = 60
    public static let branchCheckTTL: TimeInterval = 600
    static let instancesKey = "gitlab.instances"
    /// Plain-HTTP instances the person explicitly allowed (M1): their token may cross the network unencrypted.
    static let plainHTTPKey = "gitlab.plainHTTPAllowed"
    /// Addresses the person removed (S7): a token found for one of them is never reused; only a new token is.
    static let removedKey = "gitlab.removedInstances"
    static let settingsKey = "gitlab.instanceSettings"
    static let policyKey = "gitlab.babysitPolicy"
    /// Distinct merge requests read per polling pass (the rest follow seconds later): bounded work per wake-up.
    static let maxMergeRequestsPerPass = 8
    @ObservationIgnored private var removedAccounts: Set<String> = []
    @ObservationIgnored public let plainHTTPAllowed = PlainHTTPAllowList()

    @ObservationIgnored public weak var host: (any MergeRequestHost)?
    @ObservationIgnored let store: ProjectionStore
    @ObservationIgnored let clock: any WallClock
    @ObservationIgnored let provider: GitLabProvider
    @ObservationIgnored private var snapshotWrites: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored let tokens: any SecretVault
    @ObservationIgnored let baseInterval: TimeInterval
    @ObservationIgnored let maxBackoff: TimeInterval
    @ObservationIgnored let autoPoll: Bool
    @ObservationIgnored private var nextPoll: [String: Date] = [:]
    @ObservationIgnored private var interval: [String: TimeInterval] = [:]
    @ObservationIgnored private var lastFetch: [String: Date] = [:]
    @ObservationIgnored private var branchChecked: [SessionID: Date] = [:]
    @ObservationIgnored private var seenOutputParts: Set<String> = []
    @ObservationIgnored private var fetches: [String: Task<Result<MergeRequestSnapshot, ForgeError>, Never>] = [:]
    @ObservationIgnored private var fetchIDs: [String: Int] = [:]
    @ObservationIgnored private var nextFetchID = 0
    @ObservationIgnored private var polling: Set<String> = []
    /// Changes whenever a watch is created, dropped or re-added. A poll checks it after its fetch (and after a wake), so
    /// a completion never restores, reschedules or wakes for a watch the person withdrew in the meantime.
    @ObservationIgnored private var watchGenerations: [String: Int] = [:]
    @ObservationIgnored private var nextWatchGeneration = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored let log = Logger(subsystem: "app.bellocode", category: "merge-requests")

    public init(
        store: ProjectionStore, clock: any WallClock, transport: any ForgeTransport, tokens: any SecretVault, baseInterval: TimeInterval = 120,
        maxBackoff: TimeInterval = 1800, autoPoll: Bool = true
    ) {
        self.store = store
        self.clock = clock
        self.tokens = tokens
        provider = GitLabProvider(transport: transport, tokens: tokens, plainHTTPAllowed: plainHTTPAllowed, now: { [clock] in clock.now() })
        self.baseInterval = baseInterval
        self.maxBackoff = maxBackoff
        self.autoPoll = autoPoll
    }

    // MARK: Lifecycle

    public func start() async {
        let saved = (try? await store.preference(Self.instancesKey, as: [String].self)) ?? []
        instances = saved.compactMap(GitLabInstance.init(baseURL:))
        let allowed = (try? await store.preference(Self.plainHTTPKey, as: [String].self)) ?? []
        plainHTTPAllowed.set(Set(allowed).intersection(instances.map(\.baseURL)))
        removedAccounts = Set((try? await store.preference(Self.removedKey, as: [String].self)) ?? [])
        refreshTokenPresence()
        instanceStatus = ((try? await store.gitLabInstanceStatuses()) ?? [:]).filter { key, _ in instances.contains { $0.baseURL == key } }
        instanceSettings = (try? await store.preference(Self.settingsKey, as: [String: GitLabInstanceSettings].self)) ?? [:]
        babysitPolicy = (try? await store.preference(Self.policyKey, as: BabysitPolicy.self)) ?? BabysitPolicy()
        // Cached first: the panel and chips show the last snapshot (with its time) before anything is fetched.
        for snapshot in (try? await store.mergeRequestSnapshots()) ?? [] where snapshots[snapshot.ref.url] == nil { snapshots[snapshot.ref.url] = snapshot }
        for record in (try? await store.mergeRequestWatches()) ?? [] { watches[Self.key(record.sessionID, record.url)] = record }
        if let host { ingest(await host.allSessions()) }
        for (key, record) in watches where record.stoppedReason == nil { nextPoll[key] = clock.now() }
        restartLoop()
        if autoPoll {
            // Version, edition and token expiry, once per launch per instance with a token (off the launch path).
            let targets = instances.filter { instancesWithToken.contains($0.baseURL) }
            statusTask = Task { [weak self] in
                for instance in targets {
                    guard !Task.isCancelled else { return }
                    _ = await self?.refreshInstanceStatus(instance)
                }
            }
        }
    }

    public func shutdown() {
        loop?.cancel()
        loop = nil
        statusTask?.cancel()
        statusTask = nil
        for task in fetches.values { task.cancel() }
        fetches.removeAll()
        fetchIDs.removeAll()
    }

    public func ingest(_ sessions: [Session]) {
        for session in sessions {
            let list = LinkedMergeRequest.decode(fromMetadata: session.metadata)
            if list.isEmpty { if links[session.id] != nil { links[session.id] = nil } } else if links[session.id] != list { links[session.id] = list }
            for link in list where link.watching {
                let key = Self.key(session.id, link.ref.url)
                if watches[key] == nil {
                    bumpGeneration(key)
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
                bumpGeneration(key)
                watches[key] = nil
                nextPoll[key] = nil
                wakeLogs[key] = nil
                Task { [store] in try? await store.deleteMergeRequestWatch(sessionID: id, url: record.url) }
            }
            Task { [store] in try? await store.deleteMergeRequestWakes(sessionID: id) }
        }
    }

    // MARK: Instances and tokens (Settings ▸ GitLab)

    /// Adds (or updates the token of) an instance. The token goes straight to the Keychain.
    ///
    /// An `http://` address is refused unless `allowPlainHTTP` (a visible, per-instance choice in Settings): the token
    /// would cross the network unencrypted.
    public func saveInstance(baseURL: String, token: SecretValue?, allowPlainHTTP: Bool = false) async throws -> GitLabInstance {
        guard let instance = GitLabInstance(baseURL: baseURL) else {
            throw ExtrasError("Enter the GitLab address, like https://gitlab.example.com (a path such as /gitlab is fine).")
        }
        if instance.isPlainHTTP {
            guard allowPlainHTTP || plainHTTPAllowed.contains(instance.baseURL) else {
                throw ExtrasError("\(instance.baseURL) is plain HTTP: the token would be sent unencrypted. Use https://, or tick “Allow unencrypted HTTP for this instance”.")
            }
            if !plainHTTPAllowed.contains(instance.baseURL) {
                plainHTTPAllowed.set(plainHTTPAllowed.all.union([instance.baseURL]))
                try? await store.setPreference(Self.plainHTTPKey, plainHTTPAllowed.all.sorted())
            }
        }
        if !instances.contains(instance), removedAccounts.contains(instance.baseURL), token?.isEmpty ?? true,
           ((try? tokens.read(account: instance.baseURL)) ?? nil) != nil {
            // Re-adding a removed address without a new token: a token still in the Keychain for it is never reused;
            // it must be deleted first (S7).
            do { try tokens.delete(account: instance.baseURL) } catch {
                throw ExtrasError("An old token for \(instance.baseURL) is still in the Keychain and could not be deleted, so it was not reused. Enter a new token, or remove it in Keychain Access.")
            }
        }
        if let token, !token.isEmpty {
            try tokens.store(account: instance.baseURL, label: "GitLab token for \(instance.baseURL)", value: token)
            if removedAccounts.remove(instance.baseURL) != nil { try? await store.setPreference(Self.removedKey, removedAccounts.sorted()) }
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

    /// Removes an instance and deletes its token from the Keychain. Succeeds only when the token is deleted: if the
    /// Keychain refuses, the instance stays listed with the problem and nothing is reported removed (S7).
    public func removeInstance(_ instance: GitLabInstance) async throws {
        // Remembered first: whatever happens to the deletion, this token is not reused when the address is added again.
        removedAccounts.insert(instance.baseURL)
        try? await store.setPreference(Self.removedKey, removedAccounts.sorted())
        do {
            try tokens.delete(account: instance.baseURL)
        } catch {
            let message = "The token for \(instance.baseURL) could not be deleted from the Keychain (\(error.localizedDescription)), so the instance was not removed. Try again."
            instanceProblems[instance.baseURL] = message
            refreshTokenPresence()
            throw ExtrasError(message)
        }
        instances.removeAll { $0 == instance }
        if plainHTTPAllowed.contains(instance.baseURL) {
            plainHTTPAllowed.set(plainHTTPAllowed.all.subtracting([instance.baseURL]))
            try? await store.setPreference(Self.plainHTTPKey, plainHTTPAllowed.all.sorted())
        }
        instanceProblems[instance.baseURL] = nil
        instanceStatus[instance.baseURL] = nil
        instanceSettings[instance.baseURL] = nil
        try? await store.deleteGitLabInstanceStatus(instance.baseURL)
        try? await store.setPreference(Self.settingsKey, instanceSettings)
        try? await store.setPreference(Self.instancesKey, instances.map(\.baseURL))
        refreshTokenPresence()
    }

    /// The token's user name ("Test Connection"), with version, edition and token scopes/expiry refreshed; records a
    /// problem on failure.
    public func testConnection(_ instance: GitLabInstance) async -> Result<String, ForgeError> {
        switch await refreshInstanceStatus(instance) {
        case .success(let status): return .success(status.user ?? "unknown")
        case .failure(let error): return .failure(error)
        }
    }

    /// Reads who the token is, the instance's version and edition, and the token's scopes and expiry (each optional).
    @discardableResult
    public func refreshInstanceStatus(_ instance: GitLabInstance) async -> Result<GitLabInstanceStatus, ForgeError> {
        let previous = instanceStatus[instance.baseURL]?.capabilities ?? GitLabCapabilities()
        do {
            let status = try await provider.instanceStatus(instance, previous: previous, now: clock.now())
            guard instances.contains(instance) else { return .success(status) }
            instanceStatus[instance.baseURL] = status
            instanceProblems[instance.baseURL] = nil
            try? await store.saveGitLabInstanceStatus(instance.baseURL, status)
            return .success(status)
        } catch {
            let failure = error as? ForgeError ?? .network(error.localizedDescription)
            if failure.needsPerson { instanceProblems[instance.baseURL] = failure.description }
            return .failure(failure)
        }
    }

    /// The expiry warning for an instance's token (30, 7 and 1 days before; expired), from the last check.
    public func tokenWarning(_ baseURL: String) -> GitLabTokenInfo.ExpiryWarning? {
        instanceStatus[baseURL]?.token?.expiryWarning(now: clock.now())
    }

    func approvalRulesStore(_ url: String, _ rules: [ApprovalRuleDigest]) { approvalRules[url] = rules }

    public func settings(for baseURL: String) -> GitLabInstanceSettings { instanceSettings[baseURL] ?? GitLabInstanceSettings() }

    public func setSettings(_ settings: GitLabInstanceSettings, for baseURL: String) async {
        instanceSettings[baseURL] = settings
        try? await store.setPreference(Self.settingsKey, instanceSettings)
    }

    public func setBabysitPolicy(_ policy: BabysitPolicy) async {
        var bounded = policy
        bounded.wakesPerHour = min(60, max(1, policy.wakesPerHour))
        babysitPolicy = bounded
        try? await store.setPreference(Self.policyKey, bounded)
    }

    public func capabilities(_ baseURL: String) -> GitLabCapabilities { instanceStatus[baseURL]?.capabilities ?? GitLabCapabilities() }

    /// Records a probe result (an optional endpoint answered or was missing) for the instance.
    func recordProbe(_ baseURL: String, _ feature: GitLabFeature, _ available: Bool) {
        var status = instanceStatus[baseURL] ?? GitLabInstanceStatus()
        guard status.capabilities.probed[feature.rawValue] != available else { return }
        status.capabilities.record(feature, available)
        instanceStatus[baseURL] = status
        Task { [store] in try? await store.saveGitLabInstanceStatus(baseURL, status) }
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
            if watches[key] == nil { bumpGeneration(key) }
            var record = watches[key] ?? MergeRequestWatchRecord(sessionID: id, url: ref.url)
            record.stoppedReason = nil
            record.consecutiveFailures = 0
            watches[key] = record
            try? await store.saveMergeRequestWatch(record)
            nextPoll[key] = clock.now()
            interval[key] = baseInterval
            restartLoop()
            await appendLog(key, record, .started, "Babysitting started. " + babysitPolicy.summary)
        } else {
            await appendLog(key, watches[key] ?? MergeRequestWatchRecord(sessionID: id, url: ref.url), .stopped, "Babysitting stopped.")
            await dropWatch(id, ref.url)
        }
    }

    private func dropWatch(_ id: SessionID, _ url: String) async {
        let key = Self.key(id, url)
        bumpGeneration(key)
        watches[key] = nil
        nextPoll[key] = nil
        try? await store.deleteMergeRequestWatch(sessionID: id, url: url)
    }

    private func bumpGeneration(_ key: String) {
        nextWatchGeneration += 1
        watchGenerations[key] = nextWatchGeneration
    }

    /// The watch this poll started for is still the current one (not dropped, not removed and re-added).
    private func isCurrent(_ key: String, _ generation: Int?) -> Bool {
        watches[key] != nil && watchGenerations[key] == generation
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
        nextFetchID += 1
        let id = nextFetchID
        // The fetch records its result and leaves `fetches` in the same main-actor turn as it finishes. A separate
        // cleanup task left a window in which a later poll joined the finished fetch and read its old snapshot.
        let task = Task { [weak self] () -> Result<MergeRequestSnapshot, ForgeError> in
            let result: Result<MergeRequestSnapshot, ForgeError>
            do { result = .success(try await provider.mergeRequest(ref, now: now)) } catch {
                result = .failure(error as? ForgeError ?? .network(error.localizedDescription))
            }
            self?.finishFetch(ref, id: id, result)
            return result
        }
        fetches[ref.url] = task
        fetchIDs[ref.url] = id
    }

    private func finishFetch(_ ref: MergeRequestRef, id: Int, _ result: Result<MergeRequestSnapshot, ForgeError>) {
        guard fetchIDs[ref.url] == id else { return }
        fetches[ref.url] = nil
        fetchIDs[ref.url] = nil
        record(ref, result)
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
            let changed = snapshots[ref.url] != snapshot
            snapshots[ref.url] = snapshot
            problems[ref.url] = nil
            failureKinds[ref.url] = nil
            instanceProblems[ref.instance] = nil
            lastFetch[ref.url] = clock.now()
            if changed {
                // Cached for the next launch, written in order (never an older snapshot over a newer one).
                let previous = snapshotWrites
                snapshotWrites = Task { [store] in
                    await previous?.value
                    try? await store.saveMergeRequestSnapshot(snapshot)
                }
            }
        case .failure(let error):
            // The cached snapshot stays (marked stale by its time and this problem); never replaced by nothing.
            problems[ref.url] = error.description
            failureKinds[ref.url] = error.kind
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

    /// Polls every due watch. Watches of the same MR (several threads) share one read; at most
    /// `maxMergeRequestsPerPass` distinct MRs per pass, the rest a few seconds later.
    public func pollDue() async {
        let now = clock.now()
        var due: [String: [String]] = [:]
        var order: [String] = []
        for (key, date) in nextPoll.sorted(by: { $0.value < $1.value }) where date <= now && !polling.contains(key) {
            guard let record = watches[key], record.stoppedReason == nil else {
                nextPoll[key] = nil
                continue
            }
            if due[record.url] == nil { order.append(record.url) }
            due[record.url, default: []].append(key)
        }
        for url in order.dropFirst(Self.maxMergeRequestsPerPass) {
            for key in due[url] ?? [] { nextPoll[key] = now.addingTimeInterval(5) }
        }
        for url in order.prefix(Self.maxMergeRequestsPerPass) {
            let keys = due[url] ?? []
            polling.formUnion(keys)
            await poll(url: url, keys: keys)
            polling.subtract(keys)
        }
    }

    private func poll(url: String, keys: [String]) async {
        guard let ref = MergeRequestRef.parse(url, instances: instances) else {
            for key in keys { nextPoll[key] = clock.now().addingTimeInterval(maxBackoff) }  // its instance was removed: wait for it to return
            return
        }
        var active: [(key: String, generation: Int?, start: MergeRequestWatchRecord)] = []
        for key in keys {
            guard let record = watches[key] else { continue }
            let generation = watchGenerations[key]
            if (host?.pause(record.sessionID) ?? .none) == .archived {
                nextPoll[key] = clock.now().addingTimeInterval(baseInterval)
                continue
            }
            // A wake recorded but not confirmed (relaunch, lost answer) goes first; new events wait behind it.
            if record.pending != nil {
                await deliverPending(key, generation: generation, ref: ref)
                if watches[key]?.pending != nil { continue }
            }
            if let current = watches[key], current.stoppedReason == nil { active.append((key, generation, current)) }
        }
        guard !active.isEmpty else { return }
        let fetched = await fetch(ref)
        for entry in active { await process(entry.key, entry.start, ref: ref, fetched: fetched, generation: entry.generation) }
    }

    private func process(_ key: String, _ start: MergeRequestWatchRecord, ref: MergeRequestRef, fetched: Result<MergeRequestSnapshot, ForgeError>, generation: Int?) async {
        // Unwatched, unlinked or re-added while the request was out: this result belongs to nobody.
        guard isCurrent(key, generation) else { return }
        let base = interval[key] ?? baseInterval
        // The thread may have been archived or snoozed while GitLab answered.
        let pause = host?.pause(start.sessionID) ?? .none
        if pause == .archived {
            nextPoll[key] = clock.now().addingTimeInterval(baseInterval)
            return
        }
        let snapshot: MergeRequestSnapshot
        switch fetched {
        case .success(let value):
            snapshot = value
        case .failure(let error):
            var record = watches[key] ?? start
            switch error {
            case .tokenInvalid, .noToken, .noInstance, .forbidden, .tls, .insecureInstance, .redirected:
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
        record.lastChecked = clock.now()
        guard let baseline = record.baseline else {
            record.baseline = .initial(snapshot)
            watches[key] = record
            try? await store.saveMergeRequestWatch(record)
            return
        }
        let policy = babysitPolicy
        let own = policy.ignoreOwnNotes ? Set([instanceStatus[ref.instance]?.user].compactMap { $0 }) : []
        var (events, next) = baseline.diff(snapshot, ignoreAuthors: own)
        if !policy.wakeOnPipelineSuccess { events.removeAll { $0.isPipelineSuccess } }
        guard !events.isEmpty else {
            if next != baseline || record != start {
                record.baseline = next
                watches[key] = record
                try? await store.saveMergeRequestWatch(record)
            }
            return
        }
        let terminal = events.contains(where: \.isTerminal)
        let summary = events.map(\.text).joined(separator: " ")
        guard pause == .none, host != nil else {
            // Settled: recorded and visible in the log, but the thread is not woken (no replay on unsettle).
            record.baseline = next
            if terminal { stop(&record, key, snapshot.state) }
            watches[key] = record
            try? await store.saveMergeRequestWatch(record)
            await appendLog(key, record, .absorbed, summary)
            if terminal { await clearWatchingFlag(ref, record.sessionID, key, generation) }
            return
        }
        // Budget: at most `wakesPerHour`; later events wait (the baseline is not advanced, so they arrive together).
        let hourAgo = clock.now().addingTimeInterval(-3_600)
        record.recentWakes = (record.recentWakes ?? []).filter { $0 > hourAgo }
        if !terminal, let recent = record.recentWakes, recent.count >= policy.wakesPerHour, let oldest = recent.min() {
            let until = oldest.addingTimeInterval(3_600)
            let firstDeferral = record.deferredUntil == nil
            record.deferredUntil = until
            nextPoll[key] = max(nextPoll[key] ?? until, until)
            watches[key] = record
            try? await store.saveMergeRequestWatch(record)
            if firstDeferral { await appendLog(key, record, .deferred, "Budget of \(policy.wakesPerHour) wakes an hour reached; waiting: \(summary)") }
            return
        }
        record.deferredUntil = nil
        // A failed pipeline brings a bounded, sanitised excerpt of its first failing job's log.
        var failing: (job: PipelineJob, excerpt: JobLogExcerpt)?
        if events.contains(where: \.isPipelineFailure), let job = snapshot.pipeline?.failedJobs.first, let instance = GitLabInstance(baseURL: ref.instance) {
            let project = ForgeProject(instance: instance, projectPath: ref.projectPath)
            if let chunk = try? await provider.jobLog(project, jobID: job.id, maxBytes: Self.excerptBytes, tryRange: capabilities(ref.instance).support(.jobLogRange).mayTry) {
                if let honoured = chunk.rangeHonoured { recordProbe(ref.instance, .jobLogRange, honoured) }
                failing = (job, JobLogExcerpt(log: chunk.text, headOmitted: chunk.headOmitted, known: knownSecrets(ref.instance)))
            }
            guard isCurrent(key, generation) else { return }
        }
        let wakeID = "w_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let text = MergeRequestWakeText.message(snapshot, events: events, wakeID: wakeID, failingJob: failing, known: knownSecrets(ref.instance))
        record.pending = PendingWake(id: wakeID, text: text, summary: summary, next: next, terminal: terminal, created: clock.now())
        watches[key] = record
        try? await store.saveMergeRequestWatch(record)
        await deliverPending(key, generation: generation, ref: ref, terminalState: terminal ? snapshot.state : nil)
    }

    /// Bytes of a failing job's log read for an excerpt.
    static let excerptBytes = 64 << 10

    /// Values never shown to a model even if GitLab echoes them (the instance's token).
    public func knownSecrets(_ baseURL: String) -> [String] {
        guard let token = try? tokens.read(account: baseURL), !token.isEmpty else { return [] }
        return [String(decoding: token.utf8, as: UTF8.self)]
    }

    /// Posts a recorded wake once: after an earlier attempt (a relaunch, a lost answer) it first asks whether the
    /// thread already has it.
    private func deliverPending(_ key: String, generation: Int?, ref: MergeRequestRef, terminalState: MergeRequestState? = nil) async {
        guard var record = watches[key], var pending = record.pending, let host else { return }
        if pending.attempts > 0 {
            switch await host.wakeDelivered(record.sessionID, wakeID: pending.id) {
            case true?:
                await finishDelivery(key, generation: generation, ref: ref, pending, terminalState: terminalState)
                return
            case nil:
                nextPoll[key] = clock.now().addingTimeInterval(baseInterval)
                return
            case false?:
                break
            }
            guard isCurrent(key, generation) else { return }
            record = watches[key] ?? record
        }
        pending.attempts += 1
        record.pending = pending
        watches[key] = record
        try? await store.saveMergeRequestWatch(record)
        do {
            try await host.wake(record.sessionID, text: pending.text, url: record.url)
        } catch {
            // Not confirmed: tried again at the next poll (which first checks whether it arrived after all).
            guard isCurrent(key, generation) else { return }
            nextPoll[key] = clock.now().addingTimeInterval(min(maxBackoff, (interval[key] ?? baseInterval) * 2))
            if pending.attempts == 1 { await appendLog(key, record, .failed, "Could not wake the thread (\(ExtrasError.message(error))); retrying: \(pending.summary)") }
            return
        }
        // Withdrawn while the wake was being posted: record nothing for the old watch.
        guard isCurrent(key, generation) else { return }
        await finishDelivery(key, generation: generation, ref: ref, pending, terminalState: terminalState)
    }

    private func finishDelivery(_ key: String, generation: Int?, ref: MergeRequestRef, _ pending: PendingWake, terminalState: MergeRequestState?) async {
        guard var record = watches[key] else { return }
        record.baseline = pending.next
        record.pending = nil
        record.wakes += 1
        record.lastWake = clock.now()
        record.lastWakeText = pending.summary
        record.recentWakes = (record.recentWakes ?? []) + [clock.now()]
        if pending.terminal { stop(&record, key, terminalState ?? pending.next.terminalReported ?? .closed) }
        watches[key] = record
        try? await store.saveMergeRequestWatch(record)
        log.info("merge request wake posted")
        await appendLog(key, record, .delivered, pending.summary, id: pending.id)
        if pending.terminal { await clearWatchingFlag(ref, record.sessionID, key, generation) }
    }

    private func stop(_ record: inout MergeRequestWatchRecord, _ key: String, _ state: MergeRequestState) {
        record.stoppedReason = state == .merged ? "merged" : "closed"
        nextPoll[key] = nil
    }

    private func clearWatchingFlag(_ ref: MergeRequestRef, _ sessionID: SessionID, _ key: String, _ generation: Int?) async {
        guard let host, isCurrent(key, generation) else { return }
        _ = try? await host.writeLinks(sessionID) { list in
            list.map { link in
                var link = link
                if link.ref == ref { link.watching = false }
                return link
            }
        }
    }

    // MARK: Wake log

    /// Loads a watch's log for display (newest first).
    public func loadWakeLog(_ id: SessionID, _ url: String) async {
        let entries = (try? await store.mergeRequestWakeLog(sessionID: id, url: url)) ?? []
        wakeLogs[Self.key(id, url)] = entries
    }

    public func wakeLog(_ id: SessionID, _ url: String) -> [MergeRequestWakeLogEntry] { wakeLogs[Self.key(id, url)] ?? [] }

    func appendLog(_ key: String, _ record: MergeRequestWatchRecord, _ outcome: MergeRequestWakeLogEntry.Outcome, _ summary: String, id: String? = nil) async {
        let entry = MergeRequestWakeLogEntry(
            id: id ?? "l_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased(), sessionID: record.sessionID,
            url: record.url, at: clock.now(), outcome: outcome, summary: String(summary.prefix(400)))
        wakeLogs[key] = Array(([entry] + (wakeLogs[key] ?? [])).prefix(ProjectionStore.mergeRequestWakeLogLimit))
        try? await store.appendMergeRequestWake(entry)
    }
}
