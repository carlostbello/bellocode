import Foundation
import Testing
@testable import MockOpenCode

@Suite("Fault injection and concurrency")
struct FaultTests {
    static let realTime = MockServerOptions(clock: .realTime, heartbeatInterval: nil)

    func withServer(
        options: MockServerOptions = .testing, _ body: (MockOpenCodeServer, TestClient) async throws -> Void
    ) async throws {
        let server = MockOpenCodeServer(scenario: .empty(), options: options)
        let client = TestClient(try await server.start())
        do {
            try await body(server, client)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    @Test func dropMidStreamThenResync() async throws {
        try await withServer { server, client in
            let reader = EventReader(client)
            try await reader.connected()
            let session = try await client.createSession()
            await server.enqueueScript(
                TurnScript {
                    TurnStep.text("before the drop")
                    TurnStep.dropEventStreams
                    TurnStep.text("after the drop")
                })
            _ = try await client.prompt(session, "go")
            var seen: [String] = []
            while let event = try await reader.next() { seen.append(event.type) }
            #expect(seen.contains("session.text.ended"))
            #expect(!seen.contains("session.execution.succeeded"))
            // Events published while nobody listened are gone; the list endpoints have the full state.
            await server.waitUntilIdle(session)
            let messages = try await client.get("/api/session/\(session)/message?order=asc")["data"]?.arrayValue ?? []
            let texts = messages.last?["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }
            #expect(texts == ["before the drop", "after the drop"])
            // A new subscription works.
            let again = EventReader(client)
            try await again.connected()
            _ = try await client.createSession()
            #expect(try await again.next()?.type == "session.created")
            again.cancel()
        }
    }

    @Test func dropAfterFrameCount() async throws {
        try await withServer { server, client in
            await server.dropEventStreams(afterFrames: 5)
            let reader = EventReader(client)
            _ = try await client.createSession()
            await server.enqueueScript(.burst)
            _ = try await client.prompt(try await client.createSession(), "go")
            var count = 0
            while try await reader.next() != nil { count += 1 }
            // server.connected and the heartbeat count toward the five frames; the heartbeat is a comment.
            #expect(count == 4)
            await server.dropEventStreams(afterFrames: nil)
        }
    }

    @Test(arguments: [ByteSplitting.fixed(1), .fixed(7), .seeded(seed: 99, maxPiece: 13)])
    func splitBytesAtArbitraryBoundaries(_ splitting: ByteSplitting) async throws {
        try await withServer { server, client in
            await server.setEventSplitting(splitting)
            let raw = try await RawConnection(port: UInt16(client.endpoint.url.port!))
            try await raw.send(
                "GET /api/event HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: \(client.endpoint.authorizationHeader!)\r\n\r\n")
            var decoder = ChunkDecoder()
            var parser = SSEParser()
            var events: [JSONValue] = []
            var prompted = false
            while !events.contains(where: { $0.type == "session.execution.succeeded" }) {
                guard let data = await raw.receive() else { throw TestError("stream closed") }
                let before = decoder.payload.count
                decoder.feed(data)
                for text in parser.feed(decoder.payload[before...]) { events.append(try JSONValue.parse(text)) }
                if !prompted, events.contains(where: { $0.type == "server.connected" }) {
                    prompted = true
                    let session = try await client.createSession()
                    await server.enqueueScript(
                        TurnScript { TurnStep.text("Multi-byte: é 🚀 日本語 👩‍👩‍👧 done", chunkSize: 3, rate: 200) })
                    _ = try await client.prompt(session, "go")
                }
            }
            raw.close()
            #expect(decoder.head.hasPrefix("HTTP/1.1 200 OK"))
            #expect(decoder.head.contains("content-type: text/event-stream"))
            switch splitting {
            case let .fixed(n): #expect(decoder.chunkSizes.allSatisfy { $0 <= n })
            case let .seeded(_, maxPiece): #expect(decoder.chunkSizes.allSatisfy { $0 <= maxPiece })
            case .none: break
            }
            #expect(decoder.chunkSizes.max()! <= 13)
            let deltas = events.filter { $0.type == "session.text.delta" }.compactMap { $0["data"]?["delta"]?.stringValue }
            #expect(deltas.joined() == "Multi-byte: é 🚀 日本語 👩‍👩‍👧 done")
        }
    }

    @Test func duplicateEventKeepsItsID() async throws {
        try await withServer { server, client in
            let reader = EventReader(client)
            try await reader.connected()
            await server.duplicateNextEvent()
            _ = try await client.createSession()
            _ = try await client.createSession()
            let a = try #require(try await reader.next())
            let b = try #require(try await reader.next())
            let c = try #require(try await reader.next())
            #expect(a == b)
            #expect(a["id"] == b["id"])
            #expect(c["id"] != a["id"])
            reader.cancel()
        }
    }

    @Test func injectedHTTPErrors() async throws {
        try await withServer { server, client in
            await server.injectHTTPFault(.status(500, method: "GET", pathPrefix: "/api/session", message: "boom"))
            let failed = try await client.request("GET", "/api/session")
            #expect(failed.status == 500)
            #expect(failed.json["message"] == "boom")
            #expect(try await client.request("GET", "/api/session").status == 200)

            await server.injectHTTPFault(
                HTTPFault(pathPrefix: "/api/agent", action: .respond(status: 200, body: "{\"data\":", contentType: "application/json")))
            let malformed = try await client.request("GET", "/api/agent")
            #expect(malformed.status == 200)
            #expect(throws: (any Error).self) { try JSONValue.parse(malformed.body) }

            // URLSession silently retries a request whose reused connection was reset, so keep resetting until cleared.
            await server.injectHTTPFault(HTTPFault(pathPrefix: "/api/provider", action: .resetConnection, count: nil))
            await #expect(throws: (any Error).self) { try await client.request("GET", "/api/provider") }
            await server.clearHTTPFaults()
            #expect(try await client.request("GET", "/api/provider").status == 200)

            await server.injectHTTPFault(.status(503, pathPrefix: "/api/model", count: nil))
            #expect(try await client.request("GET", "/api/model").status == 503)
            #expect(try await client.request("GET", "/api/model").status == 503)
            await server.clearHTTPFaults()
            #expect(try await client.request("GET", "/api/model").status == 200)
        }
    }

    @Test func delayedRequestDoesNotBlockOthers() async throws {
        try await withServer(options: Self.realTime) { server, client in
            await server.injectHTTPFault(HTTPFault(pathPrefix: "/api/agent", action: .delay(.milliseconds(400))))
            let clock = ContinuousClock()
            let start = clock.now
            async let slow = client.request("GET", "/api/agent")
            try await Task.sleep(for: .milliseconds(50))
            let fast = try await client.request("GET", "/api/info")
            let fastElapsed = clock.now - start
            #expect(fast.status == 200)
            #expect(try await slow.status == 200)
            #expect(clock.now - start >= .milliseconds(400))
            #expect(fastElapsed < .milliseconds(350))
        }
    }

    @Test func restartKeepsStateOnANewPort() async throws {
        try await withServer { server, client in
            let reader = EventReader(client)
            try await reader.connected()
            let session = try await client.createSession(title: "survivor")
            let old = client.endpoint
            let new = try await server.restart()
            #expect(new.url != old.url)
            #expect(new.password == old.password)
            // The old stream ends and the old port no longer answers.
            var tail: [String] = []
            while let event = try await reader.next() { tail.append(event.type) }
            await #expect(throws: (any Error).self) { try await client.request("GET", "/api/session") }
            let fresh = TestClient(new)
            let fetched = try await fresh.get("/api/session/\(session)")["data"]
            #expect(fetched?["title"] == "survivor")
        }
    }

    @Test func twoSubscribersSeeTheSameSequence() async throws {
        try await withServer { server, client in
            let a = EventReader(client)
            let b = EventReader(client, query: "")
            try await a.connected()
            try await b.connected()
            #expect(await server.subscriberCount == 2)
            let session = try await client.createSession()
            _ = try await client.prompt(session, "#script:burst")
            let first = try await a.collect(until: isType("session.execution.succeeded"))
            let second = try await b.collect(until: isType("session.execution.succeeded"))
            #expect(first.count > 100)
            #expect(first == second)
            a.cancel()
            b.cancel()
        }
    }

    @Test func typeFilterLimitsTheStream() async throws {
        try await withServer { _, client in
            let reader = EventReader(client, query: "?types=session.execution.succeeded&types=session.created")
            try await reader.connected()
            let session = try await client.createSession()
            _ = try await client.prompt(session, "hi")
            #expect(try await reader.next()?.type == "session.created")
            #expect(try await reader.next()?.type == "session.execution.succeeded")
            reader.cancel()
        }
    }

    @Test func slowReaderIsDroppedWithoutBlockingOthers() async throws {
        var options = Self.realTime
        options.subscriberQueueLimit = 32
        try await withServer(options: options) { server, client in
            // A subscriber that never reads.
            let stalled = try await RawConnection(port: UInt16(client.endpoint.url.port!))
            try await stalled.send(
                "GET /api/event HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: \(client.endpoint.authorizationHeader!)\r\n\r\n")
            let reader = EventReader(client)
            try await reader.connected()
            while await server.subscriberCount < 2 { try await Task.sleep(for: .milliseconds(5)) }
            let session = try await client.createSession()
            await server.enqueueScript(
                TurnScript { TurnStep.text(String(repeating: "x", count: 8 * 1024 * 1024), chunkSize: 16 * 1024, rate: 1000) })
            _ = try await client.prompt(session, "flood")
            // Requests stay fast while the flood is in progress.
            let clock = ContinuousClock()
            let start = clock.now
            #expect(try await client.request("GET", "/api/info").status == 200)
            #expect(clock.now - start < .milliseconds(500))
            let events = try await reader.collect(until: isType("session.execution.succeeded"), timeout: .seconds(30))
            #expect(events.filter { $0.type == "session.text.delta" }.count == 512)
            #expect(await server.subscriberCount == 1)
            stalled.close()
            reader.cancel()
        }
    }
}
