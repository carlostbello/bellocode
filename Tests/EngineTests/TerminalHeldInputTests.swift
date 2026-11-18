import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// Deep review 1, U3: input typed while a terminal is not attached is held (bounded) and never dropped silently. An
/// input that does not fit is refused whole, everything after it is refused too, and what was held waits for the
/// person instead of being replayed on attach.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct TerminalHeldInputTests {
    func inputs(_ server: MockOpenCodeServer, _ id: String) async -> [String] {
        await server.ptyInputLog(id).filter { $0.hasPrefix("input:") }.map { String($0.dropFirst(6)) }
    }

    @Test func heldInputIsSentOnAttach() async throws {
        let fixture = try await TerminalServiceTests.Fixture.start()
        let terminals = fixture.service.terminals(for: fixture.sessionID)
        let record = try #require(await terminals.create(directory: "/tmp/mock-project", size: PTYSize(cols: 80, rows: 24)))
        let stream = fixture.service.makeStream(record.id, in: terminals, sink: RecordingSink())
        stream.resize(to: PTYSize(cols: 80, rows: 24))
        #expect(stream.send(Array("echo held\r".utf8)) == .held)
        #expect(stream.heldInputBytes == 10)
        stream.activate()
        try await waitFor("live") { stream.status == .live }
        try await waitFor("held input delivered") { await inputs(fixture.harness.server, record.id).joined().contains("echo held\r") }
        #expect(stream.heldInputBytes == 0)
        #expect(stream.send(Array("x".utf8)) == .sent)
        await fixture.stop()
    }

    @Test func overflowIsRefusedVisiblyAndHeldInputWaitsForThePerson() async throws {
        let fixture = try await TerminalServiceTests.Fixture.start()
        let server = fixture.harness.server
        let terminals = fixture.service.terminals(for: fixture.sessionID)
        let record = try #require(await terminals.create(directory: "/tmp/mock-project", size: PTYSize(cols: 80, rows: 24)))
        let stream = fixture.service.makeStream(record.id, in: terminals, sink: RecordingSink())
        stream.resize(to: PTYSize(cols: 80, rows: 24))
        #expect(stream.send(Array("ls".utf8)) == .held)
        // A paste that would exceed the bound is refused whole (nothing of it is kept)...
        let paste = [UInt8](repeating: UInt8(ascii: "a"), count: TerminalStream.pendingInputLimit)
        #expect(stream.send(paste) == .refused)
        #expect(stream.inputOverflowed)
        #expect(stream.heldInputBytes == 2)
        // ...and so is the Return typed after it, though it would fit.
        #expect(stream.send(Array("\r".utf8)) == .refused)
        stream.activate()
        try await waitFor("live") { stream.status == .live }
        try await waitFor("size sent") { await server.ptyInputLog(record.id).contains { $0.hasPrefix("resize:") } }
        #expect(await inputs(server, record.id).isEmpty, "nothing is replayed after an overflow")
        #expect(stream.send(Array("pwd\r".utf8)) == .refused, "still refused until the person chooses")
        // The person sends what was held; typing works again.
        #expect(stream.sendHeldInput())
        #expect(!stream.inputOverflowed)
        #expect(stream.send(Array("\r".utf8)) == .sent)
        try await waitFor("delivered in order") { await inputs(server, record.id).joined().contains("ls\r") }
        await fixture.stop()
    }

    @Test func discardClearsHeldInputAndTheOverflow() async throws {
        let fixture = try await TerminalServiceTests.Fixture.start()
        let terminals = fixture.service.terminals(for: fixture.sessionID)
        let record = try #require(await terminals.create(directory: "/tmp/mock-project", size: PTYSize(cols: 80, rows: 24)))
        let stream = fixture.service.makeStream(record.id, in: terminals, sink: RecordingSink())
        #expect(stream.send(Array("rm -rf build".utf8)) == .held)
        #expect(stream.send([UInt8](repeating: 0x61, count: TerminalStream.pendingInputLimit)) == .refused)
        stream.discardHeldInput()
        #expect(!stream.inputOverflowed && stream.heldInputBytes == 0)
        #expect(stream.send(Array("ok".utf8)) == .held)
        await fixture.stop()
    }
}
