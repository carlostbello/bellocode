import AppKit
import BelloCore
import Engine
import Foundation
import Testing

@testable import BelloCodeApp

/// The Auto right-panel tab reads a thread's stored audit log by the thread's ID, without waiting for its session.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct AutoAuditSurfaceTests {
    /// NF22: offline (the session never hydrates), the tab still shows the thread's cached log.
    @Test func showsTheStoredLogOfAThreadWhoseSessionIsNotLoaded() async throws {
        _ = NSApplication.shared
        let engine = try Engine(configuration: EngineConfiguration(server: .dynamic { nil }, store: .inMemory))
        let id = SessionID("ses_audit_offline")
        let entry = AutoAuditEntry(
            id: "audit_1", sessionID: id, projectDirectory: "/tmp/p", kind: .escalated, source: .policy, action: "bash",
            toolCallID: nil, findings: [], reasonCode: "network", explanation: "Uses the network", policyVersion: "1", at: .now)
        try await engine.store.appendAutoAudit([entry])
        let thread = engine.openThread(id)
        defer { thread.close() }
        let surfaces = AutoAuditSurfaces()
        surfaces.display(ThreadSurfaceContext(engine: engine, directory: "/tmp/p", projectName: "p", thread: thread))
        #expect(surfaces.state.sessionID == id, "the tab knows its thread before the session loads")
        let auto = try #require(engine.auto)
        #expect(await waitUntil(timeout: .seconds(3)) { auto.audit[id]?.map(\.id) == ["audit_1"] })
        #expect(thread.session == nil)
    }
}
