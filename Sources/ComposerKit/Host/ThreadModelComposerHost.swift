import BelloCore
import Engine
import Foundation
import Observation

/// The slice of an Engine thread the composer adapter uses. `ThreadModel` conforms; tests use a fake.
@MainActor
public protocol ComposerThreadSource: AnyObject, Observable {
    var sessionID: SessionID { get }
    /// The persisted plain-text draft.
    var draft: String { get set }
    var isRunning: Bool { get }
    var isStopping: Bool { get }
    var composerErrorMessage: String? { get }
    /// Earlier user prompts, oldest first.
    var composerPromptHistory: [String] { get }
    func send(_ text: String?, delivery: PromptDelivery?) async -> MessageID?
    func stop() async
    func clearError()
}

extension ThreadModel: ComposerThreadSource {
    public var composerErrorMessage: String? { lastError?.userMessage }

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
/// Attachments: `ThreadModel.send` takes text only, so `supportsAttachments` is false and the composer refuses such a
/// send visibly (the draft stays). See docs/features/composer.md for what the prompt request needs.
@MainActor
public final class ThreadModelComposerHost: ComposerHost {
    public let source: any ComposerThreadSource
    public var defaultFollowUp: ComposerDelivery
    private let cache: ComposerDraftCache

    public init(_ source: any ComposerThreadSource, defaultFollowUp: ComposerDelivery = .queue, cache: ComposerDraftCache? = nil) {
        self.source = source
        self.defaultFollowUp = defaultFollowUp
        self.cache = cache ?? .shared
    }

    public var draftKey: String { source.sessionID.rawValue }

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
        guard submission.attachments.isEmpty else {
            return .failed("This thread can't take attachments yet.")
        }
        let delivery: PromptDelivery? = switch submission.delivery {
        case .now: nil
        case .queue: .queue
        case .steer: .steer
        }
        if await source.send(submission.text, delivery: delivery) != nil { return .accepted }
        return .failed(source.composerErrorMessage ?? "The message was not sent.")
    }

    public func stop() async { await source.stop() }

    public var runState: ComposerRunState {
        if source.isStopping { return .stopping }
        return source.isRunning ? .running : .idle
    }

    public var supportsAttachments: Bool { false }
    public var errorMessage: String? { source.composerErrorMessage }
    public func clearError() { source.clearError() }
    public func recentPrompts() -> [String] { source.composerPromptHistory }

    public func observe(_ onChange: @escaping @MainActor () -> Void) -> ComposerObservation {
        let tracker = ObservationTracker(source: source, onChange: onChange)
        tracker.arm()
        return ComposerObservation { tracker.active = false }
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
