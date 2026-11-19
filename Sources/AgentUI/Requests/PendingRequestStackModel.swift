import BelloCore
import Engine
import Foundation
import Observation

/// What the request stack reads and calls. `ThreadModel` conforms; demos and tests can supply their own.
@MainActor
public protocol PendingRequestSource: AnyObject {
    var sessionID: SessionID { get }
    var session: Session? { get }
    /// Oldest first; includes requests from child sessions.
    var pendingRequests: [PendingRequest] { get }
    /// Replies in flight: shown disabled, not removed.
    var submittingRequestIDs: Set<String> { get }
    var lastError: EngineError? { get }
    func reply(to id: PermissionRequestID, _ reply: PermissionReply, message: String?) async
    func answer(_ id: QuestionID, _ answers: [String: QuestionAnswer]) async
    func dismiss(_ id: QuestionID) async
    /// BelloCode's own requests (secrets, app approvals). Default: ignored (demos).
    func respond(to request: AppRequest, _ response: AppRequestResponse) async
    /// Whether a secret is already saved under this label ("Use Saved Value"). Default: false.
    func savedSecretExists(label: String) -> Bool
    /// Whether placeholder secrets can be used now (BelloCode's egress proxy runs). Default: false.
    var placeholderSecretsAvailable: Bool { get }
}

extension ThreadModel: PendingRequestSource {}

/// What the stack shows next to a request: the project, and the child session that asked (its title, directory and
/// agent), looked up in the engine's cached session rows.
public struct PendingRequestContext {
    public var projectName: String?
    public var session: @MainActor (SessionID) -> Session?

    public init(projectName: String? = nil, session: @escaping @MainActor (SessionID) -> Session? = { _ in nil }) {
        self.projectName = projectName
        self.session = session
    }
}

/// View state of the stack: which request is in front, per-request inputs (kept while navigating), expansion, and
/// which requests were already announced to VoiceOver.
@MainActor
@Observable
public final class PendingRequestStackModel {
    public let source: any PendingRequestSource
    public var context: PendingRequestContext
    /// The request shown in front (stable server ID; falls back to the oldest).
    public var currentID: String?
    public var expandedDetails: Set<String> = []
    /// Requests whose "Deny with note" field is open, and the notes typed.
    public var noteOpen: Set<String> = []
    public var notes: [String: String] = [:]
    @ObservationIgnored private var forms: [String: QuestionFormModel] = [:]
    /// Typed secret values not yet saved, per request (memory only; cleared on save, decline and resolution).
    @ObservationIgnored private var secretDrafts: [String: SecretDraft] = [:]
    @ObservationIgnored private var announced: Set<String> = []
    /// Posts a VoiceOver announcement; injected so tests can record them.
    @ObservationIgnored public var announce: @MainActor (String) -> Void

    public init(source: any PendingRequestSource, context: PendingRequestContext = PendingRequestContext(),
                announce: @escaping @MainActor (String) -> Void = AccessibilityAnnouncer.post) {
        self.source = source
        self.context = context
        self.announce = announce
    }

    public var requests: [PendingRequest] { source.pendingRequests }

    public var current: PendingRequest? {
        let requests = self.requests
        if let currentID, let match = requests.first(where: { $0.id == currentID }) { return match }
        return requests.first
    }

    public var currentIndex: Int {
        guard let current else { return 0 }
        return requests.firstIndex { $0.id == current.id } ?? 0
    }

    public func showNext() {
        let requests = self.requests
        guard !requests.isEmpty else { return }
        currentID = requests[(currentIndex + 1) % requests.count].id
    }

    public func showPrevious() {
        let requests = self.requests
        guard !requests.isEmpty else { return }
        currentID = requests[(currentIndex - 1 + requests.count) % requests.count].id
    }

    public func isSubmitting(_ request: PendingRequest) -> Bool { source.submittingRequestIDs.contains(request.id) }

    public func form(for question: QuestionRequest) -> QuestionFormModel {
        if let form = forms[question.id.rawValue] { return form }
        let form = QuestionFormModel(fields: question.fields)
        forms[question.id.rawValue] = form
        return form
    }

    public func secretDraft(for request: AppRequest) -> SecretDraft {
        if let draft = secretDrafts[request.id] { return draft }
        let draft = SecretDraft()
        secretDrafts[request.id] = draft
        return draft
    }

    /// The child session that asked, when it is not the open thread.
    public func origin(of request: PendingRequest) -> String? {
        guard request.sessionID != source.sessionID else { return nil }
        return context.session(request.sessionID)?.title ?? "a sub-agent"
    }

    /// The session that asked: the open thread, or the child (when known).
    public func session(of request: PendingRequest) -> Session? {
        request.sessionID == source.sessionID ? source.session : context.session(request.sessionID)
    }

    public func presentation(_ request: PermissionRequest) -> PermissionPresentation {
        let directory = session(of: .permission(request))?.directory ?? source.session?.directory
        return PermissionPresentation(request, directory: directory, projectName: context.projectName)
    }

    // MARK: Actions

    public func reply(_ reply: PermissionReply, to request: PermissionRequest) async {
        guard !source.submittingRequestIDs.contains(request.id.rawValue) else { return }
        let note = reply == .reject ? notes[request.id.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        await source.reply(to: request.id, reply, message: note?.isEmpty == false ? note : nil)
        cleanUp()
    }

    /// Validates and submits; returns false (showing errors) when the form is incomplete.
    @discardableResult
    public func submit(_ question: QuestionRequest) async -> Bool {
        let form = form(for: question)
        guard form.validateForSubmit(), !source.submittingRequestIDs.contains(question.id.rawValue) else { return false }
        await source.answer(question.id, form.answers())
        cleanUp()
        return true
    }

    public func dismiss(_ question: QuestionRequest) async {
        guard !source.submittingRequestIDs.contains(question.id.rawValue) else { return }
        await source.dismiss(question.id)
        cleanUp()
    }

    /// Announces requests not announced before (once each, never per update) and drops state of resolved ones.
    public func requestsChanged() {
        let requests = self.requests
        let ids = Set(requests.map(\.id))
        let fresh = requests.filter { !announced.contains($0.id) }
        if !fresh.isEmpty {
            announced.formUnion(fresh.map(\.id))
            let first = fresh[0]
            var text: String
            switch first {
            case .permission(let permission): text = presentation(permission).announcement
            case .question(let question): text = "Question from the agent: \(question.title)"
            case .app(let app):
                switch app.kind {
                case .secret(let prompt): text = "The agent asks for a secret: \(prompt.label)"
                case .approval(let approval): text = "Approval needed: \(approval.title)"
                }
            }
            if let origin = origin(of: first) { text += ", from \(origin)" }
            if fresh.count > 1 { text += ". \(fresh.count) new requests." }
            announce(text)
        }
        announced.formIntersection(ids)
        cleanUp()
    }

    private func cleanUp() {
        let ids = Set(requests.map(\.id))
        forms = forms.filter { ids.contains($0.key) }
        for (id, draft) in secretDrafts where !ids.contains(id) { draft.text = "" }
        secretDrafts = secretDrafts.filter { ids.contains($0.key) }
        notes = notes.filter { ids.contains($0.key) }
        noteOpen.formIntersection(ids)
        expandedDetails.formIntersection(ids)
        if let currentID, !ids.contains(currentID) { self.currentID = nil }
    }

    /// The error of the last failed reply, shown on the card while the request is still pending.
    public var replyError: String? { source.lastError?.userMessage }
}

/// The secure field's text for one secret card. Lives only in memory and is cleared as soon as it is used.
@MainActor
@Observable
public final class SecretDraft {
    public var text = ""
    /// How the value will be used (secret manager); seeded once from the agent's suggestion.
    public var choice = SecretChoice(mode: .placeholder)
    public var seeded = false
    public init() {}

    func seed(from prompt: SecretPrompt, placeholdersAvailable: Bool) {
        guard !seeded else { return }
        seeded = true
        var suggestion = prompt.suggestion ?? SecretChoice(mode: .command)
        if suggestion.mode == .placeholder && !placeholdersAvailable { suggestion.mode = .brokered }
        if suggestion.headerName.isEmpty && suggestion.queryName.isEmpty && !suggestion.destination.isEmpty {
            suggestion.headerName = "Authorization"
            suggestion.headerPrefix = "Bearer "
        }
        suggestion.confirmVisible = false
        choice = suggestion
    }
}
