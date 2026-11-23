import BelloCore
import Foundation
import Observation
import os

/// Inline review of merge requests (GitLab 2, docs/features/gitlab.md "Inline review").
///
/// - Loads the MR's latest diff version (versions + `diff_refs`) and its positioned discussions, off the main actor.
/// - Keeps the person's review drafts (persisted, `app_review_draft`); nothing is sent until an explicit action.
/// - Every write first re-reads the MR's versions: if the head moved since the version on screen, nothing is sent
///   and a `ReviewMovedError` asks the person to refresh (drafts are kept and re-anchored only where the same line
///   still shows the same text).
/// - Submit uses GitLab draft notes and one `bulk_publish` when the instance offers them; otherwise single notes,
///   each removed from the local drafts as soon as GitLab accepted it (a failure part-way leaves the rest, never a
///   duplicate).
///
/// Threading: `@MainActor` state; HTTP and parsing in `GitLabProvider` (off the main actor). Loads carry a generation
/// per MR and are dropped when superseded (rule 8).
@MainActor
@Observable
public final class MergeRequestReviewService {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        /// GitLab has no diff refs yet (it prepares diffs asynchronously after a push).
        case preparing
        case failed(String)
    }

    /// Loaded review per MR URL (kept while reloading; at most `maxLoaded`, least recently used dropped).
    public private(set) var states: [String: ReviewState] = [:]
    public private(set) var phases: [String: Phase] = [:]
    /// Local drafts per MR URL, oldest first.
    public private(set) var drafts: [String: [ReviewDraft]] = [:]
    /// The MR moved since the version shown (set by a failed action or a check); cleared by a reload.
    public private(set) var moved: [String: ReviewMovedError] = [:]
    /// Last result of a submit or action, per MR URL ("Published 3 comments as one review.").
    public private(set) var notices: [String: String] = [:]
    public private(set) var busy: Set<String> = []

    public static let maxLoaded = 8
    public static let maxDraftBody = 20_000

    @ObservationIgnored public let mergeRequests: MergeRequestService
    @ObservationIgnored let store: ProjectionStore
    @ObservationIgnored private var generations: [String: Int] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var loadedDrafts: Set<String> = []
    @ObservationIgnored let log = Logger(subsystem: "app.bellocode", category: "merge-request-review")

    public init(mergeRequests: MergeRequestService, store: ProjectionStore) {
        self.mergeRequests = mergeRequests
        self.store = store
    }

    var provider: GitLabProvider { mergeRequests.provider }

    // MARK: Loading

    /// Loads (or reloads) the latest version of the MR's diff and its discussions. The previous state stays visible.
    @discardableResult
    public func load(_ ref: MergeRequestRef) async -> ReviewState? {
        let key = ref.url
        let interval = EngineSignposts.gitLab.beginInterval("reviewLoad")
        defer { EngineSignposts.gitLab.endInterval("reviewLoad", interval) }
        let generation = (generations[key] ?? 0) + 1
        generations[key] = generation
        phases[key] = .loading
        await loadDrafts(ref)
        do {
            guard let (latest, count) = try await latestVersion(ref) else {
                guard generations[key] == generation else { return nil }
                phases[key] = .preparing
                return nil
            }
            async let diffRead = provider.versionDiff(ref, version: latest, count: count)
            async let discussionRead = provider.reviewDiscussions(ref)
            let diff = try await diffRead
            let discussions = try await discussionRead
            var serverDrafts: [ServerDraftNote]?
            if mergeRequests.capabilities(ref.instance).support(.draftNotes).mayTry {
                do {
                    serverDrafts = try await provider.draftNotes(ref)
                    mergeRequests.recordProbe(ref.instance, .draftNotes, true)
                } catch ForgeError.notFound {
                    mergeRequests.recordProbe(ref.instance, .draftNotes, false)
                } catch ForgeError.forbidden {}
            }
            guard generations[key] == generation, !Task.isCancelled else { return nil }
            let state = ReviewState(
                ref: ref, diff: diff, discussions: discussions.discussions, discussionsIncomplete: discussions.truncated, serverDrafts: serverDrafts,
                loaded: mergeRequests.clock.now())
            remember(key, state)
            moved[key] = nil
            phases[key] = .ready
            await reanchorDrafts(ref, to: diff)
            return state
        } catch {
            guard generations[key] == generation else { return nil }
            phases[key] = .failed((error as? ForgeError)?.description ?? ExtrasError.message(error))
            return nil
        }
    }

    /// The newest version and how many there are; nil while GitLab prepares the diff.
    func latestVersion(_ ref: MergeRequestRef) async throws -> (MergeRequestVersion, Int)? {
        let versions = try await provider.versions(ref)
        if let first = versions.first { return (first, versions.count) }
        // No versions listed: fall back to the MR's own diff_refs (older instances), else "preparing".
        guard let refs = try await provider.diffRefs(ref) else { return nil }
        return (MergeRequestVersion(id: 0, refs: refs), 1)
    }

    private func remember(_ key: String, _ state: ReviewState) {
        states[key] = state
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.maxLoaded {
            let dropped = order.removeFirst()
            states[dropped] = nil
            phases[dropped] = nil
        }
    }

    /// Throws `ReviewMovedError` when the MR's newest version is not the one on screen (and records it for the UI).
    public func checkNotMoved(_ ref: MergeRequestRef) async throws {
        guard let shown = states[ref.url]?.refs else { throw ExtrasError("Load the merge request's diff first.") }
        guard let (latest, _) = try await latestVersion(ref) else { throw ExtrasError("GitLab is still preparing this merge request's diff. Try again shortly.") }
        if latest.refs != shown {
            let error = ReviewMovedError(shown: shown, latest: latest.refs)
            moved[ref.url] = error
            throw error
        }
    }

    // MARK: Drafts (local)

    public func drafts(for ref: MergeRequestRef) -> [ReviewDraft] { drafts[ref.url] ?? [] }

    func loadDrafts(_ ref: MergeRequestRef) async {
        guard !loadedDrafts.contains(ref.url) else { return }
        loadedDrafts.insert(ref.url)
        let saved = (try? await store.reviewDrafts(mrURL: ref.url)) ?? []
        drafts[ref.url] = (saved + (drafts[ref.url] ?? [])).reduce(into: [ReviewDraft]()) { list, draft in
            if !list.contains(where: { $0.id == draft.id }) { list.append(draft) }
        }
    }

    /// A new thread on lines `first...last` of `side` in `path` of the version on screen.
    @discardableResult
    public func addDraft(_ ref: MergeRequestRef, path: String, side: ReviewSide, first: Int, last: Int, body: String, byAgent: Bool = false) async throws -> ReviewDraft {
        guard let state = states[ref.url] else { throw ExtrasError("Load the merge request's diff first.") }
        guard let file = state.diff.files.first(where: { $0.newPath == path || $0.oldPath == path }) else { throw ExtrasError("\(path) is not in this version of \(ref).") }
        let lines = file.lines
        guard let position = lines.position(refs: state.refs, side: side, first: min(first, last), last: max(first, last)) else {
            throw ExtrasError("\(side == .old ? "Old line" : "Line") \(last) of \(path) is not in the shown diff; GitLab only accepts comments on lines of the diff.")
        }
        return try await saveDraft(
            ReviewDraft(mrURL: ref.url, kind: .newThread(position, lineText: lines.text(side: side, line: max(first, last))), body: try Self.checked(body),
                headSHA: state.refs.headSHA, created: mergeRequests.clock.now(), byAgent: byAgent))
    }

    /// A reply in a discussion (optionally resolving or reopening it when sent).
    @discardableResult
    public func addReply(_ ref: MergeRequestRef, discussionID: String, body: String, resolve: Bool? = nil) async throws -> ReviewDraft {
        guard let state = states[ref.url] else { throw ExtrasError("Load the merge request's diff first.") }
        guard state.discussions.contains(where: { $0.id == discussionID }) else { throw ExtrasError("No discussion \(discussionID) on \(ref).") }
        return try await saveDraft(
            ReviewDraft(mrURL: ref.url, kind: .reply(discussionID: discussionID), body: try Self.checked(body), resolve: resolve, headSHA: state.refs.headSHA, created: mergeRequests.clock.now()))
    }

    public func editDraft(_ draft: ReviewDraft, body: String) async throws {
        var copy = draft
        copy.body = try Self.checked(body)
        try await saveDraft(copy)
    }

    public func discardDraft(_ draft: ReviewDraft) async {
        drafts[draft.mrURL]?.removeAll { $0.id == draft.id }
        try? await store.deleteReviewDraft(id: draft.id)
    }

    /// Restores a discarded draft (Undo).
    public func restoreDraft(_ draft: ReviewDraft) async {
        _ = try? await saveDraft(draft)
    }

    static func checked(_ body: String) throws -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExtrasError("Write a comment first.") }
        guard trimmed.count <= maxDraftBody else { throw ExtrasError("The comment is too long (at most \(maxDraftBody) characters).") }
        return trimmed
    }

    @discardableResult
    private func saveDraft(_ draft: ReviewDraft) async throws -> ReviewDraft {
        var list = drafts[draft.mrURL] ?? []
        if let index = list.firstIndex(where: { $0.id == draft.id }) { list[index] = draft } else {
            guard list.count < ProjectionStore.reviewDraftLimit else {
                throw ExtrasError("This review has \(ProjectionStore.reviewDraftLimit) drafts. Submit or discard some first.")
            }
            list.append(draft)
        }
        drafts[draft.mrURL] = list
        try await store.saveReviewDraft(draft)
        return draft
    }

    /// After loading a new version: drafts written on an older one move only when their line still shows the same
    /// text; the others stay where they were written and are shown as outdated (not sent until re-placed).
    private func reanchorDrafts(_ ref: MergeRequestRef, to diff: ReviewDiffVersion) async {
        for draft in drafts[ref.url] ?? [] where draft.headSHA != diff.version.refs.headSHA {
            if let moved = draft.reanchored(to: diff), moved != draft { _ = try? await saveDraft(moved) }
        }
    }

    /// Whether a draft can be sent with the version on screen (an outdated new-thread draft cannot).
    public func isSendable(_ draft: ReviewDraft) -> Bool {
        guard let refs = states[draft.mrURL]?.refs else { return false }
        if let position = draft.position { return position.refs == refs }
        if let id = draft.discussionID { return states[draft.mrURL]?.discussions.contains { $0.id == id } ?? false }
        return true
    }

    // MARK: Sending

    /// What Submit will do, for the confirmation: how many drafts go, how, and whether the person's other GitLab draft
    /// notes on this MR would be published with them (bulk publish sends all of them).
    public struct SubmitPlan: Hashable, Sendable {
        public var sendable: Int
        public var outdated: Int
        public var asOneReview: Bool
        public var otherServerDrafts: Int
    }

    public func submitPlan(_ ref: MergeRequestRef) -> SubmitPlan {
        let list = drafts(for: ref)
        let sendable = list.filter(isSendable)
        let support = mergeRequests.capabilities(ref.instance).support(.draftNotes)
        return SubmitPlan(
            sendable: sendable.count, outdated: list.count - sendable.count, asOneReview: support.isAvailable,
            otherServerDrafts: support.isAvailable ? states[ref.url]?.serverDrafts?.count ?? 0 : 0)
    }

    /// Sends every sendable draft: as GitLab draft notes then one `bulk_publish` when available, else one by one.
    /// Requires the instance's write switch. Refuses (nothing sent) when the MR moved since the version on screen.
    @discardableResult
    public func submit(_ ref: MergeRequestRef) async throws -> String {
        try mergeRequests.requireWrites(ref.instance)
        guard !busy.contains(ref.url) else { throw ExtrasError("A submit is already running.") }
        let interval = EngineSignposts.gitLab.beginInterval("reviewSubmit")
        defer { EngineSignposts.gitLab.endInterval("reviewSubmit", interval) }
        busy.insert(ref.url)
        defer { busy.remove(ref.url) }
        try await checkNotMoved(ref)
        let sendable = drafts(for: ref).filter(isSendable)
        guard !sendable.isEmpty else { throw ExtrasError("There is nothing to send: write a comment, or re-place outdated drafts.") }
        let message: String
        if mergeRequests.capabilities(ref.instance).support(.draftNotes).mayTry, let sent = try await submitAsReview(ref, sendable) {
            message = sent
        } else {
            message = try await submitIndividually(ref, sendable)
        }
        notices[ref.url] = message
        await load(ref)
        await mergeRequests.refresh(ref)
        return message
    }

    /// GitLab draft notes + bulk publish. Nil when the instance has no draft notes (recorded; the caller falls back).
    private func submitAsReview(_ ref: MergeRequestRef, _ list: [ReviewDraft]) async throws -> String? {
        var created: [Int] = []
        for (index, draft) in list.enumerated() {
            do {
                if let id = try await provider.createDraftNote(ref, payload: Self.draftPayload(draft)) { created.append(id) }
            } catch ForgeError.notFound where index == 0 {
                mergeRequests.recordProbe(ref.instance, .draftNotes, false)
                return nil
            } catch {
                // Take back what was staged so a later attempt does not publish it twice; the local drafts stay.
                for id in created { try? await provider.deleteDraftNote(ref, id: id) }
                throw error
            }
        }
        mergeRequests.recordProbe(ref.instance, .draftNotes, true)
        do {
            try await provider.bulkPublishDraftNotes(ref)
        } catch ForgeError.outcomeUnknown {
            throw ExtrasError("The connection was lost while publishing; GitLab may have published the review. Your drafts are kept: reload before sending again.")
        } catch {
            for id in created { try? await provider.deleteDraftNote(ref, id: id) }
            throw error
        }
        for draft in list { await discardDraft(draft) }
        return "Published \(list.count) comment\(list.count == 1 ? "" : "s") as one review."
    }

    /// One note per draft; each draft is removed as soon as GitLab accepted it.
    private func submitIndividually(_ ref: MergeRequestRef, _ list: [ReviewDraft]) async throws -> String {
        var sent = 0
        for draft in list {
            do {
                try await sendSingle(ref, draft)
                await discardDraft(draft)
                sent += 1
            } catch {
                throw ExtrasError("Sent \(sent) of \(list.count) comments one by one (this instance has no draft reviews); then GitLab refused one: \(ExtrasError.message(error)) The rest are still drafts.")
            }
        }
        return "Sent \(sent) comment\(sent == 1 ? "" : "s") one by one (this GitLab instance does not offer draft reviews, so each was posted separately)."
    }

    func sendSingle(_ ref: MergeRequestRef, _ draft: ReviewDraft) async throws {
        switch draft.kind {
        case .newThread(let position, _):
            _ = try await provider.createDiscussion(ref, payload: GitLabProvider.discussionPayload(body: draft.body, position: position))
        case .general:
            _ = try await provider.createDiscussion(ref, payload: GitLabProvider.discussionPayload(body: draft.body, position: nil))
        case .reply(let id):
            _ = try await provider.reply(ref, discussionID: id, body: draft.body)
            if let resolve = draft.resolve { try await provider.resolve(ref, discussionID: id, resolved: resolve) }
        }
    }

    static func draftPayload(_ draft: ReviewDraft) -> JSONLike {
        switch draft.kind {
        case .newThread(let position, _): GitLabProvider.draftNotePayload(body: draft.body, position: position, discussionID: nil, resolve: nil)
        case .general: GitLabProvider.draftNotePayload(body: draft.body, position: nil, discussionID: nil, resolve: nil)
        case .reply(let id): GitLabProvider.draftNotePayload(body: draft.body, position: nil, discussionID: id, resolve: draft.resolve)
        }
    }

    /// Sends one draft now (the person's explicit "Send Now"): a single note, after the moved check.
    public func sendNow(_ draft: ReviewDraft, ref: MergeRequestRef) async throws {
        try mergeRequests.requireWrites(ref.instance)
        try await checkNotMoved(ref)
        guard isSendable(draft) else { throw ExtrasError("This draft was written on an older version; re-place it on the current diff.") }
        try await sendSingle(ref, draft)
        await discardDraft(draft)
        notices[ref.url] = "Sent 1 comment."
        await load(ref)
    }

    /// Resolves or reopens a discussion at once (an explicit action), after the moved check.
    public func setResolved(_ ref: MergeRequestRef, discussionID: String, _ resolved: Bool) async throws {
        try mergeRequests.requireWrites(ref.instance)
        try await checkNotMoved(ref)
        try await provider.resolve(ref, discussionID: discussionID, resolved: resolved)
        notices[ref.url] = resolved ? "Resolved the thread." : "Reopened the thread."
        await load(ref)
        await mergeRequests.refresh(ref)
    }

    // MARK: Agent context

    /// The composer text for "Add to Agent Context": where the thread is, then its notes quoted as untrusted data.
    /// Throws when the instance's token cannot be read to redact the notes (AV07).
    public func agentContext(_ discussion: ReviewDiscussion, ref: MergeRequestRef) async throws -> String {
        let anchor = states[ref.url].map { ReviewAnchoring.anchor(discussion.position, shown: $0.refs, files: $0.diff.fileLines) } ?? .general
        let place: String = switch anchor {
        case .line(let path, let side, let line, let start): "\(path):\(start.map { "\($0)–" } ?? "")\(line)\(side == .old ? " (old side)" : "")"
        case .file(let path, let reason): "\(path) (\(reason))"
        case .outdated(let position): "\(position.label), outdated (written at head \(position.refs.headSHA.prefix(12)))"
        case .general: "the merge request (general comment)"
        }
        let known = try await mergeRequests.knownSecrets(ref.instance)
        let body = discussion.visibleNotes.map { note in
            "@\(note.author)\(note.created.map { " (\(Self.dateText($0)))" } ?? ""):\n" + UntrustedText.sanitise(note.body, limit: 4_000, known: known)
        }.joined(separator: "\n\n")
        return UntrustedText.composerQuote(
            intro: "Review thread \(discussion.id) on \(ref) at \(place) [\(discussion.stateWord)]. Consider it when you work; the notes below were written on GitLab and are quoted as data:",
            label: "review thread on \(ref), \(place)", body: body.isEmpty ? "(no notes)" : body)
    }

    static func dateText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
