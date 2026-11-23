import Foundation

/// What the composer hands the host when the user sends.
public struct ComposerSubmission: Hashable, Sendable {
    /// The prompt as plain text; tokens appear as their text form (`@path`, `/command`).
    public var text: String
    /// Tokens with UTF-16 ranges into `text` (opencode's `Prompt.Mention` uses start/end offsets).
    public var tokens: [PlacedToken]
    public var attachments: [ComposerAttachment]
    public var delivery: ComposerDelivery

    public init(text: String, tokens: [PlacedToken], attachments: [ComposerAttachment], delivery: ComposerDelivery) {
        self.text = text
        self.tokens = tokens
        self.attachments = attachments
        self.delivery = delivery
    }
}

/// The host's answer to a send. `accepted` means the server admitted the prompt; nothing earlier may claim delivery.
public enum ComposerSendOutcome: Hashable, Sendable {
    case accepted
    /// Not sent. The composer puts the draft back and shows `message` inline.
    case failed(String)
    /// Every answer was lost: it may or may not have been admitted. The host keeps it (with its ID) and offers an
    /// explicit check/retry; the composer stays clear (restoring the text would invite a duplicate) and shows `message`.
    case unconfirmed(String)
}

public enum ComposerRunState: Hashable, Sendable {
    case idle
    case running
    /// Stop was requested; the server has not confirmed.
    case stopping
}

/// Cancels a host observation when released or cancelled.
@MainActor
public final class ComposerObservation {
    private var onCancel: (() -> Void)?

    public init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        onCancel?()
        onCancel = nil
    }

    isolated deinit { cancel() }
}

/// Everything the composer needs from the thread it edits. The shell provides one per thread
/// (`ThreadModelComposerHost` for an Engine `ThreadModel`); tests and the demo use fakes.
@MainActor
public protocol ComposerHost: AnyObject {
    /// Identity of the thread, for keeping per-thread state apart.
    var draftKey: String { get }
    /// The object that stores the draft (a thread model), shared by every host of that thread; nil when the host is
    /// the only one. A failed send restores its text into every live composer whose host has the same owner (NF04).
    var draftOwner: ObjectIdentifier? { get }
    /// The saved draft. Called when the composer shows this host, and again when `isDraftLoaded` becomes true.
    func loadDraft() -> ComposerDraft
    /// The saved draft has been read. While false, `loadDraft()` is a placeholder: the composer saves nothing over it
    /// and reconciles (merging anything typed meanwhile) once it turns true. Report the change through `observe`.
    var isDraftLoaded: Bool { get }
    /// Persist the draft. Called debounced while typing, and at once on send, thread switch and teardown.
    func saveDraft(_ draft: ComposerDraft)
    /// Send, queue or steer. Return only when the server admitted the prompt or the attempt failed.
    func send(_ submission: ComposerSubmission) async -> ComposerSendOutcome
    /// Stop the running turn.
    func stop() async
    var runState: ComposerRunState { get }
    /// The host can deliver at the next step of a running turn.
    var supportsSteer: Bool { get }
    /// The host can send attachments. When false, a send with attachments fails visibly instead of dropping them.
    var supportsAttachments: Bool { get }
    /// What a plain send does while running (queue unless the user changed the setting).
    var defaultFollowUp: ComposerDelivery { get }
    /// The last error from a host command (for example a failed stop), shown inline.
    var errorMessage: String? { get }
    func clearError()
    /// Earlier prompts in this thread, oldest first, for Up/Down recall.
    func recentPrompts() -> [String]
    /// Calls `onChange` (on the main actor) after `runState`, `errorMessage`, `isDraftLoaded` or capabilities change.
    func observe(_ onChange: @escaping @MainActor () -> Void) -> ComposerObservation
}

extension ComposerHost {
    public var draftOwner: ObjectIdentifier? { nil }
    public var isDraftLoaded: Bool { true }
    public var supportsSteer: Bool { true }
    public var supportsAttachments: Bool { true }
    public var defaultFollowUp: ComposerDelivery { .queue }
    public var errorMessage: String? { nil }
    public func clearError() {}
    public func recentPrompts() -> [String] { [] }
}
