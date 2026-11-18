import BelloCore
import Foundation
import OpenCodeKit

/// Where the engine finds its opencode server.
public enum ServerSource: Sendable {
    /// The bundled server, owned by a supervisor. The engine starts and stops it.
    case supervised(ServerSupervisor)
    /// An already running server (the mock, or `BELLOCODE_SERVER_URL`). Never started or stopped by the engine.
    case fixed(ServerConnection)
    /// A server whose address can change (tests that restart the mock on a new port). Returns nil while unavailable.
    case dynamic(@Sendable () async -> ServerConnection?)

    /// `BELLOCODE_SERVER_URL` (+ optional `BELLOCODE_SERVER_PASSWORD`): attach to that server instead of spawning one.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> ServerSource? {
        guard let raw = environment["BELLOCODE_SERVER_URL"], let url = URL(string: raw), url.scheme != nil else { return nil }
        let password = environment["BELLOCODE_SERVER_PASSWORD"] ?? ""
        return .fixed(ServerConnection(baseURL: url, credentials: ServerCredentials(password: password)))
    }
}

/// Engine settings. Defaults are the production values; tests shorten intervals.
public struct EngineConfiguration: Sendable {
    public var server: ServerSource
    public var store: ProjectionStore.Location
    /// Coalescing cadence for streamed text (AGENTS.md rule 3: start at 33 ms).
    public var streamCadence: Duration = .milliseconds(33)
    /// Write-behind interval for the projection database.
    public var writeInterval: Duration = .milliseconds(100)
    /// Messages a thread loads when it opens.
    public var windowSize: Int = 50
    /// Messages per "load older" page.
    public var pageSize: Int = 50
    /// Concurrent list requests during a resync.
    public var syncConcurrency: Int = 4
    /// Session list pages (of `sessionPageSize`) read per resync; more marks the list incomplete (nothing is deleted).
    public var maxSessionPages: Int = 100
    public var sessionPageSize: Int = 100
    /// Messages kept in memory by the engine (the store holds the rest).
    public var messageCacheCapacity: Int = 2048
    /// Per-subscriber change backlog before a reload is forced.
    public var subscriberLimit: Int = 4096
    /// EventHub per-subscriber frame buffer.
    public var eventBufferLimit: Int = 4096
    /// Reconnect backoff for the event stream.
    public var eventBackoff = BackoffPolicy(initial: .milliseconds(250), maximum: .seconds(10))
    /// Retry backoff for failed database writes (kept in memory meanwhile).
    public var writeRetryBackoff = BackoffPolicy(initial: .milliseconds(250), maximum: .seconds(10))
    /// Retry backoff after a resync failed all its attempts while the event stream stays connected.
    public var resyncRetryBackoff = BackoffPolicy(initial: .seconds(1), maximum: .seconds(30))
    /// The location whose catalog is loaded when no project is known.
    public var defaultDirectory: String?
    /// Auto's reviewer model backend; nil uses opencode's `generate.text` (tests inject a scripted one).
    public var autoReviewerModel: (any AutoReviewer.Model)?
    public var time: any TimeSource = SystemTimeSource()
    /// Calendar time for the scheduler and the PR poller (docs/features/orchestration-extras.md).
    public var wallClock: any WallClock = SystemWallClock()
    /// Where secrets are kept: the macOS Keychain by default; tests pass `InMemorySecretVault`.
    public var secretVault: any SecretVault = KeychainSecretVault()
    /// How GitLab is reached (REST v4 over URLSession; tests and mock mode pass recorded fixtures).
    public var forgeTransport: any ForgeTransport = URLSessionForgeTransport()
    /// Where GitLab access tokens are kept: the Keychain under `GitLabProvider.tokenService`.
    public var forgeTokens: any SecretVault = KeychainSecretVault(service: GitLabProvider.tokenService)
    /// MR watch polling: base interval, longest backoff after failures.
    public var mergeRequestPoll: Duration = .seconds(120)
    public var mergeRequestMaxBackoff: Duration = .seconds(1800)
    /// Where HTML visuals are kept (default: `~/Library/Caches/BelloCode/visuals`).
    public var visualsDirectory: URL?
    /// Off in tests that do not exercise scheduling; the app always starts it.
    public var startsExtras = true
    /// Containerised execution (docs/features/containers.md). The app sets it for the bundled server; nil in mock
    /// mode and tests (the Environment UI then says container execution is off).
    public var containers: ContainerConfiguration?

    public init(server: ServerSource, store: ProjectionStore.Location) {
        self.server = server
        self.store = store
    }

    /// The app's default cache location: `~/Library/Application Support/BelloCode/projection.sqlite`.
    public static func defaultStoreURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "BelloCode", directoryHint: .isDirectory).appending(path: "projection.sqlite")
    }
}

/// A command failure, phrased for the user. Never contains credentials or message content.
public enum EngineError: Error, Sendable, Hashable, CustomStringConvertible {
    /// No server connection; nothing was sent.
    case offline
    /// The thing no longer exists on the server.
    case notFound(String)
    /// The request was already settled or conflicts with the current state (for example, an answered question).
    case conflict(String)
    /// The server rejected the request.
    case rejected(String)
    /// The server failed.
    case server(String)
    /// No answer in time; the server may or may not have applied it.
    case timedOut
    /// Every answer to a send was lost and opencode could not be asked whether it has the prompt. It is kept, with its
    /// ID, as an `UnconfirmedSend`: retrying reuses the ID, so opencode admits it at most once.
    case deliveryUnknown
    case cancelled
    case failed(String)

    public var userMessage: String {
        switch self {
        case .offline: "BelloCode is not connected to opencode. Nothing was sent."
        case .notFound(let detail): "It no longer exists. \(detail)"
        case .conflict(let detail): "That was already handled. \(detail)"
        case .rejected(let detail): "opencode refused the request. \(detail)"
        case .server(let detail): "opencode reported an error. \(detail)"
        case .timedOut: "opencode did not answer in time. Check the thread before retrying."
        case .deliveryUnknown:
            "Delivery unknown: opencode did not confirm it received this message. Retry checks and resends it under the same ID, so it cannot run twice."
        case .cancelled: "Cancelled."
        case .failed(let detail): "Something went wrong. \(detail)"
        }
    }

    /// The user-facing text. It can contain the server's own error message (sanitized: control characters removed,
    /// at most 300 characters), so it is for display and private diagnostics only. Log `logSummary`.
    public var description: String { userMessage }

    /// The kind of failure only, never server-provided text: safe for public logs.
    public var logSummary: String {
        switch self {
        case .offline: "offline"
        case .notFound: "notFound"
        case .conflict: "conflict"
        case .rejected: "rejected"
        case .server: "server"
        case .timedOut: "timedOut"
        case .deliveryUnknown: "deliveryUnknown"
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
    }

    /// For public logs: the engine error kind plus, for server errors, the operation, status and validated tag.
    static func logSummary(_ error: any Error) -> String {
        if let error = error as? OpenCodeError { return error.logSummary }
        return from(error).logSummary
    }

    /// Server-provided text made safe to display: no control characters, bounded length.
    static func sanitized(_ text: String) -> String {
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : scalar
        }))
        return cleaned.count > 300 ? String(cleaned.prefix(300)) + "…" : cleaned
    }

    /// Whether retrying the same request may succeed.
    public var isTransient: Bool {
        switch self {
        case .offline, .timedOut, .server, .deliveryUnknown: true
        default: false
        }
    }

    static func from(_ error: any Error) -> EngineError {
        if let error = error as? EngineError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? OpenCodeError {
            switch error {
            case .http(let status, let body, _):
                let message = body.map { sanitized($0.message) } ?? "HTTP \(status)"
                switch status {
                case 404: return .notFound(message)
                case 409: return .conflict(message)
                case 503: return .offline
                case 400..<500: return .rejected(message)
                default: return .server(message)
                }
            case .transport(_, let code):
                return code == .timedOut ? .timedOut : .offline
            case .decoding(let operation, _):
                return .failed("Unexpected response from \(operation).")
            case .invalidResponse, .unexpectedContentType:
                return .failed("Unexpected response.")
            }
        }
        if error is TimeoutError { return .timedOut }
        if let error = error as? URLError { return error.code == .timedOut ? .timedOut : .offline }
        return .failed(String(describing: type(of: error)))
    }
}

/// opencode-shaped identifiers for optimistic records: `msg_`/`ses_` + 12 hex digits of time and counter + 14 random
/// base62 characters. Message IDs ascend with time; session IDs descend (newer sorts first), as opencode's do.
struct IdentifierFactory: Sendable {
    private var lastTime: Int64 = 0
    private var counter: UInt64 = 0

    mutating func messageID(now: Timestamp) -> MessageID { MessageID(make("msg", now: now, descending: false)) }

    mutating func sessionID(now: Timestamp) -> SessionID { SessionID(make("ses", now: now, descending: true)) }

    private mutating func make(_ prefix: String, now: Timestamp, descending: Bool) -> String {
        // Never backwards: `now` is an estimate of the server clock that a correction can move back, and IDs of one
        // kind must keep the order they were minted in (it breaks ties between equal timestamps).
        var time = max(Int64(now.milliseconds), lastTime)
        if time != lastTime { counter = 0 }
        counter += 1
        if counter > 0xFFF {
            // The counter field is full: take the next millisecond rather than wrap.
            time += 1
            counter = 1
        }
        lastTime = time
        let value = (UInt64(max(time, 0)) & 0xF_FFFF_FFFF) << 12 | (counter & 0xFFF)
        let ordered = descending ? 0xFFFF_FFFF_FFFF - value : value
        var hex = String(ordered, radix: 16)
        if hex.count < 12 { hex = String(repeating: "0", count: 12 - hex.count) + hex }
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        var generator = SystemRandomNumberGenerator()
        let suffix = String((0..<14).map { _ in alphabet[Int(generator.next() % 62)] })
        return "\(prefix)_\(hex)\(suffix)"
    }
}
