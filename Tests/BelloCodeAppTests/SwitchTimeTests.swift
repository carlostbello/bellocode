import AppKit
import BelloCore
import Engine
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import BelloCodeApp

/// Drives thread selection across 500 threads through the real content area (header, temporary transcript, request
/// stack, composer) and measures select → transcript rendered from cache. Budget: 100 ms (AGENTS.md UX rule 1).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct SwitchTimeTests {
    @Test func switchingAcross500ThreadsStaysWithinBudget() async throws {
        _ = NSApplication.shared
        // 625 sessions: every fifth is a sub-agent, so 500 top-level threads across 5 projects.
        let scenario = FixtureGenerator(seed: 7).workspace(projectCount: 5, sessionCount: 625, messagesPerSession: 6)
        let server = MockOpenCodeServer(scenario: scenario, options: .testing)
        let endpoint = try await server.start()
        let connection = ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? ""))
        let engine = try Engine(configuration: EngineConfiguration(server: .fixed(connection), store: .inMemory))
        await engine.start()
        let workspace = WorkspaceController(engine: engine, stateStore: ShellStateStore(defaults: nil))
        func threadIDs() -> [SessionID] {
            engine.root.projects.flatMap { workspace.projectModel($0)?.sessionIDs ?? [] }
        }
        let loaded = await waitUntil(timeout: .seconds(30)) { engine.root.connection == .live && threadIDs().count == 500 }
        #expect(loaded, "500 threads listed (got \(threadIDs().count))")
        let ids = threadIDs()

        let container = ThreadContainerViewController(workspace: workspace, surfaces: .builtIn)
        container.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)

        func rendered(_ id: SessionID) -> Bool {
            guard container.displayed == .thread(id), let thread = container.context?.thread, thread.phase == .ready,
                let transcript = container.transcript as? TranscriptSurfaceController
            else { return false }
            return !thread.messageIDs.isEmpty && transcript.controller.renderedMessageCount == thread.messageIDs.count
                && !transcript.controller.rows.isEmpty
        }

        func pass() async -> [Double] {
            var samples: [Double] = []
            for id in ids {
                let start = ContinuousClock.now
                workspace.select(.thread(id))
                let deadline = start + .seconds(2)
                while !rendered(id), ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .microseconds(200))
                }
                let elapsed = ContinuousClock.now - start
                samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
            }
            return samples
        }

        // Cold pass: each thread's newest messages come from the mock server once and land in the cache.
        let cold = await pass()
        await engine.flush()
        // Warm pass: models beyond the 8 kept open were closed, so most switches reopen from the SQLite cache.
        let warm = await pass()
        #expect(workspace.openThreadCount <= WorkspaceController.openThreadLimit)

        func stats(_ samples: [Double]) -> (p50: Double, p95: Double, max: Double) {
            let sorted = samples.sorted()
            return (sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)], sorted.last ?? 0)
        }
        let c = stats(cold)
        let w = stats(warm)
        print(String(format: "switch-time cold (server): p50 %.1f ms, p95 %.1f ms, max %.1f ms over %d", c.p50, c.p95, c.max, cold.count))
        print(String(format: "switch-time warm (cache): p50 %.1f ms, p95 %.1f ms, max %.1f ms over %d", w.p50, w.p95, w.max, warm.count))
        // Every switch rendered (a switch that hit its 2 s deadline is a functional failure). The latency budgets
        // (p95 100 ms, max 200 ms) are asserted with BELLOCODE_STRICT_PERF=1 on a quiet machine; otherwise against a
        // sanity bound ten times wider, so a loaded machine cannot fail it.
        #expect(w.max < 2_000, "every warm switch rendered before its 2 s deadline")
        let strict = ProcessInfo.processInfo.environment["BELLOCODE_STRICT_PERF"] == "1"
        #expect(w.p95 < (strict ? 100 : 1_000), "warm p95 \(w.p95) ms")
        if strict { #expect(w.max < 200, "warm max \(w.max) ms") }

        // Sidebar: 500 thread rows (plus headers and projects) build, and row selection drives the workspace.
        let sidebar = SidebarViewController(workspace: workspace)
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        let buildStart = ContinuousClock.now
        var rows = 0
        while rows < 505, ContinuousClock.now < buildStart + .seconds(5) {
            try? await Task.sleep(for: .milliseconds(1))
            rows = sidebar.outlineView.numberOfRows
        }
        let buildTime = ContinuousClock.now - buildStart
        print("sidebar: \(rows) rows in \(buildTime)")
        #expect(rows >= 505, "headers, 5 projects and 500 threads (attention rows may add more)")
        var checked = 0
        for row in 0..<rows {
            guard let item = sidebar.outlineView.item(atRow: row) as? SidebarItem, case .thread(let id) = item.id else { continue }
            sidebar.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            #expect(workspace.selection == .thread(id))
            checked += 1
            if checked == 100 { break }
        }
        #expect(checked == 100)
        #expect(sidebar.outlineView.numberOfRows == rows, "selection never reshuffles rows")

        workspace.close()
        await engine.stop()
        await server.stop()
    }
}
