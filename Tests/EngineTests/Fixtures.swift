import BelloCore
import Foundation
import Synchronization
import Testing

@testable import Engine

/// Small builders for domain values in tests.
enum Fixtures {
    static func t(_ ms: Double) -> Timestamp { Timestamp(milliseconds: ms) }

    static func session(
        _ id: String, project: String = "p1", parent: String? = nil, title: String? = nil, updated: Double = 1
    ) -> Session {
        Session(
            id: SessionID(id), projectID: ProjectID(project), parentID: parent.map { SessionID($0) }, title: title,
            directory: "/tmp/\(project)", created: t(1), updated: t(updated))
    }

    static func userMessage(_ id: String, session: String, text: String, at ms: Double) -> Message {
        Message(id: MessageID(id), sessionID: SessionID(session), kind: .user(UserContent(text: text)), created: t(ms))
    }

    static func assistantMessage(_ id: String, session: String, text: String, at ms: Double) -> Message {
        let messageID = MessageID(id)
        return Message(
            id: messageID, sessionID: SessionID(session), kind: .assistant(AssistantInfo(agent: "build", finish: "stop")),
            created: t(ms), completed: t(ms + 1),
            parts: [Part(id: Part.makeID(message: messageID, .text(ordinal: 0)), index: 0, content: .text(text))])
    }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "bellocode-engine-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(
    timeout: Duration = .seconds(10), _ message: @autoclosure () -> String = "condition not met",
    _ condition: () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    if try await condition() { return }
    Issue.record("timed out: \(message())")
    throw CancellationError()
}
