import BelloCore
import Foundation
import OpenCodeKit
import Testing

@testable import Engine

@Suite("Configuration and errors")
struct ConfigurationTests {
    @Test func attachesToServerFromEnvironment() {
        let source = ServerSource.fromEnvironment([
            "BELLOCODE_SERVER_URL": "http://127.0.0.1:4321", "BELLOCODE_SERVER_PASSWORD": "pw",
        ])
        guard case .fixed(let connection) = source else { Issue.record("expected a fixed source"); return }
        #expect(connection.baseURL.absoluteString == "http://127.0.0.1:4321")
        #expect(connection.credentials == ServerCredentials(password: "pw"))
        #expect(ServerSource.fromEnvironment([:]) == nil)
        #expect(ServerSource.fromEnvironment(["BELLOCODE_SERVER_URL": "not a url"]) == nil)
    }

    @Test func serverErrorsBecomeUserPresentable() {
        func http(_ status: Int, _ tag: String = "UnknownError") -> OpenCodeError {
            let body = try? JSONDecoder().decode(ServerErrorBody.self, from: Data(#"{"_tag":"\#(tag)","message":"m"}"#.utf8))
            return .http(status: status, body: body, operation: "op")
        }
        #expect(EngineError.from(http(404)) == .notFound("m"))
        #expect(EngineError.from(http(409)) == .conflict("m"))
        #expect(EngineError.from(http(400)) == .rejected("m"))
        #expect(EngineError.from(http(500)) == .server("m"))
        #expect(EngineError.from(OpenCodeError.transport(operation: "op", code: .timedOut)) == .timedOut)
        #expect(EngineError.from(OpenCodeError.transport(operation: "op", code: .cannotConnectToHost)) == .offline)
        #expect(EngineError.from(CancellationError()) == .cancelled)
        #expect(EngineError.offline.isTransient)
        #expect(!EngineError.offline.userMessage.isEmpty)
    }

    @Test func permissionModesRoundTripThroughRules() {
        for mode in PermissionMode.allCases {
            #expect(PermissionModeRules.mode(from: PermissionModeRules.rules(for: mode)) == mode)
        }
        #expect(PermissionModeRules.mode(from: [PermissionRule(action: "read", resource: "*", effect: .deny)]) == nil)
    }

    @Test func optimisticIDsHaveOpencodeShapeAndOrder() {
        var factory = IdentifierFactory()
        let a = factory.messageID(now: Timestamp(milliseconds: 1_794_000_000_000))
        let b = factory.messageID(now: Timestamp(milliseconds: 1_794_000_000_000))
        let c = factory.messageID(now: Timestamp(milliseconds: 1_794_000_000_001))
        #expect(a.rawValue.hasPrefix("msg_") && a.rawValue.count == 30)
        #expect(a < b && b < c)
        let s1 = factory.sessionID(now: Timestamp(milliseconds: 1_794_000_000_000))
        let s2 = factory.sessionID(now: Timestamp(milliseconds: 1_794_000_000_005))
        #expect(s1.rawValue.hasPrefix("ses_"))
        #expect(s2 < s1, "newer sessions sort first, as opencode's do")
    }
}
