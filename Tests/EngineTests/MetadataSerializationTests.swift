import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// Deep review 1, C9: two metadata updates of one session from the app never lose each other.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct MetadataSerializationTests {
    @Test func concurrentUpdatesOfOneSessionKeepBoth() async throws {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-project")
        let core = engine.core
        // The first update's read is answered only when the test says so.
        await harness.server.injectHTTPFault(
            HTTPFault(method: "GET", pathPrefix: "/api/session/\(session.id.rawValue)", action: .holdResponse(gate: "read"), count: 1))
        @Sendable func append(_ tag: String) -> @Sendable (RawJSON?) -> [String: Any] {
            { raw in
                var object = raw.flatMap { try? JSONSerialization.jsonObject(with: Data($0.text.utf8)) as? [String: Any] } ?? [:]
                object["tags"] = ((object["tags"] as? [String]) ?? []) + [tag]
                return object
            }
        }
        let first = Task { try await core.mergeSessionMetadata(session.id, append("a")) }
        #expect(await waitUntilAsync(timeout: .seconds(10)) { await harness.server.heldResponseCount(gate: "read") == 1 }, "first read held")
        let second = Task { try await core.mergeSessionMetadata(session.id, append("b")) }
        #expect(await waitUntilAsync(timeout: .seconds(10)) { await core.metadataWaiterCount(session.id) == 1 }, "second waits its turn")
        await harness.server.releaseResponses(gate: "read")
        try await first.value
        try await second.value
        let stored = try await harness.client.session(session.id.rawValue).metadata
        let tags = (try stored.map { try JSONSerialization.jsonObject(with: try $0.encodedData()) } as? [String: Any])?["tags"] as? [String]
        #expect(tags == ["a", "b"], "neither update was lost")
        await engine.stop()
        await harness.stop()
    }
}
