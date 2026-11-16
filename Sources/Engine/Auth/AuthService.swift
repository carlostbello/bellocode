import BelloCore
import Foundation
import Observation
import OpenCodeKit

// MARK: - Domain values

/// A way to sign in to an integration.
public struct AuthMethod: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// Paste an API key.
        case key
        /// Sign in in the browser (`auto`) or paste a code (`code`); the mode is known once the attempt starts.
        case oauth
        /// The server runs a login command (for example a provider CLI).
        case command
        /// A credential source outside opencode (an AWS profile, gcloud credentials, another CLI's login).
        case external
        /// Environment variables the server reads; nothing to do in BelloCode.
        case environment
        case other(String)
    }

    public var kind: Kind
    /// `methodID` for oauth, command and external; nil for key and env.
    public var methodID: String?
    public var label: String
    /// Questions to answer first (rendered like a question card; `hidden` fields submit their default).
    public var fields: [QuestionField]
    public var command: [String]
    public var environmentNames: [String]

    public var id: String { methodID ?? "\(kind)" }

    /// Whether BelloCode can run this method (env only describes variables).
    public var isInteractive: Bool {
        switch kind {
        case .key, .oauth, .command, .external: true
        case .environment, .other: false
        }
    }
}

/// An integration (a provider, usually) and its sign-in state.
public struct IntegrationItem: Hashable, Sendable, Identifiable {
    public struct Connection: Hashable, Sendable, Identifiable {
        /// Credential ID, or the variable name for an environment connection.
        public var id: String
        public var label: String
        public var isCredential: Bool
        /// `key`, `oauth`, `external` for credentials.
        public var method: String?
        /// Set when opencode says the connection needs signing in again.
        public var problem: String?
    }

    public var id: String
    public var name: String
    public var methods: [AuthMethod]
    public var connections: [Connection]

    public var isConnected: Bool { connections.contains { $0.problem == nil } }
    public var interactiveMethods: [AuthMethod] { methods.filter(\.isInteractive) }
}

/// A stored credential, without its secret.
public struct CredentialItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var integrationID: String
    public var label: String
    public var isActive: Bool
    /// `key`, `oauth` or `external`.
    public var kind: String
}

/// The state of one sign-in attempt. Transitions:
///
/// ```
/// idle ─connect(key/external)→ submitting ─204→ succeeded
///                                          └─error→ failed(retry keeps every input)
/// idle ─startOAuth→ starting ─auto→ waitingForBrowser ─poll complete→ succeeded
///                            │                        ├─poll failed→ failed
///                            │                        ├─poll expired / local expiry→ expired
///                            │                        └─paste redirect URL→ verifying
///                            └─code→ waitingForCode ─submitCode→ verifying ─204→ succeeded / ─400→ waitingForCode(error)
/// idle ─startCommand→ starting → runningCommand(output) ─complete/failed/expired→ …
/// any waiting state ─cancel()→ cancelled (the server attempt is cancelled too)
/// ```
public enum AuthFlowPhase: Hashable, Sendable {
    case idle
    case submitting
    case starting
    /// The authorization page is open in the browser; the server completes the attempt. `canPaste`: the user may
    /// also paste the redirect URL.
    case waitingForBrowser(url: URL, instructions: String, canPaste: Bool, expires: Date?)
    /// The user must paste the code the provider shows. `error` is the last rejected attempt's message.
    case waitingForCode(url: URL, instructions: String, expires: Date?, error: String?)
    case verifying
    case runningCommand(output: String?)
    case succeeded
    case failed(message: String)
    case expired
    case cancelled

    public var isWaiting: Bool {
        switch self {
        case .submitting, .starting, .waitingForBrowser, .waitingForCode, .verifying, .runningCommand: true
        default: false
        }
    }
}

/// One sign-in attempt for one integration and method.
public struct AuthFlow: Hashable, Sendable {
    public var integrationID: String
    public var methodID: String?
    public var phase: AuthFlowPhase
}

/// Opens a URL in the user's default browser. Injected so tests and demos do not open one.
public typealias URLOpener = @MainActor @Sendable (URL) -> Void

// MARK: - Service

/// Provider sign-in and credentials through opencode's integration API.
///
/// Secrets: API keys go straight to the server in one request and are never stored, logged or kept in this object
/// beyond the call (the caller's text field owns the typed key). Credential lists are decoded without secret values
/// (`CredentialSummary`). BelloCode itself retains no provider secret, so nothing is written to the Keychain.
///
/// Threading: `@MainActor`, observable. Network calls run in the client off the main actor. Polling for OAuth and
/// command attempts is a task owned by this service and cancelled by `cancel()`, a new attempt, or `shutdown()`.
@MainActor
@Observable
public final class AuthService {
    public enum ListState: Hashable, Sendable {
        case idle, loading, loaded
        case failed(String)
    }

    public private(set) var integrations: [IntegrationItem] = []
    public private(set) var credentials: [CredentialItem] = []
    public private(set) var listState: ListState = .idle
    /// The current sign-in attempt, if any (one at a time).
    public private(set) var flow: AuthFlow?
    /// The last credential command failure (activate, rename, remove), for an inline message.
    public private(set) var lastError: EngineError?

    @ObservationIgnored private let client: @Sendable () async throws -> OpenCodeClient
    @ObservationIgnored private let directory: @MainActor () -> String?
    @ObservationIgnored private let openURL: URLOpener
    @ObservationIgnored private let importer: CredentialImporter?
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let emptyListRetries: Int
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var attempt: (integrationID: String, attemptID: String, isCommand: Bool)?
    @ObservationIgnored private var flowGeneration = 0

    /// - Parameters:
    ///   - client: the current server client (throws `EngineError.offline` when there is none).
    ///   - directory: the location integrations are listed for (the current project; nil uses the server default).
    ///   - openURL: opens authorization pages (the app passes `NSWorkspace.shared.open`).
    ///   - importer: runs `opencode auth export | import`; nil when no bundled binary is known.
    public init(
        client: @escaping @Sendable () async throws -> OpenCodeClient, directory: @escaping @MainActor () -> String? = { nil },
        openURL: @escaping URLOpener, importer: CredentialImporter? = nil, pollInterval: Duration = .seconds(1),
        emptyListRetries: Int = 5
    ) {
        self.client = client
        self.directory = directory
        self.openURL = openURL
        self.importer = importer
        self.pollInterval = pollInterval
        self.emptyListRetries = emptyListRetries
    }

    /// Cancels polling and any open attempt on the server.
    public func shutdown() {
        refreshTask?.cancel()
        Task { await self.cancel() }
    }

    // MARK: Lists

    /// Reloads integrations and credentials. A cold location can answer an empty integration list for a few seconds;
    /// that is retried (`emptyListRetries`, one `pollInterval` apart) before showing it as empty.
    public func refresh() async {
        if integrations.isEmpty { listState = .loading }
        let directory = directory()
        do {
            let client = try await client()
            var list = try await client.integrations(directory: directory)
            var retries = emptyListRetries
            while list.isEmpty, retries > 0, !Task.isCancelled {
                retries -= 1
                try await Task.sleep(for: pollInterval)
                list = try await client.integrations(directory: directory)
            }
            let summaries = try await client.credentials()
            try Task.checkCancellation()
            integrations = list.map(Self.item).sorted(by: Self.order)
            credentials = summaries.map {
                CredentialItem(id: $0.id, integrationID: $0.integrationID, label: $0.label, isActive: $0.active, kind: $0.kind)
            }
            listState = .loaded
        } catch is CancellationError {
            return
        } catch {
            let failure = EngineError.from(error)
            listState = integrations.isEmpty ? .failed(failure.userMessage) : .loaded
            lastError = failure
        }
    }

    public func integration(_ id: String) -> IntegrationItem? { integrations.first { $0.id == id } }

    public func credentials(for integrationID: String) -> [CredentialItem] {
        credentials.filter { $0.integrationID == integrationID }
    }

    /// Ranked integrations for a search field: connected and well-known first when the query is empty.
    public func search(_ query: String) -> [IntegrationItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return integrations }
        return integrations.compactMap { item -> (IntegrationItem, Int)? in
            let name = item.name.lowercased()
            let id = item.id.lowercased()
            if name.hasPrefix(trimmed) || id.hasPrefix(trimmed) { return (item, 0) }
            if name.contains(trimmed) || id.contains(trimmed) { return (item, 1) }
            return nil
        }.sorted { $0.1 == $1.1 ? Self.order($0.0, $1.0) : $0.1 < $1.1 }.map(\.0)
    }

    /// Integrations people look for first, shown at the top of the provider list.
    public static let featured = ["opencode", "anthropic", "openai", "github-copilot", "google", "openrouter", "xai", "mistral"]

    static func order(_ lhs: IntegrationItem, _ rhs: IntegrationItem) -> Bool {
        if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
        let l = featured.firstIndex(of: lhs.id) ?? Int.max
        let r = featured.firstIndex(of: rhs.id) ?? Int.max
        if l != r { return l < r }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    static func item(_ dto: IntegrationInfo) -> IntegrationItem {
        IntegrationItem(
            id: dto.id, name: dto.name,
            methods: dto.methods.map { method in
                let kind: AuthMethod.Kind =
                    switch method.type {
                    case .key: .key
                    case .oauth: .oauth
                    case .command: .command
                    case .external: .external
                    case .env: .environment
                    default: .other(method.type.rawValue)
                    }
                let label = method.label ?? {
                    switch kind {
                    case .key: "API key"
                    case .oauth: "Sign in with \(dto.name)"
                    case .command: "Log in with a command"
                    case .external: "External credentials"
                    case .environment: "Environment variable"
                    case .other(let raw): raw
                    }
                }()
                return AuthMethod(
                    kind: kind, methodID: method.id, label: label, fields: (method.form ?? []).map(Mapping.field),
                    command: method.command ?? [], environmentNames: method.names ?? [])
            },
            connections: dto.connections.compactMap { connection in
                let isCredential = connection.type == "credential"
                guard let id = isCredential ? connection.id : connection.name else { return nil }
                return IntegrationItem.Connection(
                    id: id, label: connection.label ?? connection.name ?? id, isCredential: isCredential,
                    method: connection.method, problem: connection.status?.message)
            })
    }

    // MARK: Connecting

    /// Connects with an API key (and the method's form answers). The key is sent once and not kept. Inputs are not
    /// cleared on failure; the flow reports `failed` with the server's reason.
    public func connectKey(integrationID: String, key: String, answers: [String: QuestionAnswer] = [:], label: String? = nil) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = beginFlow(integrationID: integrationID, methodID: nil, phase: .submitting)
        guard !trimmed.isEmpty else {
            setPhase(.failed(message: "Enter an API key."), generation)
            return
        }
        let directory = directory()
        do {
            try await client().connectKey(
                integrationID: integrationID, key: trimmed, answer: Self.formAnswer(answers), label: Self.label(label),
                directory: directory)
            setPhase(.succeeded, generation)
            await refresh()
        } catch {
            setPhase(.failed(message: Self.message(error)), generation)
        }
    }

    /// Connects an `external` method (credentials kept outside opencode, such as an AWS profile).
    public func connectExternal(integrationID: String, methodID: String, answers: [String: QuestionAnswer] = [:], label: String? = nil) async {
        let generation = beginFlow(integrationID: integrationID, methodID: methodID, phase: .submitting)
        do {
            try await client().connectExternal(
                integrationID: integrationID, methodID: methodID, answer: Self.formAnswer(answers), label: Self.label(label),
                directory: directory())
            setPhase(.succeeded, generation)
            await refresh()
        } catch {
            setPhase(.failed(message: Self.message(error)), generation)
        }
    }

    /// Starts an OAuth attempt and opens the authorization page in the default browser. `auto` attempts are polled
    /// until they complete, fail or expire; `code` attempts wait for `submitCode`.
    public func startOAuth(integrationID: String, methodID: String, answers: [String: QuestionAnswer] = [:], label: String? = nil) async {
        let generation = beginFlow(integrationID: integrationID, methodID: methodID, phase: .starting)
        do {
            let started = try await client().startOAuth(
                integrationID: integrationID, methodID: methodID, answer: Self.formAnswer(answers), label: Self.label(label),
                directory: directory())
            guard generation == flowGeneration else {
                try? await client().cancelOAuth(integrationID: integrationID, attemptID: started.attemptID, directory: directory())
                return
            }
            attempt = (integrationID, started.attemptID, false)
            guard let url = URL(string: started.url), url.scheme == "https" || url.scheme == "http" else {
                setPhase(.failed(message: "opencode returned an authorization link BelloCode cannot open."), generation)
                await cancelAttemptOnServer()
                return
            }
            let expires = Self.deadline(started.time)
            if started.mode == "code" {
                setPhase(.waitingForCode(url: url, instructions: started.instructions, expires: expires, error: nil), generation)
            } else {
                setPhase(
                    .waitingForBrowser(url: url, instructions: started.instructions, canPaste: started.paste == true, expires: expires),
                    generation)
            }
            openURL(url)
            startPolling(generation: generation, expires: expires)
        } catch {
            setPhase(.failed(message: Self.message(error)), generation)
        }
    }

    /// Opens the current attempt's page again (the user closed the tab).
    public func reopenBrowser() {
        switch flow?.phase {
        case .waitingForBrowser(let url, _, _, _), .waitingForCode(let url, _, _, _): openURL(url)
        default: break
        }
    }

    /// Completes a `code` attempt with the pasted code, or an `auto` attempt with the pasted redirect URL. A rejected
    /// code returns to `waitingForCode` with the reason, keeping the attempt.
    public func submitCode(_ code: String) async {
        guard let flow, let attempt, !attempt.isCommand else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let previous = flow.phase
        let generation = flowGeneration
        setPhase(.verifying, generation)
        do {
            try await client().completeOAuth(
                integrationID: attempt.integrationID, attemptID: attempt.attemptID, code: trimmed, directory: directory())
            guard generation == flowGeneration else { return }
            if case .waitingForBrowser = previous {
                // The result of a pasted redirect URL arrives through the attempt status.
                setPhase(previous, generation)
                return
            }
            stopPolling()
            self.attempt = nil
            setPhase(.succeeded, generation)
            await refresh()
        } catch {
            guard generation == flowGeneration else { return }
            switch previous {
            case .waitingForCode(let url, let instructions, let expires, _):
                setPhase(.waitingForCode(url: url, instructions: instructions, expires: expires, error: Self.message(error)), generation)
            default:
                setPhase(previous, generation)
                lastError = EngineError.from(error)
            }
        }
    }

    /// Starts a command login; its progress output (if any) shows while it runs.
    public func startCommand(integrationID: String, methodID: String, label: String? = nil) async {
        let generation = beginFlow(integrationID: integrationID, methodID: methodID, phase: .starting)
        do {
            let started = try await client().startCommand(
                integrationID: integrationID, methodID: methodID, label: Self.label(label), directory: directory())
            guard generation == flowGeneration else {
                try? await client().cancelCommand(integrationID: integrationID, attemptID: started.attemptID, directory: directory())
                return
            }
            attempt = (integrationID, started.attemptID, true)
            setPhase(.runningCommand(output: nil), generation)
            startPolling(generation: generation, expires: Self.deadline(started.time))
        } catch {
            setPhase(.failed(message: Self.message(error)), generation)
        }
    }

    /// Cancels the current attempt (here and on the server). Inputs stay with the caller.
    public func cancel() async {
        guard let flow, flow.phase.isWaiting else { return }
        let generation = flowGeneration
        stopPolling()
        await cancelAttemptOnServer()
        setPhase(.cancelled, generation)
    }

    /// Forgets a finished flow (succeeded, failed, expired, cancelled) so the UI returns to its idle state.
    public func clearFlow() {
        guard let flow, !flow.phase.isWaiting else { return }
        self.flow = nil
    }

    private func beginFlow(integrationID: String, methodID: String?, phase: AuthFlowPhase) -> Int {
        stopPolling()
        if attempt != nil { Task { await self.cancelAttemptOnServer() } }
        flowGeneration += 1
        flow = AuthFlow(integrationID: integrationID, methodID: methodID, phase: phase)
        lastError = nil
        return flowGeneration
    }

    private func setPhase(_ phase: AuthFlowPhase, _ generation: Int) {
        guard generation == flowGeneration, var flow else { return }
        guard flow.phase != phase else { return }
        flow.phase = phase
        self.flow = flow
    }

    private func startPolling(generation: Int, expires: Date?) {
        pollTask?.cancel()
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard let self, !Task.isCancelled, generation == self.flowGeneration else { return }
                if let expires, Date() >= expires {
                    await self.cancelAttemptOnServer()
                    self.setPhase(.expired, generation)
                    return
                }
                guard await self.poll(generation) else { return }
            }
        }
    }

    /// One status poll; returns whether to keep polling.
    private func poll(_ generation: Int) async -> Bool {
        guard let attempt else { return false }
        let status: AttemptStatus
        do {
            let client = try await client()
            status =
                attempt.isCommand
                ? try await client.commandStatus(integrationID: attempt.integrationID, attemptID: attempt.attemptID, directory: directory())
                : try await client.oauthStatus(integrationID: attempt.integrationID, attemptID: attempt.attemptID, directory: directory())
        } catch {
            guard generation == flowGeneration else { return false }
            let failure = EngineError.from(error)
            if failure.isTransient { return true }
            self.attempt = nil
            setPhase(.failed(message: failure.userMessage), generation)
            return false
        }
        guard generation == flowGeneration else { return false }
        switch status.status {
        case .complete:
            self.attempt = nil
            setPhase(.succeeded, generation)
            await refresh()
            return false
        case .failed:
            self.attempt = nil
            setPhase(.failed(message: status.message ?? "The provider did not finish signing in."), generation)
            return false
        case .expired:
            self.attempt = nil
            setPhase(.expired, generation)
            return false
        default:
            if attempt.isCommand, status.message != nil { setPhase(.runningCommand(output: status.message), generation) }
            return true
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func cancelAttemptOnServer() async {
        guard let attempt else { return }
        self.attempt = nil
        let directory = directory()
        guard let client = try? await client() else { return }
        if attempt.isCommand {
            try? await client.cancelCommand(integrationID: attempt.integrationID, attemptID: attempt.attemptID, directory: directory)
        } else {
            try? await client.cancelOAuth(integrationID: attempt.integrationID, attemptID: attempt.attemptID, directory: directory)
        }
    }

    // MARK: Credentials

    /// Makes a credential the integration's active one. Applies at once; rolls back on failure.
    public func activate(_ credentialID: String) async {
        guard let target = credentials.first(where: { $0.id == credentialID }) else { return }
        let previous = credentials
        credentials = credentials.map { item in
            var item = item
            if item.integrationID == target.integrationID { item.isActive = item.id == credentialID }
            return item
        }
        await run(rollback: previous) { try await $0.activateCredential(credentialID) }
    }

    public func rename(_ credentialID: String, to label: String) async {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = credentials.firstIndex(where: { $0.id == credentialID }) else { return }
        let previous = credentials
        credentials[index].label = trimmed
        await run(rollback: previous) { try await $0.renameCredential(credentialID, label: trimmed) }
    }

    /// Removes a credential on the server. This cannot be undone (the secret is gone), so the UI confirms first.
    public func remove(_ credentialID: String) async {
        let previous = credentials
        credentials.removeAll { $0.id == credentialID }
        await run(rollback: previous) { try await $0.removeCredential(credentialID) }
    }

    private func run(rollback previous: [CredentialItem], _ body: @escaping @Sendable (OpenCodeClient) async throws -> Void) async {
        do {
            try await body(try await client())
            lastError = nil
            await refresh()
        } catch {
            credentials = previous
            lastError = EngineError.from(error)
        }
    }

    // MARK: Import

    /// Whether importing is available (a bundled opencode is known).
    public var canImport: Bool { importer != nil }

    /// Lists what `source` holds (no secrets), for the consent step.
    public func previewImport(from source: CredentialImportSource) async throws -> [ImportableCredential] {
        guard let importer else { throw EngineError.failed("Importing needs the bundled opencode.") }
        return try await importer.preview(source)
    }

    /// Imports every credential of `source` into BelloCode's opencode. Run only after the user confirmed.
    public func importCredentials(from source: CredentialImportSource) async throws -> CredentialImportResult {
        guard let importer else { throw EngineError.failed("Importing needs the bundled opencode.") }
        let connection = try await client().connection
        let result = try await importer.run(source, into: connection)
        await refresh()
        return result
    }

    // MARK: Helpers

    static func formAnswer(_ answers: [String: QuestionAnswer]) -> [String: FormValue]? {
        answers.isEmpty ? nil : answers.mapValues(Mapping.formValue)
    }

    static func label(_ label: String?) -> String? {
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The local deadline of an attempt: its server lifetime (`expires - created`) from now, so a server clock that
    /// differs from this Mac's never expires an attempt early. Nil when it does not expire.
    static func deadline(_ time: OAuthAttempt.Time) -> Date? {
        let lifetime = time.expires.value - time.created.value
        guard lifetime.isFinite, lifetime > 0 else { return nil }
        return Date().addingTimeInterval(lifetime / 1000)
    }

    /// The server's own reason when it gave one (for example "Missing required form field: resourceName"), else the
    /// generic engine message. Never includes request bodies.
    static func message(_ error: any Error) -> String {
        if let error = error as? OpenCodeError, case .http(_, let body?, _) = error, !body.message.isEmpty { return body.message }
        return EngineError.from(error).userMessage
    }
}
