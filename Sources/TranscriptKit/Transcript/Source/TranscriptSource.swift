import BelloCore
import Engine
import Foundation
import Observation

/// What the transcript reads from a thread. `ThreadModel` conforms; tests and the demo can supply their own.
///
/// Reads happen inside `withObservationTracking`, so conforming types should be `@Observable`: the transcript
/// re-reads `messageIDs` (and the flags) when they change, and each tracked message when its model changes.
@MainActor
public protocol TranscriptSource: AnyObject {
    /// Loaded messages, oldest first (server IDs).
    var transcriptMessageIDs: [MessageID] { get }
    func transcriptMessage(_ id: MessageID) -> Message?
    var transcriptHasOlder: Bool { get }
    var transcriptIsLoadingOlder: Bool { get }
    /// The first content (cache or server) has been applied.
    var transcriptIsReady: Bool { get }
    /// A turn is running (shows "Working…" while nothing visible streams).
    var transcriptIsRunning: Bool { get }
    func transcriptLoadOlder() async
}

extension ThreadModel: TranscriptSource {
    public var transcriptMessageIDs: [MessageID] { messageIDs }
    public func transcriptMessage(_ id: MessageID) -> Message? { message(id)?.message }
    public var transcriptHasOlder: Bool { hasOlder }
    public var transcriptIsLoadingOlder: Bool { isLoadingOlder }
    public var transcriptIsReady: Bool { phase != .opening }
    public var transcriptIsRunning: Bool { isRunning }
    public func transcriptLoadOlder() async { await loadOlder() }
}

/// An in-memory source for tests, demos and previews.
@MainActor
@Observable
public final class StaticTranscriptSource: TranscriptSource {
    public var messages: [Message] {
        didSet { index = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { $1 }) }
    }
    public var older: [[Message]] = []
    public var isRunning = false
    public var isReady = true
    public private(set) var isLoadingOlder = false
    @ObservationIgnored private var index: [MessageID: Message] = [:]

    public init(messages: [Message] = [], older: [[Message]] = []) {
        self.messages = messages
        self.older = older
        index = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    }

    public var transcriptMessageIDs: [MessageID] { messages.map(\.id) }
    public func transcriptMessage(_ id: MessageID) -> Message? {
        _ = messages  // register observation on the list (messages are values here)
        return index[id]
    }
    public var transcriptHasOlder: Bool { !older.isEmpty }
    public var transcriptIsLoadingOlder: Bool { isLoadingOlder }
    public var transcriptIsReady: Bool { isReady }
    public var transcriptIsRunning: Bool { isRunning }

    public func transcriptLoadOlder() async {
        guard let page = older.popLast(), !isLoadingOlder else { return }
        isLoadingOlder = true
        await Task.yield()
        messages = page + messages
        isLoadingOlder = false
    }

    /// Replaces one message (a new revision).
    public func update(_ message: Message) {
        if let position = messages.firstIndex(where: { $0.id == message.id }) {
            messages[position] = message
        } else {
            messages.append(message)
        }
    }
}
