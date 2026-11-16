import BelloCore
import Darwin
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// Resident memory of this process, in MB.
func residentMegabytes() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
}

func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

@Suite("Performance", .serialized)
@MainActor
struct PerformanceTests {
    @Test func tenThousandMessageThread() async throws {
        let clock = ContinuousClock()
        let scenario = Scenario.large(seed: 42, projectCount: 2, sessionCount: 10, largeSessionMessages: 10_000)
        let harness = try await MockHarness.start(scenario)
        let directory = Fixtures.temporaryDirectory()
        let engine = try makeEngine(harness, store: .file(directory.appending(path: "projection.sqlite")))
        await engine.start()
        try await waitUntil("live", timeout: .seconds(60)) { engine.root.connection == .live }
        let sessions = await engine.core.projectionForTesting.sessions
        let large = try #require(sessions.values.first { $0.title == FixtureGenerator.largeSessionTitle })

        // 1. First open with an empty cache: the newest window comes from the server.
        var start = clock.now
        var thread = engine.openThread(large.id)
        try await waitUntil("server window", timeout: .seconds(30)) { thread.messageIDs.count == 50 }
        let openFromServer = clock.now - start
        try await waitUntil("has older") { thread.hasOlder }

        // 2. Paging older from the server.
        var serverPages: [Duration] = []
        for _ in 0..<3 {
            start = clock.now
            await thread.loadOlder()
            serverPages.append(clock.now - start)
        }
        #expect(thread.messageIDs.count == 200)
        #expect(thread.lastError == nil)
        let ids = thread.messageIDs
        #expect(Set(ids).count == ids.count, "no duplicates across pages")
        thread.close()

        // 3. Fill the cache with the whole transcript (as months of use would), then reopen from disk.
        var all: [Message] = []
        var cursor: String?
        repeat {
            let page = try await harness.client.messages(
                sessionID: large.id.rawValue, MessageListQuery(limit: 1000, order: cursor == nil ? .descending : nil, cursor: cursor))
            all += page.data.map { Mapping.message($0, sessionID: large.id) }
            cursor = page.data.count < 1000 ? nil : page.cursor.next
        } while cursor != nil
        #expect(all.count == 10_000)
        var batch = StoreBatch()
        batch.messages = all
        batch.syncStates = [SessionSyncState(sessionID: large.id, historyComplete: true)]
        start = clock.now
        try await engine.store.apply(batch, publish: false)
        let writeAll = clock.now - start
        #expect(try await engine.store.messageCount(sessionID: large.id) == 10_000)

        var reads: [Duration] = []
        for _ in 0..<10 {
            start = clock.now
            _ = try await engine.store.latestMessages(sessionID: large.id, limit: 50)
            reads.append(clock.now - start)
        }

        let memoryBefore = residentMegabytes()
        start = clock.now
        thread = engine.openThread(large.id)
        try await waitUntil("cached window") { thread.phase == .ready && thread.messageIDs.count >= 50 }
        let openFromCache = clock.now - start

        var cachePages: [Duration] = []
        for _ in 0..<20 {
            start = clock.now
            await thread.loadOlder()
            cachePages.append(clock.now - start)
        }
        #expect(thread.messageIDs.count == 50 + 20 * 50)
        #expect(thread.loadedMessageCount == thread.messageIDs.count)
        let memoryAfter = residentMegabytes()
        let cacheCount = await engine.core.projectionForTesting.messages.count
        #expect(cacheCount <= engine.configuration.messageCacheCapacity)

        let average = { (values: [Duration]) in values.map(milliseconds).reduce(0, +) / Double(max(1, values.count)) }
        print(
            """
            10k fixture: open (server window) \(String(format: "%.1f", milliseconds(openFromServer))) ms; \
            server page avg \(String(format: "%.1f", average(serverPages))) ms; \
            write 10,000 messages \(String(format: "%.0f", milliseconds(writeAll))) ms; \
            store read of 50 avg \(String(format: "%.2f", average(reads))) ms; \
            open cached thread \(String(format: "%.1f", milliseconds(openFromCache))) ms; \
            cached page avg \(String(format: "%.2f", average(cachePages))) ms; \
            resident \(String(format: "%.0f", memoryBefore)) -> \(String(format: "%.0f", memoryAfter)) MB with \
            \(thread.messageIDs.count) messages loaded; engine message cache \(cacheCount)
            """)
        thread.close()
        await engine.stop()
        await harness.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func sustainedEventThroughput() async throws {
        // Engine processing alone: decode + dedupe + coalesce + reduce + publish + attention, no network.
        let store = try ProjectionStore(location: .inMemory)
        var configuration = EngineConfiguration(server: .dynamic { nil }, store: .inMemory)
        configuration.writeInterval = .milliseconds(50)
        let core = EngineCore(configuration: configuration, store: store)
        let subscription = store.observe(.thread("ses_perf"))
        let decoder = OpenCodeEventDecoder()
        func frame(_ index: Int, _ type: String, _ data: String) -> OpenCodeEventEnvelope {
            decoder.decode(Data(#"{"id":"evt_\#(index)","created":\#(1000 + index),"type":"\#(type)","data":\#(data)}"#.utf8))
        }
        var frames: [OpenCodeEventEnvelope] = []
        var index = 0
        frames.append(frame(index, "session.created", #"{"sessionID":"ses_perf","projectID":"p","location":{"directory":"/tmp/p"}}"#))
        for message in 0..<50 {
            let base = #""sessionID":"ses_perf","assistantMessageID":"msg_\#(message)""#
            index += 1
            frames.append(frame(index, "session.step.started", #"{\#(base),"agent":"build","model":{"id":"m","providerID":"p"}}"#))
            index += 1
            frames.append(frame(index, "session.text.started", #"{\#(base),"ordinal":0}"#))
            for _ in 0..<1000 {
                index += 1
                frames.append(frame(index, "session.text.delta", #"{\#(base),"ordinal":0,"delta":"tok "}"#))
            }
            index += 1
            frames.append(frame(index, "session.text.ended", #"{\#(base),"ordinal":0,"text":"done"}"#))
            index += 1
            frames.append(frame(index, "session.step.ended", #"{\#(base),"finish":"stop"}"#))
        }
        let clock = ContinuousClock()
        let start = clock.now
        for envelope in frames { await core.handle(envelope) }
        await core.flush()
        let elapsed = clock.now - start
        let perSecond = Double(frames.count) / (milliseconds(elapsed) / 1000)
        #expect(subscription.poll() != nil)
        #expect(try await store.messageCount(sessionID: "ses_perf") == 50)
        print("throughput: \(frames.count) events in \(String(format: "%.0f", milliseconds(elapsed))) ms = \(String(format: "%.0f", perSecond)) events/s (engine only)")

        // End to end against the mock: streamed bursts through HTTP, SSE parsing, EventHub and the engine.
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-project")
        let thread = engine.openThread(session.id)
        let eventsBefore = await engine.core.statistics.events
        let e2eStart = clock.now
        for _ in 0..<3 {
            await thread.send("go #script:burst")
            await harness.server.waitUntilIdle(session.id.rawValue)
        }
        let published = await harness.server.publishedEvents().count
        try await waitUntil("all events applied", timeout: .seconds(30)) {
            thread.status?.status == .finishedUnread && thread.messageIDs.count >= 6
        }
        await engine.flush()
        let e2e = clock.now - e2eStart
        let processed = await engine.core.statistics.events - eventsBefore
        print("throughput: \(processed) events end to end in \(String(format: "%.0f", milliseconds(e2e))) ms = \(String(format: "%.0f", Double(processed) / (milliseconds(e2e) / 1000))) events/s (mock published \(published))")
        let listed = try await harness.listedMessages(session.id)
        #expect(normalized(thread.messageIDs.compactMap { thread.message($0)?.message }) == normalized(listed))
        thread.close()
        await engine.stop()
        await harness.stop()
    }
}
