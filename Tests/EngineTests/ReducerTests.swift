import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

@Suite("Reducers", .timeLimit(.minutes(3)))
struct ReducerTests {
    private let now = Timestamp(milliseconds: 1)

    private func run(_ envelopes: [OpenCodeEventEnvelope], pipeline: inout EventPipeline) -> [Reduction] {
        var reductions: [Reduction] = []
        for (index, envelope) in envelopes.enumerated() {
            reductions.append(pipeline.ingest(envelope, clock: .milliseconds(index), now: now))
        }
        reductions.append(pipeline.flushDeltas(clock: .seconds(1_000), now: now, force: true))
        return reductions
    }

    @Test func recordedStreamBuildsTheTurn() throws {
        let envelopes = try recordedEnvelopes()
        var pipeline = EventPipeline()
        _ = run(envelopes, pipeline: &pipeline)
        let state = pipeline.state
        #expect(state.sessions.count == 1)
        let session = try #require(state.sessions.values.first)
        #expect(session.outcome == .succeeded)
        #expect(!session.isRunning)
        #expect(session.usage.outputTokens > 0)
        #expect(state.projects.count == 1)
        let messages = state.messages.messages(in: session.id).sorted { $0.sortKey < $1.sortKey }
        // One user prompt (delivered from the inbox) and two assistant steps.
        #expect(messages.map(\.kind.typeName) == ["user", "assistant", "assistant"])
        let first = messages[1]
        #expect(first.parts.contains { if case .tool(let call) = $0.content { call.name == "shell" && call.status == .completed } else { false } })
        let last = messages[2]
        guard case .assistant(let info) = last.kind else { Issue.record("not assistant"); return }
        #expect(info.finish == "stop")
        #expect(!info.isOpen)
        #expect(last.parts.allSatisfy { !$0.isStreaming })
        #expect(last.parts.contains { if case .text(let text) = $0.content { !text.isEmpty } else { false } })
        #expect(state.queue.isEmpty)
        #expect(state.pending.isEmpty)
    }

    @Test func duplicatesAndReplayAreIdempotent() throws {
        let envelopes = try recordedEnvelopes()
        var once = EventPipeline()
        _ = run(envelopes, pipeline: &once)

        // Every frame twice in a row (same event IDs): dropped by ID.
        var doubled = EventPipeline()
        _ = run(envelopes.flatMap { [$0, $0] }, pipeline: &doubled)
        #expect(doubled.duplicatesDropped == envelopes.filter { $0.id != nil }.count)

        // The whole stream replayed with fresh IDs over the finished state (resync replays buffered events over a
        // newer snapshot): nothing may change.
        var replayed = once
        let renamed = try recordedFrames().map { frame in
            OpenCodeEventDecoder().decode(Data(frame.replacingOccurrences(of: #""id":"evt_"#, with: #""id":"evt_replay"#).utf8))
        }
        let reductions = run(renamed, pipeline: &replayed)
        let sessionID = try #require(once.state.sessions.keys.first)
        let expected = normalized(once.state.messages.messages(in: sessionID))
        #expect(normalized(doubled.state.messages.messages(in: sessionID)) == expected)
        #expect(normalized(replayed.state.messages.messages(in: sessionID)) == expected)
        #expect(replayed.state.sessions == once.state.sessions)
        let messageChanges = reductions.flatMap(\.changes).filter { if case .message = $0 { true } else { false } }
        #expect(messageChanges.isEmpty, "replay must not change messages: \(messageChanges.count)")
    }

    @Test func lateEventsNeverMoveStateBackwards() {
        var state = ProjectionState()
        var reduction = Reduction()
        state.putSession(Fixtures.session("ses_1"), into: &reduction)
        func envelope(_ type: String, _ created: Double, _ data: String) -> OpenCodeEventEnvelope {
            let frame = #"{"id":"evt_\#(UUID().uuidString)","created":\#(created),"type":"\#(type)","data":\#(data)}"#
            return OpenCodeEventDecoder().decode(Data(frame.utf8))
        }
        let toolBase = #""sessionID":"ses_1","assistantMessageID":"msg_a","id":"call_1""#
        let events = [
            envelope("session.step.started", 10, #"{"sessionID":"ses_1","assistantMessageID":"msg_a","agent":"build","model":{"id":"m","providerID":"p"}}"#),
            envelope("session.tool.success", 12, #"{\#(toolBase),"content":[{"type":"text","text":"done"}]}"#),
            // Arrive late, after the success:
            envelope("session.tool.called", 11, #"{\#(toolBase),"input":{"a":1},"executed":false}"#),
            envelope("session.tool.input.started", 10, #"{\#(toolBase),"name":"shell"}"#),
            envelope("session.execution.succeeded", 20, #"{"sessionID":"ses_1"}"#),
            envelope("session.execution.started", 9, #"{"sessionID":"ses_1"}"#),
            envelope("session.execution.succeeded", 15, #"{"sessionID":"ses_1"}"#),
        ]
        for event in events { _ = EventReducer.reduce(event, into: &state, now: now) }
        let call = state.messages["msg_a"]?.parts.first?.content.toolCall
        #expect(call?.status == .completed)
        #expect(call?.name == "shell")
        #expect(call?.outputText == "done")
        #expect(state.sessions["ses_1"]?.idleAt == Fixtures.t(20))
        #expect(state.sessions["ses_1"]?.isRunning == false)
    }

    @Test func unknownEventsAreIgnored() {
        var state = ProjectionState()
        let frames = [
            #"{"id":"evt_1","type":"something.new","data":{"x":1}}"#,
            #"{"id":"evt_2","type":"session.created","data":{"broken":true}}"#,
            #"not json"#,
        ]
        for frame in frames {
            let reduction = EventReducer.reduce(OpenCodeEventDecoder().decode(Data(frame.utf8)), into: &state, now: now)
            #expect(reduction.isEmpty)
        }
    }

    @Test func optimisticSendIsReconciledWithoutDuplicates() {
        var state = ProjectionState()
        var reduction = Reduction()
        state.putSession(Fixtures.session("ses_1"), into: &reduction)
        var optimistic = Fixtures.userMessage("msg_mine", session: "ses_1", text: "hello", at: 100)
        optimistic.delivery = .sending
        state.putMessage(optimistic, persist: true, into: &reduction)
        func envelope(_ type: String, _ data: String) -> OpenCodeEventEnvelope {
            OpenCodeEventDecoder().decode(Data(#"{"id":"evt_\#(type)","created":50,"type":"\#(type)","data":\#(data)}"#.utf8))
        }
        _ = EventReducer.reduce(
            envelope("session.inbox.enqueued", #"{"sessionID":"ses_1","inboxID":"msg_mine","item":{"type":"user","payload":{"text":"hello"},"delivery":"steer"}}"#),
            into: &state, now: now)
        #expect(state.messages["msg_mine"]?.delivery == .accepted)
        #expect(state.queue.isEmpty, "our own prompt must not also appear as queued")
        _ = EventReducer.reduce(envelope("session.inbox.delivered", #"{"sessionID":"ses_1","inboxID":"msg_mine"}"#), into: &state, now: now)
        #expect(state.messages["msg_mine"]?.delivery == .delivered)
        #expect(state.messages.messages(in: "ses_1").count == 1)

        // The list endpoint's copy merges onto the same row.
        let server = Fixtures.userMessage("msg_mine", session: "ses_1", text: "hello", at: 50)
        let merged = SnapshotMerge.message(local: state.messages["msg_mine"], server: server)
        #expect(merged.delivery == .delivered)
        #expect(merged.created == Fixtures.t(50))
    }

    @Test func promptFromElsewhereQueuesThenDelivers() {
        var state = ProjectionState()
        var reduction = Reduction()
        state.putSession(Fixtures.session("ses_1"), into: &reduction)
        func envelope(_ type: String, _ data: String) -> OpenCodeEventEnvelope {
            OpenCodeEventDecoder().decode(Data(#"{"id":"evt_\#(type)","created":70,"type":"\#(type)","data":\#(data)}"#.utf8))
        }
        _ = EventReducer.reduce(
            envelope("session.inbox.enqueued", #"{"sessionID":"ses_1","inboxID":"msg_q","item":{"type":"user","payload":{"text":"later"},"delivery":"queue"}}"#),
            into: &state, now: now)
        #expect(state.queue["msg_q"]?.delivery == .queue)
        #expect(state.queue["msg_q"]?.text == "later")
        let delivered = EventReducer.reduce(envelope("session.inbox.delivered", #"{"sessionID":"ses_1","inboxID":"msg_q"}"#), into: &state, now: now)
        #expect(state.queue.isEmpty)
        if case .user(let content) = state.messages["msg_q"]?.kind { #expect(content.text == "later") } else { Issue.record("no message") }
        #expect(delivered.effects.isEmpty)
    }

    @Test func fullTourScriptMatchesListEndpoints() async throws {
        let harness = try await MockHarness.start()
        let created = try await harness.client.createSession(SessionCreateRequest(directory: "/tmp/mock-project"))
        _ = try await harness.client.prompt(sessionID: created.id, PromptRequest(text: "tour #script:full-tour"))
        try await harness.answerFullTour(sessionID: created.id)
        await harness.server.waitUntilAllIdle()

        var pipeline = EventPipeline()
        _ = run(await harness.publishedEnvelopes(), pipeline: &pipeline)
        let sessions = try await harness.client.sessions(SessionListQuery(limit: 50)).data
        #expect(Set(pipeline.state.sessions.keys) == Set(sessions.map { SessionID($0.id) }))
        #expect(sessions.count == 2, "the tour starts one sub-agent session")
        for session in sessions {
            let id = SessionID(session.id)
            let listed = try await harness.listedMessages(id)
            #expect(normalized(pipeline.state.messages.messages(in: id)) == normalized(listed))
            #expect(pipeline.state.sessions[id]?.outcome == Mapping.session(session).outcome)
        }
        #expect(pipeline.state.pending.isEmpty)
        let tour = pipeline.state.messages.messages(in: SessionID(created.id))
        let subagent = tour.flatMap(\.parts).compactMap { if case .subagent(let r) = $0.content { r } else { nil } }.first
        #expect(subagent?.childSessionID != nil)
        #expect(subagent?.agent == "explore")
        await harness.stop()
    }

    @Test func failureScriptRecordsTheError() async throws {
        let harness = try await MockHarness.start()
        let created = try await harness.client.createSession(SessionCreateRequest(directory: "/tmp/mock-project"))
        _ = try await harness.client.prompt(sessionID: created.id, PromptRequest(text: "go #script:failure"))
        await harness.server.waitUntilAllIdle()
        var pipeline = EventPipeline()
        _ = run(await harness.publishedEnvelopes(), pipeline: &pipeline)
        let session = try #require(pipeline.state.sessions[SessionID(created.id)])
        #expect(session.outcome == .failed)
        #expect(session.lastError?.message == "Rate limit exceeded")
        let listed = try await harness.listedMessages(session.id)
        #expect(normalized(pipeline.state.messages.messages(in: session.id)) == normalized(listed))
        await harness.stop()
    }
}

@Suite("StreamCoalescer", .timeLimit(.minutes(3)))
struct StreamCoalescerTests {
    private let key = StreamKey(sessionID: "ses_1", messageID: "msg_1", kind: .text(ordinal: 0))

    @Test func flushIsDueOneCadenceAfterTheFirstPendingDelta() {
        var coalescer = StreamCoalescer(cadence: .milliseconds(33))
        #expect(coalescer.append("a", for: key, now: .milliseconds(100)) == .milliseconds(133))
        #expect(coalescer.append("b", for: key, now: .milliseconds(110)) == nil)
        #expect(!coalescer.isDue(now: .milliseconds(132)))
        #expect(coalescer.isDue(now: .milliseconds(133)))
        #expect(coalescer.takeAll() == [StreamCoalescer.Flush(key: key, text: "ab")])
        #expect(coalescer.isEmpty)
        #expect(!coalescer.isDue(now: .seconds(10)))
        #expect(coalescer.append("c", for: key, now: .milliseconds(200)) == .milliseconds(233))
    }

    @Test func neverDropsOrReordersContent() {
        var coalescer = StreamCoalescer(cadence: .milliseconds(33))
        let other = StreamKey(sessionID: "ses_1", messageID: "msg_1", kind: .reasoning(ordinal: 0))
        var expected = ""
        var flushed: [StreamKey: String] = [:]
        for index in 0..<10_000 {
            let piece = "\(index),"
            expected += piece
            coalescer.append(piece, for: key, now: .milliseconds(index))
            coalescer.append("r", for: other, now: .milliseconds(index))
            if coalescer.isDue(now: .milliseconds(index)) {
                for flush in coalescer.takeAll() { flushed[flush.key, default: ""] += flush.text }
            }
        }
        for flush in coalescer.takeAll() { flushed[flush.key, default: ""] += flush.text }
        #expect(flushed[key] == expected)
        #expect(flushed[other]?.count == 10_000)
    }

    @Test func commitsAreBoundedByCadence() {
        // 1,000 deltas per second for one second at a 33 ms cadence: about 30 commits, not 1,000.
        var coalescer = StreamCoalescer(cadence: .milliseconds(33))
        var commits = 0
        for millisecond in 0..<1000 {
            coalescer.append("x", for: key, now: .milliseconds(millisecond))
            if coalescer.isDue(now: .milliseconds(millisecond)) {
                _ = coalescer.takeAll()
                commits += 1
            }
        }
        #expect((28...31).contains(commits))
    }

    @Test func perMessageFlushLeavesOthersPending() {
        var coalescer = StreamCoalescer()
        let second = StreamKey(sessionID: "ses_1", messageID: "msg_2", kind: .text(ordinal: 0))
        coalescer.append("one", for: key, now: .zero)
        coalescer.append("two", for: second, now: .zero)
        #expect(coalescer.take(messageID: "msg_1").map(\.text) == ["one"])
        #expect(!coalescer.isEmpty)
        #expect(coalescer.take(sessionID: "ses_1").map(\.text) == ["two"])
        #expect(coalescer.isEmpty)
    }

    @Test func oversizedBacklogIsDueImmediately() {
        var coalescer = StreamCoalescer(cadence: .seconds(10), maxPendingBytes: 100)
        coalescer.append(String(repeating: "x", count: 150), for: key, now: .zero)
        #expect(coalescer.isDue(now: .zero))
    }

    @Test func pipelineFlushesABlockWhenItEnds() {
        var pipeline = EventPipeline(cadence: .seconds(10))
        func envelope(_ id: String, _ type: String, _ data: String) -> OpenCodeEventEnvelope {
            OpenCodeEventDecoder().decode(Data(#"{"id":"\#(id)","created":1,"type":"\#(type)","data":\#(data)}"#.utf8))
        }
        let base = #""sessionID":"ses_1","assistantMessageID":"msg_1","ordinal":0"#
        _ = pipeline.ingest(envelope("e1", "session.text.started", "{\(base)}"), clock: .zero, now: Timestamp(milliseconds: 1))
        let quiet = pipeline.ingest(envelope("e2", "session.text.delta", #"{\#(base),"delta":"Hel"}"#), clock: .zero, now: Timestamp(milliseconds: 1))
        #expect(quiet.changes.isEmpty, "a delta alone does not publish")
        _ = pipeline.ingest(envelope("e3", "session.text.delta", #"{\#(base),"delta":"lo"}"#), clock: .zero, now: Timestamp(milliseconds: 1))
        let ended = pipeline.ingest(envelope("e4", "session.text.ended", #"{\#(base),"text":"Hello"}"#), clock: .zero, now: Timestamp(milliseconds: 1))
        #expect(ended.writes.messages.last?.parts.first?.content == .text("Hello"))
        #expect(pipeline.coalescer.isEmpty)
        #expect(pipeline.state.messages["msg_1"]?.parts.first?.isStreaming == false)
    }
}
