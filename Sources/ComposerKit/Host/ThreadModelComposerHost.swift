import BelloCore
import Engine
import Foundation
import Observation
import UniformTypeIdentifiers

/// The slice of an Engine thread the composer adapter uses. `ThreadModel` conforms; tests use a fake.
@MainActor
public protocol ComposerThreadSource: AnyObject, Observable {
    var sessionID: SessionID { get }
    /// The persisted plain-text draft.
    var draft: String { get set }
    /// `draft` holds the stored value (it is read asynchronously when the thread opens).
    var isDraftLoaded: Bool { get }
    var isRunning: Bool { get }
    var isStopping: Bool { get }
    var composerErrorMessage: String? { get }
    /// The last send's delivery is unknown (kept by the thread for a same-ID retry), not failed.
    var composerDeliveryUnknown: Bool { get }
    /// Earlier user prompts, oldest first.
    var composerPromptHistory: [String] { get }
    /// Sends `text`. The composer always passes its submission's text: the source must not clear or restore `draft`
    /// for it (the composer cleared its own submitted revision and restores a failed send itself; R4-01).
    func send(_ text: String?, attachments: PromptAttachments, delivery: PromptDelivery?) async -> MessageID?
    /// Runs a server slash command; true when the server accepted it.
    func runCommand(_ name: String, arguments: String, attachments: PromptAttachments, delivery: PromptDelivery?) async -> Bool
    func stop() async
    func clearError()
}

extension ComposerThreadSource {
    public var isDraftLoaded: Bool { true }
    public var composerDeliveryUnknown: Bool { false }
}

extension ThreadModel: ComposerThreadSource {
    public var composerErrorMessage: String? { lastError?.userMessage }
    public var composerDeliveryUnknown: Bool { lastError == .deliveryUnknown }

    public var composerPromptHistory: [String] {
        messageIDs.compactMap { id in
            guard case .user(let content) = message(id)?.message.kind else { return nil }
            return content.text
        }
    }
}

/// Rich draft state (tokens, attachments, selection) that the Engine does not persist, kept per thread in memory and
/// bounded. Used only while its text still matches the thread's persisted draft.
///
/// Entries are scoped to the source that stored them (a thread model) as well as to the key (the session ID): two
/// sources with the same session ID (two engines in one process, as in tests that run the same mock fixture side by
/// side) never replace each other's rich state. A source without an entry of its own (a thread model reopened after
/// eviction) gets the newest entry for the key whose text matches.
@MainActor
public final class ComposerDraftCache {
    public static let shared = ComposerDraftCache()
    public let capacity: Int

    struct Key: Hashable {
        var key: String
        var owner: ObjectIdentifier?
    }

    private var drafts: [Key: ComposerDraft] = [:]
    /// Least recently stored first.
    private var order: [Key] = []

    public init(capacity: Int = 64) {
        self.capacity = capacity
    }

    /// The newest draft stored for `key`, by any owner.
    public func draft(for key: String) -> ComposerDraft? {
        order.last { $0.key == key }.flatMap { drafts[$0] }
    }

    /// The draft `owner` stored for `key` if its text is `text`; else the newest one for `key` with that text.
    public func draft(for key: String, owner: ObjectIdentifier?, matching text: String) -> ComposerDraft? {
        if let own = drafts[Key(key: key, owner: owner)], own.text == text { return own }
        for candidate in order.reversed() where candidate.key == key {
            if let draft = drafts[candidate], draft.text == text { return draft }
        }
        return nil
    }

    public func store(_ draft: ComposerDraft, for key: String, owner: ObjectIdentifier? = nil) {
        let entry = Key(key: key, owner: owner)
        drafts[entry] = draft
        order.removeAll { $0 == entry }
        order.append(entry)
        while order.count > capacity { drafts[order.removeFirst()] = nil }
    }
}

/// The one revision of a thread's stored draft (R3-01), shared by every host of that thread (each window makes its
/// own host; Edit from Here makes another). Bumped by every save through any of them, and when the thread's text
/// changed some other way (a send clearing it, a failed send restoring it, the stored draft arriving), which is seen by
/// comparing it with the text of the last revision. Observable, so the other composers of the thread follow a save
/// that changed only attachments or tokens.
@MainActor
@Observable
final class ComposerDraftRevision {
    /// Process-wide, so a revision number is never reused for a draft (no ABA after a thread model is replaced).
    private static var next = 0
    private(set) var value: Int
    @ObservationIgnored private var text: String
    /// An edit a composer handed over before the stored draft was read (`ThreadModelComposerHost.saveDraft` while
    /// not loaded). Joined with the stored rich draft on the first load; never written over it.
    @ObservationIgnored var editBeforeLoad: ComposerDraft?

    init(text: String) {
        self.text = text
        value = Self.mint()
    }

    private static func mint() -> Int {
        next += 1
        return next
    }

    /// The current revision for the source's current text.
    func current(text: String) -> Int {
        if text != self.text { bump(text: text) }
        return value
    }

    func bump(text: String) {
        self.text = text
        value = Self.mint()
    }

    /// One per source object, released with it (weak keys).
    private static let bySource = NSMapTable<AnyObject, ComposerDraftRevision>.weakToStrongObjects()

    static func of(_ source: any ComposerThreadSource) -> ComposerDraftRevision {
        if let existing = bySource.object(forKey: source) { return existing }
        let created = ComposerDraftRevision(text: source.draft)
        bySource.setObject(created, forKey: source)
        return created
    }
}

/// Adapts an Engine `ThreadModel` (or any `ComposerThreadSource`) to `ComposerHost`.
///
/// A send becomes opencode prompt input (`PromptSubmissionMapper`): attachments as `file://` URIs (pasted images and
/// large pastes are written to `fileStore` first), `@` file tokens as file mentions, agent and skill tokens as their
/// mentions, and a leading `/command` token as a server command run with the rest as its arguments.
@MainActor
public final class ThreadModelComposerHost: ComposerHost {
    public let source: any ComposerThreadSource
    public var defaultFollowUp: ComposerDelivery
    public let fileStore: AttachmentFileStore
    private let cache: ComposerDraftCache
    /// Where the draft's attachments and tokens survive a relaunch (R28); nil keeps them in memory only (tests).
    public let archive: ComposerDraftArchive?

    public init(
        _ source: any ComposerThreadSource, defaultFollowUp: ComposerDelivery = .queue, cache: ComposerDraftCache? = nil,
        fileStore: AttachmentFileStore = .applicationDefault, archive: ComposerDraftArchive? = nil
    ) {
        self.source = source
        self.defaultFollowUp = defaultFollowUp
        self.cache = cache ?? .shared
        self.fileStore = fileStore
        self.archive = archive
    }

    public var draftKey: String { source.sessionID.rawValue }
    public var draftOwner: ObjectIdentifier? { ObjectIdentifier(source) }
    public var isDraftLoaded: Bool { source.isDraftLoaded }
    private var revision: ComposerDraftRevision { ComposerDraftRevision.of(source) }
    public var draftRevision: Int { revision.current(text: source.draft) }

    public func loadDraft() -> ComposerDraft {
        let text = source.draft
        if isDraftLoaded, let edit = revision.editBeforeLoad {
            revision.editBeforeLoad = nil
            let joined = Self.join(stored: storedCandidates(text: text, edit: edit), edit: edit, text: text)
            cache.store(joined, for: draftKey, owner: ObjectIdentifier(source))
            if let archive, ComposerDraftArchive.needsRecord(joined) || archive.load(draftKey) != nil {
                archive.save(joined, for: draftKey)
            }
            return joined
        }
        if let cached = cache.draft(for: draftKey, owner: ObjectIdentifier(source), matching: text) { return cached }
        // After a relaunch: the staged attachments and pills recorded with the draft (R28).
        if isDraftLoaded, let restored = archive?.restore(draftKey, text: text) {
            cache.store(restored, for: draftKey, owner: ObjectIdentifier(source))
            return restored
        }
        return ComposerDraft(text: text)
    }

    public func saveDraft(_ draft: ComposerDraft) {
        // Not read yet: the stored draft (and its archived mentions and attachments) is not known, so nothing may be
        // written over it (AV2-02). The edit is handed over to be joined with it when it loads.
        guard isDraftLoaded else { return handOverBeforeLoad(draft) }
        let previous = cache.draft(for: draftKey)
        cache.store(draft, for: draftKey, owner: ObjectIdentifier(source))
        if source.draft != draft.text { source.draft = draft.text }
        revision.bump(text: source.draft)
        if let archive, ComposerDraftArchive.needsRecord(draft) || previous.map(ComposerDraftArchive.needsRecord) ?? true {
            archive.save(draft, for: draftKey)
        }
    }

    /// A composer left before the stored draft was read and hands over what was typed meanwhile. The thread gets the
    /// text (it joins it after the stored text when that arrives, `ThreadModel.mergeDrafts`); the cache and the archive
    /// are left alone, so the stored rich record survives; the edit's own tokens and attachments wait in the revision
    /// and are joined with the stored rich draft by the first `loadDraft()` after it loads.
    private func handOverBeforeLoad(_ edit: ComposerDraft) {
        guard !edit.isEmpty else { return }
        // A second hand-over (another composer, or the same one after more typing) keeps the first: a composer hands
        // over all it shows, so an edit that already holds the earlier one replaces it; otherwise both are kept.
        let pending = revision.editBeforeLoad.map { earlier in
            edit.containsRestored(earlier) ? edit : ComposerDraft.merging(failed: earlier, current: edit)
        } ?? edit
        revision.editBeforeLoad = pending
        if source.draft != pending.text { source.draft = pending.text }
        revision.bump(text: source.draft)
    }

    /// The stored drafts that, joined with `edit` the way the thread joins text, could have produced `text`: the
    /// archived rich record first, then the plain stored text implied by the join.
    private func storedCandidates(text: String, edit: ComposerDraft) -> [ComposerDraft] {
        var candidates: [ComposerDraft] = []
        if let archive, let record = archive.load(draftKey), let rich = archive.restore(draftKey, text: record.text) {
            candidates.append(rich)
        }
        let suffix = "\n\n" + edit.text
        let joined = text as NSString
        if joined.hasSuffix(suffix) {
            candidates.append(ComposerDraft(text: joined.substring(to: joined.length - (suffix as NSString).length)))
        }
        candidates.append(ComposerDraft(text: ""))
        return candidates
    }

    /// The rich draft for the thread's joined `text`: a stored candidate whose join with `edit` gives exactly `text`
    /// (stored first, then the edit, as `ThreadModel.mergeDrafts` joins them), keeping both drafts' tokens and
    /// attachments. When none matches (the text changed some other way), the text with the edit's attachments.
    static func join(stored candidates: [ComposerDraft], edit: ComposerDraft, text: String) -> ComposerDraft {
        func adding(_ attachments: [ComposerAttachment], to draft: ComposerDraft) -> ComposerDraft {
            var draft = draft
            let known = Set(draft.attachments.map(\.id))
            draft.attachments += attachments.filter { !known.contains($0.id) }
            return draft
        }
        for stored in candidates {
            let joined = ComposerDraft.merging(failed: stored, current: edit)
            if joined.text == text { return joined.validated() }
            // The edit was empty or the same text: the stored draft.
            if stored.text == text { return adding(edit.attachments, to: stored).validated() }
            // Nothing was stored, or the edit already extends it: the edit.
            if edit.text == text, edit.text.hasPrefix(stored.text) { return adding(stored.attachments, to: edit).validated() }
        }
        return ComposerDraft(text: text, attachments: edit.attachments).validated()
    }

    public func send(_ submission: ComposerSubmission) async -> ComposerSendOutcome {
        let delivery: PromptDelivery? = switch submission.delivery {
        case .now: nil
        case .queue: .queue
        case .steer: .steer
        }
        let input: PromptSubmissionMapper.Input
        do {
            input = try await PromptSubmissionMapper.map(submission, store: fileStore)
        } catch {
            return .failed("An attachment could not be prepared: \(error.localizedDescription)")
        }
        if let command = input.command {
            if await source.runCommand(command.name, arguments: input.text, attachments: input.attachments, delivery: delivery) {
                return .accepted
            }
            return .failed(source.composerErrorMessage ?? "The command was not run.")
        }
        // The composer already cleared the submitted revision (a compare-and-swap on the revision it showed). Dispatch
        // clears nothing: by now the stored draft can be a newer revision another window saved, possibly with the same
        // text, and only the submitted revision's clear belongs to this send (R4-01).
        if await source.send(input.text, attachments: input.attachments, delivery: delivery) != nil { return .accepted }
        if source.composerDeliveryUnknown {
            return .unconfirmed(source.composerErrorMessage ?? "Delivery unknown: opencode did not confirm it received this message.")
        }
        return .failed(source.composerErrorMessage ?? "The message was not sent.")
    }

    public func stop() async { await source.stop() }

    public var runState: ComposerRunState {
        if source.isStopping { return .stopping }
        return source.isRunning ? .running : .idle
    }

    public var supportsAttachments: Bool { true }
    public var errorMessage: String? { source.composerErrorMessage }
    public func clearError() { source.clearError() }
    public func recentPrompts() -> [String] { source.composerPromptHistory }

    public func observe(_ onChange: @escaping @MainActor () -> Void) -> ComposerObservation {
        let tracker = ObservationTracker(source: source, revision: revision, onChange: onChange)
        tracker.arm()
        return ComposerObservation { tracker.active = false }
    }
}

/// Turns a composer submission into opencode prompt input. Pure except for writing in-memory attachments to files.
public enum PromptSubmissionMapper {
    public struct Input: Hashable, Sendable {
        /// The prompt text, or the command's argument text when `command` is set.
        public var text: String
        public var attachments: PromptAttachments
        public var command: (name: String, token: ComposerToken)? {
            get { commandToken.map { ($0.value, $0) } }
            set { commandToken = newValue?.token }
        }
        var commandToken: ComposerToken?
    }

    public static func map(_ submission: ComposerSubmission, store: AttachmentFileStore) async throws -> Input {
        var text = submission.text
        var tokens = submission.tokens.sorted { $0.location < $1.location }
        var commandToken: ComposerToken?
        // A command token at the start of the prompt: run it with the rest as arguments; shift later mentions.
        if let first = tokens.first, first.token.kind == .command,
           (text as NSString).substring(to: first.location).allSatisfy(\.isWhitespace)
        {
            commandToken = first.token
            let rest = (text as NSString).substring(from: first.location + first.length)
            let trimmed = String(rest.drop { $0 == " " || $0 == "\t" })
            let shift = first.location + first.length + ((rest as NSString).length - (trimmed as NSString).length)
            text = trimmed
            tokens = tokens.dropFirst().map { placed in
                PlacedToken(token: placed.token, range: NSRange(location: placed.location - shift, length: placed.length))
            }
        }
        var attachments = PromptAttachments()
        for placed in tokens {
            let mention = PromptAttachments.Mention(
                start: placed.location, end: placed.location + placed.length, text: placed.token.text)
            switch placed.token.kind {
            case .file:
                let url = URL(filePath: placed.token.value)
                attachments.files.append(
                    PromptAttachments.File(
                        uri: url.absoluteString, name: url.lastPathComponent, mime: mimeType(for: url), mention: mention))
            case .agent:
                attachments.agents.append(PromptAttachments.Agent(name: placed.token.value, mention: mention))
            case .skill:
                attachments.skills.append(PromptAttachments.Skill(id: placed.token.value, mention: mention))
            case .command, .other:
                continue
            }
        }
        for attachment in submission.attachments {
            let url = try await store.materialize(attachment)
            attachments.files.append(
                PromptAttachments.File(uri: url.absoluteString, name: attachment.name, mime: attachment.mimeType))
        }
        return Input(text: text, attachments: attachments, commandToken: commandToken)
    }

    static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "text/plain"
    }
}

/// Re-arms `withObservationTracking` after each change, until deactivated.
@MainActor
private final class ObservationTracker {
    let source: any ComposerThreadSource
    let revision: ComposerDraftRevision
    let onChange: @MainActor () -> Void
    var active = true

    init(source: any ComposerThreadSource, revision: ComposerDraftRevision, onChange: @escaping @MainActor () -> Void) {
        self.source = source
        self.revision = revision
        self.onChange = onChange
    }

    func arm() {
        guard active else { return }
        withObservationTracking {
            _ = source.isRunning
            _ = source.isStopping
            _ = source.isDraftLoaded
            _ = source.composerErrorMessage
            // The stored draft: its text, and the revision (a save that changed only attachments or tokens).
            _ = source.draft
            _ = revision.value
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.active else { return }
                self.onChange()
                self.arm()
            }
        }
    }
}
