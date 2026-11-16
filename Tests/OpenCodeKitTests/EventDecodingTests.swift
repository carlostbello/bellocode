import Foundation
import Testing
@testable import OpenCodeKit

@Suite("Event decoding")
struct EventDecodingTests {
    private func sampleEnvelopes() throws -> [OpenCodeEventEnvelope] {
        var parser = SSEParser()
        let decoder = OpenCodeEventDecoder()
        return try parser.feed(Array(try Repo.eventsSample)).map { decoder.decode(Data($0.data.utf8)) }
    }

    @Test func everyRecordedEventDecodesToAKnownCase() throws {
        let envelopes = try sampleEnvelopes()
        #expect(envelopes.count == 50)
        let unknown = envelopes.filter(\.event.isUnknown).map(\.type)
        #expect(unknown.isEmpty, "unknown: \(unknown)")
    }

    @Test func recordedTurnHasTheExpectedShape() throws {
        let envelopes = try sampleEnvelopes()
        let session = "ses_e1a4aec0fffeSv6rQPV7c8C5Fl"

        guard case .serverConnected = envelopes[0].event else {
            Issue.record("first frame is not server.connected")
            return
        }
        #expect(envelopes[0].created == nil)

        let created = envelopes.compactMap { envelope -> EventPayload.SessionCreated? in
            if case .sessionCreated(let payload) = envelope.event { payload } else { nil }
        }
        #expect(created.count == 1)
        #expect(created.first?.sessionID == session)
        #expect(created.first?.location.directory.hasSuffix("/oc/proj2") == true)

        // Every session-scoped frame routes to the one session.
        let sessionFrames = envelopes.filter { $0.type.hasPrefix("session.") || $0.type.hasPrefix("permission.") }
        #expect(sessionFrames.allSatisfy { $0.sessionID == session })

        // Text deltas reassemble into the ended text.
        var text = ""
        var ended: String?
        for envelope in envelopes {
            switch envelope.event {
            case .textDelta(let delta): text += delta.delta
            case .textEnded(let end): ended = end.text
            default: break
            }
        }
        #expect(text == ended)
        #expect(ended == "The directory contains: `README.md`.")

        // The tool state machine: input started → input ended → called → progress → success.
        let toolID = "0e998b5f-4e53-499a-bf08-17e601bc44f1"
        let toolEvents = envelopes.compactMap { envelope -> String? in
            switch envelope.event {
            case .toolInputStarted(let p) where p.id == toolID: "input.started:\(p.name)"
            case .toolInputEnded(let p) where p.id == toolID: "input.ended"
            case .toolCalled(let p) where p.id == toolID: "called:\(p.input["command"]?.stringValue ?? "")"
            case .toolProgress(let p) where p.id == toolID: "progress"
            case .toolSucceeded(let p) where p.id == toolID: "success:\(p.content.count)"
            default: nil
            }
        }
        #expect(toolEvents == ["input.started:shell", "input.ended", "called:ls", "progress", "success:1"])

        // Turn boundaries and usage.
        #expect(envelopes.contains { if case .executionStarted = $0.event { true } else { false } })
        #expect(envelopes.contains { if case .executionSucceeded = $0.event { true } else { false } })
        let finishes = envelopes.compactMap { envelope -> FinishReason? in
            if case .stepEnded(let p) = envelope.event { p.finish } else { nil }
        }
        #expect(finishes == [.toolCalls, .stop])
        let usage = envelopes.compactMap { envelope -> Double? in
            if case .usageUpdated(let p) = envelope.event { p.tokens.input } else { nil }
        }
        #expect(usage == [674, 1420])

        // Durable metadata survives on durable frames only.
        #expect(envelopes.first { $0.type == "worktree.resolved" }?.durable?.seq == 0)
        #expect(envelopes.first { $0.type == "session.text.delta" }?.durable == nil)
    }

    @Test func permissionAskedAndReplied() throws {
        let envelopes = try sampleEnvelopes()
        guard case .permissionAsked(let request) = envelopes[48].event,
            case .permissionReplied(let reply) = envelopes[49].event
        else {
            Issue.record("expected permission.asked then permission.replied at the end of the sample")
            return
        }
        #expect(request.action == "read")
        #expect(request.resources == ["secret.env"])
        #expect(reply.requestID == request.id)
        #expect(reply.reply == .once)
    }

    @Test func catalogEventsBecomeResourcesChanged() throws {
        let types = try sampleEnvelopes().compactMap { envelope -> String? in
            if case .resourcesChanged(let type) = envelope.event { type } else { nil }
        }
        #expect(Set(types).isSuperset(of: ["provider.updated", "model.updated", "agent.updated"]))
    }

    @Test func unknownTypeFallsBackWithRawJSON() {
        let json = #"{"id":"evt_1","type":"session.brand-new","data":{"sessionID":"ses_1"}}"#
        let envelope = OpenCodeEventDecoder().decode(Data(json.utf8))
        guard case .unknown(let type, let raw) = envelope.event else {
            Issue.record("expected .unknown")
            return
        }
        #expect(type == "session.brand-new")
        #expect(raw == Data(json.utf8))
        #expect(envelope.id == "evt_1")
    }

    @Test func knownTypeWithUnexpectedShapeFallsBack() {
        let json = #"{"id":"evt_2","type":"session.text.delta","data":{"sessionID":"ses_1"}}"#
        let envelope = OpenCodeEventDecoder().decode(Data(json.utf8))
        #expect(envelope.event.isUnknown)
        #expect(envelope.type == "session.text.delta")
    }

    @Test func invalidJSONFallsBack() {
        let envelope = OpenCodeEventDecoder().decode(Data("not json".utf8))
        #expect(envelope.event.isUnknown)
        #expect(envelope.type == "")
    }

    @Test func extraFieldsAndUnknownEnumValuesAreTolerated() {
        let json = """
            {"id":"evt_3","type":"session.step.ended","created":1,"brandNew":true,
             "location":{"directory":"/tmp/p","extra":1},
             "data":{"sessionID":"ses_1","assistantMessageID":"msg_1","finish":"aliens","newField":[1,2]}}
            """
        let envelope = OpenCodeEventDecoder().decode(Data(json.utf8))
        guard case .stepEnded(let payload) = envelope.event else {
            Issue.record("expected .stepEnded")
            return
        }
        #expect(payload.finish.rawValue == "aliens")
        #expect(envelope.directory == "/tmp/p")
    }

    @Test func formAndStatusEvents() {
        let decoder = OpenCodeEventDecoder()
        let form = """
            {"id":"evt_4","type":"form.created","data":{"form":{"id":"frm_1","sessionID":"ses_9","title":"Pick",
             "fields":[{"key":"choice","type":"multiselect","options":[{"value":"a","label":"A"}]},
                       {"key":"note","type":"string","default":"x"},{"key":"odd","type":"telepathy"}]}}}
            """
        guard case .formCreated(let info) = decoder.decode(Data(form.utf8)).event else {
            Issue.record("expected .formCreated")
            return
        }
        #expect(info.sessionID == "ses_9")
        #expect(info.fields.map(\.type) == [.multiselect, .string, FormFieldType(rawValue: "telepathy")])

        let status = #"{"id":"evt_5","type":"session.status","data":{"sessionID":"ses_9","status":{"type":"retry","attempt":2,"message":"rate limited","next":99}}}"#
        guard case .sessionStatus(let changed) = decoder.decode(Data(status.utf8)).event else {
            Issue.record("expected .sessionStatus")
            return
        }
        #expect(changed.status == .retry(attempt: 2, message: "rate limited", next: 99))
        #expect(decoder.decode(Data(status.utf8)).sessionID == "ses_9")
    }
}
