import Foundation
import Synchronization
import Testing
@testable import OpenCodeKit

/// Plays a script of connections: each either fails before opening, or opens, sends chunks and then ends.
final class ScriptedConnector: EventStreamConnector {
    enum Ending: Sendable {
        case close
        case fail
        /// Stays open until cancelled.
        case hold
    }

    enum Connection: Sendable {
        case refuse
        case open(chunks: [[UInt8]], then: Ending)
    }

    private let script: Mutex<[Connection]>
    private let attemptCount = Mutex(0)

    init(_ script: [Connection]) {
        self.script = Mutex(script)
    }

    var attempts: Int { attemptCount.withLock { $0 } }

    struct Refused: Error {}

    func stream(
        onOpen: @escaping @Sendable () async -> Void,
        onChunk: @escaping @Sendable ([UInt8]) async throws -> Void
    ) async throws {
        attemptCount.withLock { $0 += 1 }
        let connection = script.withLock { $0.isEmpty ? .open(chunks: [], then: .hold) : $0.removeFirst() }
        switch connection {
        case .refuse:
            throw Refused()
        case .open(let chunks, let ending):
            await onOpen()
            for chunk in chunks { try await onChunk(chunk) }
            switch ending {
            case .close: return
            case .fail: throw Refused()
            case .hold:
                while true { try await Task.sleep(for: .seconds(60)) }
            }
        }
    }
}

/// Splits bytes into chunks of pseudo-random sizes.
func randomChunks(_ bytes: [UInt8], seed: UInt64, maxLength: Int = 97) -> [[UInt8]] {
    var generator = SeededGenerator(seed: seed)
    var chunks: [[UInt8]] = []
    var index = 0
    while index < bytes.count {
        let end = min(bytes.count, index + Int.random(in: 1...maxLength, using: &generator))
        chunks.append(Array(bytes[index..<end]))
        index = end
    }
    return chunks
}

func frame(_ json: String) -> [UInt8] { Array("data: \(json)\n\n".utf8) }

func deltaFrame(session: String, index: Int) -> [UInt8] {
    frame(#"{"id":"evt_\#(index)","type":"session.text.delta","data":{"sessionID":"\#(session)","assistantMessageID":"msg_1","ordinal":0,"delta":"\#(index)"}}"#)
}

@Suite("EventHub")
struct EventHubTests {
    private let fastBackoff = BackoffPolicy(initial: .milliseconds(1), maximum: .milliseconds(5), jitter: 0)

    @Test func deliversResyncThenRecordedEventsInOrder() async throws {
        let sample = Array(try Repo.eventsSample)
        let connector = ScriptedConnector([.open(chunks: randomChunks(sample, seed: 7), then: .hold)])
        let hub = EventHub(connector: connector, backoff: fastBackoff)
        let subscription = await hub.subscribe()
        await hub.start()

        let messages = try await within(.seconds(5)) {
            var iterator = subscription.makeAsyncIterator()
            var received: [EventHubMessage] = []
            while received.count < 51, let message = await iterator.next() { received.append(message) }
            return received
        }
        guard case .resync(.connected(connection: 1)) = messages.first else {
            Issue.record("first message must be .resync(.connected(1)), got \(String(describing: messages.first))")
            await hub.stop()
            return
        }
        let types = messages.dropFirst().compactMap(\.envelope?.type)
        var parser = SSEParser()
        let expected = try parser.feed(sample).map { OpenCodeEventDecoder().decode(Data($0.data.utf8)).type }
        #expect(types == expected)
        let statistics = await hub.statistics
        #expect(statistics.frames == 50)
        #expect(statistics.unknownFrames == 0)
        await hub.stop()
    }

    @Test func reconnectEmitsDisconnectedThenResync() async throws {
        let connector = ScriptedConnector([
            .open(chunks: [deltaFrame(session: "ses_1", index: 1)], then: .close),
            .refuse,
            .open(chunks: [deltaFrame(session: "ses_1", index: 2)], then: .hold),
        ])
        let hub = EventHub(connector: connector, backoff: fastBackoff)
        let subscription = await hub.subscribe()
        await hub.start()

        let messages = try await within(.seconds(5)) {
            var iterator = subscription.makeAsyncIterator()
            return await collect(&iterator) { $0.envelope?.id == "evt_2" }
        }
        let summary = messages.map { message -> String in
            switch message {
            case .resync(.connected(let n)): "resync\(n)"
            case .resync(.overflow): "overflow"
            case .disconnected: "disconnected"
            case .event(let envelope): envelope.id ?? "?"
            }
        }
        #expect(summary == ["resync1", "evt_1", "disconnected", "disconnected", "resync2", "evt_2"])
        #expect(connector.attempts == 3)
        await hub.stop()
    }

    @Test func sessionFilterRoutesOnlyThatSessionPlusSignals() async throws {
        let chunks = [
            deltaFrame(session: "ses_a", index: 1),
            deltaFrame(session: "ses_b", index: 2),
            frame(#"{"id":"evt_3","type":"provider.updated","data":{}}"#),
            deltaFrame(session: "ses_a", index: 4),
        ]
        let hub = EventHub(connector: ScriptedConnector([.open(chunks: chunks, then: .hold)]), backoff: fastBackoff)
        let onlyA = await hub.subscribe(.session("ses_a"))
        let everything = await hub.subscribe(.all)
        await hub.start()

        let a = try await within(.seconds(5)) {
            var iterator = onlyA.makeAsyncIterator()
            return await collect(&iterator) { $0.envelope?.id == "evt_4" }
        }
        #expect(a.first?.isResync == true)
        #expect(a.compactMap(\.envelope?.id) == ["evt_1", "evt_4"])

        let all = try await within(.seconds(5)) {
            var iterator = everything.makeAsyncIterator()
            return await collect(&iterator) { $0.envelope?.id == "evt_4" }
        }
        #expect(all.compactMap(\.envelope?.id) == ["evt_1", "evt_2", "evt_3", "evt_4"])
        await hub.stop()
    }

    @Test func slowSubscriberGetsOverflowResyncNotSilentLoss() async throws {
        let chunks = (1...40).map { deltaFrame(session: "ses_1", index: $0) }
        let connector = ScriptedConnector([.open(chunks: chunks, then: .hold)])
        let hub = EventHub(connector: connector, backoff: fastBackoff)
        let slow = await hub.subscribe(bufferLimit: 8)
        let fast = await hub.subscribe()
        await hub.start()

        // Wait for every frame to be dispatched before the slow subscriber reads anything.
        try await eventually { await hub.statistics.frames == 40 }

        let slowMessages = try await within(.seconds(5)) {
            var iterator = slow.makeAsyncIterator()
            return await collect(&iterator) { $0.envelope?.id == "evt_40" }
        }
        // Whatever was discarded is announced: an overflow marker precedes the surviving tail, which is contiguous.
        guard let marker = slowMessages.firstIndex(where: { if case .resync(.overflow) = $0 { true } else { false } }) else {
            Issue.record("expected an overflow resync")
            await hub.stop()
            return
        }
        let tail = slowMessages[(marker + 1)...].compactMap(\.envelope?.id)
        let expectedTail = (41 - tail.count...40).map { "evt_\($0)" }
        #expect(tail == expectedTail)
        #expect(slowMessages.count <= 8)
        #expect(slow.overflowCount >= 1)
        #expect(await hub.statistics.overflows >= 1)

        // The other subscriber is unaffected.
        let fastMessages = try await within(.seconds(5)) {
            var iterator = fast.makeAsyncIterator()
            return await collect(&iterator) { $0.envelope?.id == "evt_40" }
        }
        #expect(fastMessages.compactMap(\.envelope).count == 40)
        await hub.stop()
    }

    @Test func serverStreamFailureEventForcesReconnect() async throws {
        let failure = Array("event: effect/http-api/stream/failure\ndata: []\n\n".utf8)
        let connector = ScriptedConnector([
            .open(chunks: [deltaFrame(session: "s", index: 1), failure, deltaFrame(session: "s", index: 99)], then: .hold),
            .open(chunks: [deltaFrame(session: "s", index: 2)], then: .hold),
        ])
        let hub = EventHub(connector: connector, backoff: fastBackoff)
        let subscription = await hub.subscribe()
        await hub.start()
        let messages = try await within(.seconds(5)) {
            var iterator = subscription.makeAsyncIterator()
            return await collect(&iterator) { $0.envelope?.id == "evt_2" }
        }
        #expect(messages.compactMap(\.envelope?.id) == ["evt_1", "evt_2"])
        #expect(messages.filter(\.isResync).count == 2)
        await hub.stop()
    }

    @Test func oversizedFrameDropsTheConnectionAndResyncs() async throws {
        let huge = frame(String(repeating: "x", count: 2000))
        let connector = ScriptedConnector([
            .open(chunks: [huge], then: .hold),
            .open(chunks: [deltaFrame(session: "s", index: 1)], then: .hold),
        ])
        let hub = EventHub(connector: connector, backoff: fastBackoff, maxEventBytes: 1024)
        let subscription = await hub.subscribe()
        await hub.start()
        let messages = try await within(.seconds(5)) {
            var iterator = subscription.makeAsyncIterator()
            return await collect(&iterator) { $0.envelope?.id == "evt_1" }
        }
        #expect(messages.filter(\.isResync).count == 2)
        #expect(messages.contains { if case .disconnected = $0 { true } else { false } })
        await hub.stop()
    }

    @Test func backoffGrowsOnFailuresAndResetsAfterAConnection() async throws {
        let time = ManualTimeSource()
        let connector = ScriptedConnector([.refuse, .refuse, .refuse, .open(chunks: [], then: .close), .refuse])
        let policy = BackoffPolicy(initial: .milliseconds(100), maximum: .milliseconds(300), jitter: 0)
        let hub = EventHub(connector: connector, backoff: policy, time: time, random: { 0.5 })
        await hub.start()
        for _ in 0..<5 {
            try await time.waitForSleepers()
            time.advance(by: .seconds(1))
        }
        try await eventually { await hub.connectionState == .connected(connection: 2) }
        #expect(connector.attempts == 6)
        #expect(time.requestedSleeps == [100, 200, 300, 100, 200].map { Duration.milliseconds($0) })
        await hub.stop()
    }

    @Test func stopEndsSubscriptionsAndLaterSubscriptionsAreFinished() async throws {
        let hub = EventHub(connector: ScriptedConnector([]), backoff: fastBackoff)
        let subscription = await hub.subscribe()
        await hub.start()
        try await eventually { await hub.connectionState == .connected(connection: 1) }
        await hub.stop()
        let drained = try await within(.seconds(5)) {
            var iterator = subscription.makeAsyncIterator()
            var count = 0
            while await iterator.next() != nil { count += 1 }
            return count
        }
        #expect(drained == 1)  // the initial resync
        let late = await hub.subscribe()
        var iterator = late.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(await hub.connectionState == .stopped)
    }

    @Test func cancellingTheConsumerUnsubscribes() async throws {
        let hub = EventHub(connector: ScriptedConnector([]), backoff: fastBackoff)
        let subscription = await hub.subscribe()
        await hub.start()
        let consumer = Task {
            var count = 0
            for await _ in subscription { count += 1 }
            return count
        }
        try await eventually { await hub.connectionState == .connected(connection: 1) }
        consumer.cancel()
        _ = await consumer.value
        #expect(subscription.mailbox.isTerminated)
        await hub.stop()
    }
}

@Suite("Subscriber mailbox")
struct MailboxTests {
    private func event(_ id: String) -> EventHubMessage {
        .event(OpenCodeEventDecoder().decode(Data(#"{"id":"\#(id)","type":"x","data":{}}"#.utf8)))
    }

    @Test func overflowReplacesBufferWithMarker() async {
        let mailbox = Mailbox(filter: .all, limit: 3)
        for id in ["a", "b", "c", "d", "e"] { mailbox.push(event(id)) }
        mailbox.finish()
        var received: [String] = []
        while let message = await mailbox.next() {
            switch message {
            case .resync(.overflow): received.append("overflow")
            case .event(let envelope): received.append(envelope.id ?? "")
            default: received.append("other")
            }
        }
        #expect(received == ["overflow", "d", "e"])
        #expect(mailbox.overflowCount == 1)
    }

    @Test func pushAfterTerminateReportsDeadConsumer() {
        let mailbox = Mailbox(filter: .all, limit: 4)
        #expect(mailbox.push(event("a")))
        mailbox.terminate()
        #expect(!mailbox.push(event("b")))
    }

    @Test func waitingConsumerReceivesDirectly() async throws {
        let mailbox = Mailbox(filter: .all, limit: 2)
        let reader = Task { await mailbox.next() }
        try await Task.sleep(for: .milliseconds(20))
        mailbox.push(event("x"))
        let message = await reader.value
        #expect(message?.envelope?.id == "x")
    }
}
