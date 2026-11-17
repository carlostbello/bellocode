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

/// An in-memory source for tests, demos and previews. Observation is per message, as with `ThreadModel`: changing one
/// message notifies the readers of that message (and of the ID list only when the list changes).
@MainActor
@Observable
public final class StaticTranscriptSource: TranscriptSource {
    @ObservationIgnored public var messages: [Message] {
        didSet { messagesChanged() }
    }
    public var older: [[Message]] = []
    public var isRunning = false
    public var isReady = true
    public private(set) var isLoadingOlder = false
    /// The ID list; reassigned only when it changes (it keeps its storage otherwise).
    private var ids: [MessageID] = []
    @ObservationIgnored private var boxes: [MessageID: MessageBox] = [:]

    @MainActor @Observable final class MessageBox {
        var message: Message
        init(_ message: Message) { self.message = message }
    }

    public init(messages: [Message] = [], older: [[Message]] = []) {
        self.messages = messages
        self.older = older
        messagesChanged()
    }

    private func messagesChanged() {
        // A duplicate ID: the last message wins.
        for message in messages {
            if let box = boxes[message.id] {
                if box.message != message { box.message = message }
            } else {
                boxes[message.id] = MessageBox(message)
            }
        }
        let newIDs = messages.map(\.id)
        let live = Set(newIDs)
        for id in boxes.keys where !live.contains(id) { boxes[id] = nil }
        if newIDs != ids { ids = newIDs }
    }

    public var transcriptMessageIDs: [MessageID] { ids }
    public func transcriptMessage(_ id: MessageID) -> Message? { boxes[id]?.message }
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
