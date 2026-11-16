import Foundation

// Checkpoint stub: the turn engine replaces this in the next commit.

struct InboxItem: Sendable {
    let id: String
    let json: JSONValue
}

struct TurnHandle {
    let generation: Int
    let task: Task<Void, Never>
}

enum WaitResult: Sendable {
    case reply(JSONValue, message: String?)
    case cancelled
    case interrupted
}

struct Waiter {
    let sessionID: String
    let continuation: CheckedContinuation<WaitResult, Never>
}

extension MockOpenCodeServer {
    func resumeWaiter(_ id: String, with result: WaitResult) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: result)
    }

    func admit(sessionID: String, id: String?, text: String, delivery: String, script: TurnScript) -> JSONValue {
        [:]
    }

    func selectScript(sessionID: String, text: String) -> TurnScript { state.defaultScript }

    func interrupt(_ sessionID: String, resume: Bool) -> Bool { false }
}
