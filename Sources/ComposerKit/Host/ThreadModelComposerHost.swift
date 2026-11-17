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
@MainActor
public final class ComposerDraftCache {
    public static let shared = ComposerDraftCache()
    public let capacity: Int
    private var drafts: [String: ComposerDraft] = [:]
    private var order: [String] = []

    public init(capacity: Int = 64) {
        self.capacity = capacity
    }

    public func draft(for key: String) -> ComposerDraft? { drafts[key] }

    public func store(_ draft: ComposerDraft, for key: String) {
        drafts[key] = draft
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity { drafts[order.removeFirst()] = nil }
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

    public init(
        _ source: any ComposerThreadSource, defaultFollowUp: ComposerDelivery = .queue, cache: ComposerDraftCache? = nil,
        fileStore: AttachmentFileStore = .applicationDefault
    ) {
        self.source = source
        self.defaultFollowUp = defaultFollowUp
        self.cache = cache ?? .shared
        self.fileStore = fileStore
    }

    public var draftKey: String { source.sessionID.rawValue }
    public var isDraftLoaded: Bool { source.isDraftLoaded }

    public func loadDraft() -> ComposerDraft {
        let text = source.draft
        if let cached = cache.draft(for: draftKey), cached.text == text { return cached }
        return ComposerDraft(text: text)
    }

    public func saveDraft(_ draft: ComposerDraft) {
        cache.store(draft, for: draftKey)
        if source.draft != draft.text { source.draft = draft.text }
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
        let tracker = ObservationTracker(source: source, onChange: onChange)
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
    let onChange: @MainActor () -> Void
    var active = true

    init(source: any ComposerThreadSource, onChange: @escaping @MainActor () -> Void) {
        self.source = source
        self.onChange = onChange
    }

    func arm() {
        guard active else { return }
        withObservationTracking {
            _ = source.isRunning
            _ = source.isStopping
            _ = source.isDraftLoaded
            _ = source.composerErrorMessage
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.active else { return }
                self.onChange()
                self.arm()
            }
        }
    }
}
