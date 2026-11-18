import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// A running mock server plus an OpenCodeKit client for it.
struct MockHarness {
    let server: MockOpenCodeServer
    let endpoint: MockOpenCodeEndpoint

    static func start(_ scenario: Scenario = .empty(), options: MockServerOptions = .testing) async throws -> MockHarness {
        let server = MockOpenCodeServer(scenario: scenario, options: options)
        return MockHarness(server: server, endpoint: try await server.start())
    }

    var connection: ServerConnection {
        ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? ""))
    }

    var client: OpenCodeClient { OpenCodeClient(connection: connection) }

    func stop() async { await server.stop() }

    /// Every event the mock published so far, decoded as the EventHub would.
    func publishedEnvelopes() async -> [OpenCodeEventEnvelope] {
        let decoder = OpenCodeEventDecoder()
        return await server.publishedEvents().map { decoder.decode(Data($0.serialized.utf8)) }
    }

    /// All messages of a session from the list endpoint, mapped to domain values, oldest first.
    func listedMessages(_ sessionID: SessionID) async throws -> [Message] {
        var messages: [Message] = []
        var cursor: String?
        repeat {
            let page = try await client.messages(
                sessionID: sessionID.rawValue,
                MessageListQuery(limit: 200, order: cursor == nil ? .ascending : nil, cursor: cursor))
            messages += page.data.map { Mapping.message($0, sessionID: sessionID) }
            cursor = page.data.count < 200 ? nil : page.cursor.next
        } while cursor != nil
        return messages
    }

    /// Answers the next pending permission and question (polling until each appears), as a user would.
    func answerFullTour(sessionID: String) async throws {
        try await eventually("permission asked") { await !server.pendingPermissions().isEmpty }
        let permission = await server.pendingPermissions()[0]
        try await client.replyPermission(sessionID: sessionID, requestID: permission.id, decision: .once)
        try await eventually("question asked") { await !server.pendingForms().isEmpty }
        let form = await server.pendingForms()[0]
        try await client.replyForm(sessionID: sessionID, formID: form.id, answer: ["runner": .string("swift test")])
    }
}

/// Messages reduced to what must match between the event-built projection and the list endpoints: identity, kinds,
/// text and tool state. Timestamps, revisions, delivery and streaming flags are excluded.
struct NormalizedMessage: Equatable, CustomStringConvertible {
    struct NormalizedPart: Equatable {
        var id: String
        var summary: String
    }

    var id: String
    var session: String
    var kind: String
    var detail: String
    var parts: [NormalizedPart]

    init(_ message: Message) {
        id = message.id.rawValue
        session = message.sessionID.rawValue
        kind = message.kind.typeName
        switch message.kind {
        case .user(let content): detail = content.text
        case .assistant(let info): detail = "\(info.agent ?? "-") \(info.finish ?? "-") \(info.error?.message ?? "-")"
        default: detail = ""
        }
        parts = message.parts.map { part in
            let summary: String
            switch part.content {
            case .text(let text): summary = "text:\(text)"
            case .reasoning(let text): summary = "reasoning:\(text)"
            case .tool(let call): summary = Self.tool(call)
            case .subagent(let reference):
                summary = "subagent:\(reference.childSessionID?.rawValue ?? "-") " + Self.tool(reference.call)
            case .file(let file): summary = "file:\(file.uri)"
            case .unknown(let type, _): summary = "unknown:\(type)"
            }
            return NormalizedPart(id: part.id.rawValue, summary: summary)
        }
    }

    static func tool(_ call: BelloCore.ToolCall) -> String {
        "tool:\(call.name) \(call.status) in=\(call.input?.text ?? "-") out=\(call.output) err=\(call.error?.message ?? "-")"
    }

    var description: String { "\(id) \(kind) \(detail) \(parts.map(\.summary))" }
}

func normalized(_ messages: [Message]) -> [NormalizedMessage] {
    messages.sorted { $0.sortKey < $1.sortKey }.map(NormalizedMessage.init)
}

/// The `data` of every frame in the pinned contract's recorded stream (Contracts/opencode-<pin>/events-sample.sse).
func recordedFrames() throws -> [String] {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    let contracts = OpenCodePin.contractsDirectory(root: url) ?? url.appending(path: "Contracts")
    let data = try Data(contentsOf: contracts.appending(path: "events-sample.sse"))
    var parser = SSEParser()
    var frames: [String] = []
    for byte in data {
        if let event = try parser.push(byte) { frames.append(event.data) }
    }
    return frames
}

/// The recorded contract stream as decoded envelopes.
func recordedEnvelopes() throws -> [OpenCodeEventEnvelope] {
    let decoder = OpenCodeEventDecoder()
    return try recordedFrames().map { decoder.decode(Data($0.utf8)) }
}

/// An ordering barrier for a thread model: publishes a marker change on the thread's topic after everything the engine
/// has published so far, and waits until the model applied it. Each subscriber's mailbox is ordered, so every earlier
/// change to the thread (for example from a resync that just finished) has been applied when this returns. Replaces
/// fixed sleeps (docs/reviews/M1-review.md, m3).
@MainActor
func threadBarrier(_ engine: Engine, _ thread: ThreadModel) async throws {
    let marker = Double(Int.random(in: 1_000_000..<9_000_000))
    let id = thread.sessionID
    await engine.core.updateThreadUI(id) { $0.scrollOffset = marker }
    try await waitUntil("barrier") { thread.uiState.scrollOffset == marker }
}

/// A failure report for engine flow tests: the thread model's queue and status, the core's queue, unconfirmed edits
/// and statistics, and the mock's recent requests and published events. Test data only (no secrets).
@MainActor
func engineDiagnostics(_ harness: MockHarness, _ engine: Engine, _ thread: ThreadModel) async -> String {
    let queue = thread.queue.map { "  \($0.id.rawValue) \($0.delivery) \($0.state) created=\($0.created.milliseconds)" }
    let users = userMessages(thread).map { "  \($0.id.rawValue) \(String(describing: $0.delivery))" }
    let core = await engine.core.queueDiagnostics(thread.sessionID)
    let requests = await harness.server.recordedRequests().suffix(60)
    let events = await harness.server.publishedEvents().suffix(60).map { event -> String in
        let text = event.serialized
        return "  " + (text.count > 240 ? String(text.prefix(240)) + "…" : text)
    }
    let held = await harness.server.heldEventCount
    return """
        --- diagnostics ---
        connection: \(engine.root.connection); thread phase \(thread.phase); status \(String(describing: thread.status?.status)); \
        running \(thread.isRunning); pending \(thread.pendingRequests.count); lastError \(String(describing: thread.lastError))
        model queue (\(thread.queue.count)):
        \(queue.joined(separator: "\n"))
        user messages:
        \(users.joined(separator: "\n"))
        \(core)
        mock held events: \(held)
        mock requests (last \(requests.count)):
          \(requests.joined(separator: "\n  "))
        mock events (last \(events.count)):
        \(events.joined(separator: "\n"))
        --- end diagnostics ---
        """
}

/// `#expect` that attaches `engineDiagnostics` when it fails.
@MainActor
func check(
    _ condition: Bool, _ comment: String, _ harness: MockHarness, _ engine: Engine, _ thread: ThreadModel,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    guard !condition else { return }
    let report = await engineDiagnostics(harness, engine, thread)
    Issue.record(Comment(rawValue: comment + "\n" + report), sourceLocation: sourceLocation)
}
