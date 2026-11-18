import AppKit
import BelloCore
import Engine
import Foundation
import Observation

/// The review screen's state for one merge request (GitLab 2, docs/features/gitlab.md "Inline review"): turns the
/// loaded version into diff files and inline threads, offers the actions each thread allows (writes gated per
/// instance), and runs them through `MergeRequestReviewService`. Every action is bound to the version on screen: when
/// the MR moved, nothing is sent; the new version is loaded and the person is told what happened to their drafts.
@MainActor
@Observable
public final class MergeRequestReviewModel {
    public let ref: MergeRequestRef
    public let service: MergeRequestReviewService
    /// Shown below the toolbar ("Published 3 comments as one review.", errors). Not cleared by reloads.
    public private(set) var message: String?
    public private(set) var isError = false
    @ObservationIgnored public var now: () -> Date = Date.init
    /// Inserts text into the thread's composer (the person sends it). Nil when no composer is shown.
    @ObservationIgnored public var insertIntoComposer: ((String) -> Void)?
    @ObservationIgnored public var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Asks to confirm (title, detail, button) → true to go on.
    @ObservationIgnored public var confirm: (String, String, String) -> Bool = { _, _, _ in true }

    public init(ref: MergeRequestRef, service: MergeRequestReviewService) {
        self.ref = ref
        self.service = service
    }

    public var state: ReviewState? { service.states[ref.url] }
    public var phase: MergeRequestReviewService.Phase { service.phases[ref.url] ?? .idle }
    public var drafts: [ReviewDraft] { service.drafts(for: ref) }
    public var writesEnabled: Bool { service.mergeRequests.settings(for: ref.instance).writesEnabled }
    public var snapshot: MergeRequestSnapshot? { service.mergeRequests.snapshots[ref.url] }

    public func load() async {
        await service.load(ref)
    }

    // MARK: Presentation

    /// "Version 2 of 2 · head 9f2c1ab4e5d6 · loaded 10:42".
    public var versionLine: String {
        guard let state else { return phase == .preparing ? "GitLab is preparing the diff…" : "Loading the diff…" }
        let count = state.diff.count
        let id = state.diff.version.id
        let label = id > 0 && count > 0 ? "Version \(count) of \(count)" : "Latest version"
        return "\(label) · head \(state.refs.headSHA.prefix(12))" + (state.diff.incomplete ? " · some files not loaded" : "")
    }

    /// The version's files for the diff view.
    public var diffFiles: [DiffFile] {
        guard let state else { return [] }
        return state.diff.files.map { file in
            var diff = DiffFile.from(file.patch)
            if file.renamedFile { diff.oldPath = file.oldPath }
            if file.tooLarge, diff.hunks.isEmpty { diff.content = .binary }
            return diff
        }
    }

    /// Threads and drafts to show inline. Threads on files not in this version (and general comments) are counted
    /// in `elsewhere`, not placed.
    public var annotations: [DiffAnnotation] {
        guard let state else { return [] }
        let paths = Set(state.diff.files.flatMap { [$0.newPath, $0.oldPath] })
        let byDiscussion = Dictionary(grouping: drafts.filter { $0.discussionID != nil }, by: { $0.discussionID! })
        var list: [DiffAnnotation] = []
        for (discussion, anchor) in state.anchored {
            guard let path = anchor.path, paths.contains(path) else { continue }
            let replies = byDiscussion[discussion.id] ?? []
            var notes = discussion.visibleNotes.map { DiffAnnotation.Note(author: $0.author, time: relative($0.created), body: $0.body + ($0.bodyTruncated ? "\n…" : "")) }
            notes += replies.map { DiffAnnotation.Note(author: "you", time: relative($0.created), body: $0.body + ($0.resolve == true ? "\n(resolves the thread when sent)" : ""), isDraft: true) }
            let primary: DiffAnnotation.State = !discussion.isResolvable ? .comment : discussion.isResolved ? .resolved : .unresolved
            var outdated = false
            let placement: DiffAnnotation.Placement
            var note: String?
            switch anchor {
            case .line(let path, let side, let line, let start):
                placement = .line(path: path, side: side == .old ? .old : .new, line: line)
                if let start { note = "Lines \(start)–\(line)" }
            case .file(let path, let reason):
                placement = .file(path: path)
                note = reason
            case .outdated(let position):
                placement = .file(path: position.path)
                outdated = true
                note = ReviewAnchor.outdated(position).note
            case .general:
                continue
            }
            list.append(
                DiffAnnotation(
                    id: discussion.id, placement: placement, state: DiffAnnotationStateSet(primary, outdated: outdated, hasDraft: !replies.isEmpty), note: note,
                    notes: notes))
        }
        for draft in drafts {
            guard case .newThread(let position, _) = draft.kind, paths.contains(position.path) || paths.contains(position.oldPath) else { continue }
            let anchor = ReviewAnchoring.anchor(position, shown: state.refs, files: state.diff.fileLines)
            let placement: DiffAnnotation.Placement
            var note: String? = draft.byAgent ? "Written by the agent" : nil
            var outdated = false
            switch anchor {
            case .line(let path, let side, let line, let start):
                placement = .line(path: path, side: side == .old ? .old : .new, line: line)
                if let start { note = [note, "Lines \(start)–\(line)"].compactMap { $0 }.joined(separator: " · ") }
            default:
                placement = .file(path: position.path)
                outdated = true
                note = "Written on head \(position.refs.headSHA.prefix(12)) at \(position.label); that line changed, so it will not be sent. Copy it to a current line or discard it."
            }
            list.append(
                DiffAnnotation(
                    id: draft.id, placement: placement, state: DiffAnnotationStateSet(outdated ? .outdated : .draft, outdated: outdated, hasDraft: true), note: note,
                    notes: [DiffAnnotation.Note(author: draft.byAgent ? "agent" : "you", time: relative(draft.created), body: draft.body, isDraft: true)]))
        }
        return list
    }

    /// Threads not placed in the diff: general comments and threads on files not in this version.
    public var elsewhere: Int {
        guard let state else { return 0 }
        let paths = Set(state.diff.files.flatMap { [$0.newPath, $0.oldPath] })
        return state.anchored.filter { $0.anchor.path.map { !paths.contains($0) } ?? true }.count
    }

    func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        if abs(date.timeIntervalSince(now())) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now())
    }

    public var submitTitle: String {
        let plan = service.submitPlan(ref)
        return plan.sendable == 0 ? "Submit Review" : "Submit Review (\(plan.sendable))"
    }

    // MARK: Actions on a thread

    public func actions(for annotation: DiffAnnotation) -> [DiffAnnotationAction] {
        let writes = writesEnabled
        if let draft = drafts.first(where: { $0.id == annotation.id }) {
            return [
                DiffAnnotationAction(id: "edit", title: "Edit Draft…"),
                DiffAnnotationAction(id: "send", title: writes ? "Send Now" : "Send Now (writes are off)", isEnabled: writes && service.isSendable(draft)),
                DiffAnnotationAction(id: "discard", title: "Discard Draft"),
            ]
        }
        guard let discussion = state?.discussions.first(where: { $0.id == annotation.id }) else { return [] }
        var list = [DiffAnnotationAction(id: "reply", title: "Reply…")]
        if discussion.isResolvable {
            let title = discussion.isResolved ? "Reopen Thread" : "Resolve Thread"
            list.append(DiffAnnotationAction(id: "resolve", title: writes ? title : title + " (writes are off)", isEnabled: writes))
        }
        if drafts.contains(where: { $0.discussionID == discussion.id }) {
            list.append(DiffAnnotationAction(id: "discardReply", title: "Discard Draft Reply"))
        }
        list.append(DiffAnnotationAction(id: "agent", title: "Add to Agent Context", isEnabled: insertIntoComposer != nil))
        list.append(DiffAnnotationAction(id: "open", title: "Open in GitLab"))
        return list
    }

    /// Runs an action that needs no text (reply and edit need the editor: `beginReply` / `beginEdit`).
    public func perform(_ action: DiffAnnotationAction, on annotation: DiffAnnotation) async {
        switch action.id {
        case "resolve":
            guard let discussion = state?.discussions.first(where: { $0.id == annotation.id }) else { return }
            await run { try await self.service.setResolved(self.ref, discussionID: discussion.id, !discussion.isResolved) }
        case "send":
            guard let draft = drafts.first(where: { $0.id == annotation.id }) else { return }
            await run { try await self.service.sendNow(draft, ref: self.ref) }
        case "discard":
            guard let draft = drafts.first(where: { $0.id == annotation.id }) else { return }
            await service.discardDraft(draft)
            lastDiscarded = [draft]
            show("Discarded the draft. Undo with ⌘Z.", error: false)
        case "discardReply":
            let replies = drafts.filter { $0.discussionID == annotation.id }
            for draft in replies { await service.discardDraft(draft) }
            lastDiscarded = replies
            show("Discarded the draft reply. Undo with ⌘Z.", error: false)
        case "agent":
            guard let discussion = state?.discussions.first(where: { $0.id == annotation.id }) else { return }
            guard let insert = insertIntoComposer else { return show("Open the thread's composer to add the thread as context.", error: true) }
            insert(service.agentContext(discussion, ref: ref))
            show("The thread is in the composer, quoted as GitLab content: review it and send.", error: false)
        case "open":
            if let url = URL(string: ref.url + (state?.discussions.contains { $0.id == annotation.id } == true ? "#note_\(firstNoteID(annotation.id) ?? 0)" : "")) { openURL(url) }
        default:
            break
        }
    }

    /// Drafts discarded last (Undo restores them).
    public private(set) var lastDiscarded: [ReviewDraft] = []

    public func undoDiscard() async {
        let drafts = lastDiscarded
        lastDiscarded = []
        for draft in drafts { await service.restoreDraft(draft) }
        if !drafts.isEmpty { show("Restored \(drafts.count == 1 ? "the draft" : "\(drafts.count) drafts").", error: false) }
    }

    func firstNoteID(_ discussionID: String) -> Int? { state?.discussions.first { $0.id == discussionID }?.notes.first?.id }

    public func reply(to annotation: DiffAnnotation, text: String, resolve: Bool? = nil) async {
        await run { try await self.service.addReply(self.ref, discussionID: annotation.id, body: text, resolve: resolve) }
        if !isError { show("Reply saved as a draft. Submit Review sends it.", error: false) }
    }

    public func edit(_ annotation: DiffAnnotation, text: String) async {
        guard let draft = drafts.first(where: { $0.id == annotation.id }) else { return }
        await run { try await self.service.editDraft(draft, body: text) }
    }

    public func draftText(_ annotation: DiffAnnotation) -> String { drafts.first { $0.id == annotation.id }?.body ?? "" }

    /// A new comment on the selected lines (from the diff's comment popover).
    public func comment(_ comment: DiffReviewComment) async {
        await run {
            try await self.service.addDraft(
                self.ref, path: comment.path, side: comment.side == .old ? .old : .new, first: comment.startLine, last: comment.endLine, body: comment.text)
        }
        if !isError { show("Comment saved as a draft. Submit Review sends it.", error: false) }
    }

    // MARK: Submit

    public func submit() async {
        let plan = service.submitPlan(ref)
        guard plan.sendable > 0 else {
            return show(plan.outdated > 0 ? "Only outdated drafts are left: re-place them on current lines or discard them." : "There are no drafts to send.", error: true)
        }
        var detail = "\(plan.sendable) comment\(plan.sendable == 1 ? "" : "s") on \(ref) at head \(state?.refs.headSHA.prefix(12) ?? "?")"
        detail += plan.asOneReview ? ", published together as one review." : ", posted one by one (this instance does not offer draft reviews)."
        if plan.otherServerDrafts > 0 {
            detail += " GitLab also holds \(plan.otherServerDrafts) other draft comment\(plan.otherServerDrafts == 1 ? "" : "s") of yours on this merge request (written elsewhere); publishing sends them too."
        }
        if plan.outdated > 0 { detail += " \(plan.outdated) outdated draft\(plan.outdated == 1 ? " stays" : "s stay") here." }
        guard confirm("Submit review?", detail, "Submit") else { return }
        await run {
            let message = try await self.service.submit(self.ref)
            self.show(message, error: false)
        }
    }

    public func discardAllDrafts() async {
        let all = drafts
        guard !all.isEmpty else { return }
        for draft in all { await service.discardDraft(draft) }
        lastDiscarded = all
        show("Discarded \(all.count) draft\(all.count == 1 ? "" : "s"). Undo with ⌘Z.", error: false)
    }

    private func run(_ body: @escaping () async throws -> Void) async {
        do {
            try await body()
            isError = false
        } catch let moved as ReviewMovedError {
            // Refresh and ask: nothing was sent; the new version is shown and the drafts were re-checked.
            await service.load(ref)
            let outdated = service.submitPlan(ref).outdated
            show(
                "\(moved.description) The new version is now shown\(outdated > 0 ? "; \(outdated) draft\(outdated == 1 ? " is" : "s are") outdated" : ""). Check it, then act again.",
                error: true)
        } catch {
            show(ExtrasError.message(error), error: true)
        }
    }

    func show(_ text: String, error: Bool) {
        message = text
        isError = error
    }

    public func clearMessage() { message = nil }
}
