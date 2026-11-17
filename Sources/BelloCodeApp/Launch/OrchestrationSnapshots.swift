import AppKit
import BelloCore
import Engine
import MockOpenCode
import TranscriptKit

/// `--snapshot orch`: orchestration in the window (docs/features/orchestration.md): the Agents panel with a tree of
/// mixed states, sub-agent cards and a send-to-user card in the transcript, the waiting-on-children status, a child's
/// view ("Child of …"), sidebar nesting and a fan-out group, in light and dark.
extension SnapshotRunner {
    func runOrchestration() async -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log("FAIL cannot create \(directory.path): \(error)")
            return false
        }
        let engine = runtime.engine
        let settings = AppSettings(defaults: nil)
        let services = AppServices(settings: settings, auth: runtime.auth)
        let workspace = WorkspaceController(engine: engine, stateStore: ShellStateStore(defaults: nil))
        let controller = MainWindowController(
            workspace: workspace,
            configuration: .init(surfaces: .builtIn(services: services), autosaveSuffix: nil, sourceLabel: runtime.sourceLabel))
        guard let window = controller.window else { return false }
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        controller.showWindow(nil)
        let driver = ShellDriver(controller: controller)
        var written: [String] = []
        func shoot(_ state: String) async {
            guard only.isEmpty || only.contains(state) else { return }
            written += await render(driver, state: state)
        }

        await engine.start()
        guard await waitUntil(timeout: .seconds(20), { engine.root.connection == .live && !engine.root.projects.isEmpty }) else {
            log("FAIL mock never became live")
            return false
        }
        _ = await waitUntil(timeout: .seconds(5)) {
            engine.root.projects.allSatisfy { workspace.projectModel($0).map { !$0.sessionIDs.isEmpty } ?? false }
        }
        guard let first = engine.root.projects.first, let threads = workspace.projectModel(first)?.sessionIDs, threads.count >= 2 else {
            log("FAIL the mock scenario has too few threads")
            return false
        }
        for id in threads { try? await engine.markViewed(id) }
        await runtime.setMockChildReports(true)
        let orchestration = engine.orchestration!

        // A parent that fans work out: a long audit (with its own child), a quick changelog, a failing benchmark run,
        // a native sub-agent that needs approval, and a plan the person must read now.
        let parentID = threads[0]
        _ = await driver.select(.thread(parentID))
        let parent = workspace.threadModel(parentID)
        _ = await waitUntil(timeout: .seconds(5)) { parent.phase == .ready }
        await parent.setPermissionMode(.ask)
        await runtime.enqueueMockScript(Self.orchestrator, for: parentID)
        // What the parent says when each child's report wakes it.
        for reply in ["Changelog drafted.", "Benchmarks failed (missing fixture); I'll retry when it exists.", "Noted."] {
            await runtime.enqueueMockScript(TurnScript(steps: [.text(reply)]), for: parentID)
        }
        driver.type("Prepare the 2.0 release: audit the parser, write the changelog, benchmark, and fix the docs.")
        driver.send()
        _ = await waitUntil(timeout: .seconds(15)) {
            let children = orchestration.children(of: parentID)
            return children.count >= 4 && orchestration.status(of: parentID) == .waitingOnChildren
                && children.contains { orchestration.status(of: $0) == .needsApproval }
                && children.contains { orchestration.status(of: $0) == .failed }
        }
        _ = await waitUntil(timeout: .seconds(5)) {
            orchestration.children(of: parentID).contains { !orchestration.children(of: $0).isEmpty }
        }
        try? await Task.sleep(for: .milliseconds(400))
        controller.sidebar.expandThread(parentID)
        driver.perform(.showAgents)
        driver.settle(10)
        await shoot("agents")

        // The transcript side: cards follow their children; the send-to-user card; Agents panel hidden for width.
        controller.split.setCollapsed(controller.split.panelItem, true)
        driver.settle(10)
        // Bring the cards up: the turn's first assistant message (the delegation) at the top of the viewport.
        if let transcript = controller.container.transcriptSurface,
            let first = parent.messageIDs.first(where: { id in
                parent.message(id)?.message.parts.contains { if case .subagent = $0.content { true } else { false } } ?? false
            })
        {
            transcript.controller.restore(anchor: TranscriptAnchor(messageID: first, offset: 0))
        }
        driver.settle(10)
        await shoot("cards")
        controller.split.setCollapsed(controller.split.panelItem, false)

        // A child's own view: "Child of …", its place in the tree.
        if let blocked = orchestration.children(of: parentID).first(where: { orchestration.status(of: $0) == .needsApproval }) {
            _ = await driver.select(.thread(blocked))
            _ = await waitUntil(timeout: .seconds(5)) { workspace.threadModel(blocked).phase == .ready }
            driver.perform(.showAgents)
            driver.settle(10)
            await shoot("child")
        }

        // Fan-out: threads created by another thread, nested under it in the sidebar as a group.
        let creatorID = threads[1]
        _ = await driver.select(.thread(creatorID))
        let creator = workspace.threadModel(creatorID)
        _ = await waitUntil(timeout: .seconds(5)) { creator.phase == .ready }
        await runtime.enqueueMockScript(Self.fanOut, for: creatorID)
        driver.type("Split the migration into one thread per module.")
        driver.send()
        _ = await waitUntil(timeout: .seconds(5)) { !creator.isRunning && creator.messageIDs.count >= 2 }
        let created = await runtime.mockCreateThreads(by: creatorID, titles: ["Migrate Parser module", "Migrate Lexer module", "Migrate CLI module"])
        _ = await waitUntil(timeout: .seconds(5)) { created.allSatisfy { orchestration.node($0)?.node.kind == .created } }
        driver.settle(10)
        _ = await waitUntil(timeout: .seconds(5)) { orchestration.createdThreads(by: creatorID).count == created.count }
        try? await Task.sleep(for: .milliseconds(300))
        driver.settle(10)
        controller.sidebar.expandThread(creatorID)
        driver.perform(.showAgents)
        driver.settle(10)
        await shoot("fanout")

        workspace.close()
        controller.close()
        for path in written { log("wrote \(path)") }
        log(written.isEmpty ? "FAIL nothing written" : "PASS \(written.count) images")
        return !written.isEmpty
    }

    static let orchestrator = TurnScript(name: "snapshot-orchestrator") {
        TurnStep.text("I'll split this into parallel tasks and keep the release notes for myself.\n\n")
        TurnStep.delegate(description: "Audit parser for 2.0", task: "Audit Sources/Core/Parser.swift for breaking changes.") {
            TurnStep.text("Reading the grammar first.")
            TurnStep.delegate(description: "Check grammar tests", task: "List grammar tests that cover precedence.") {
                TurnStep.delay(milliseconds: 600_000)
            }
            TurnStep.delay(milliseconds: 600_000)
        }
        TurnStep.delegate(description: "Write CHANGELOG entry", task: "Draft the 2.0 changelog entry from the merged PRs.") {
            TurnStep.text("Drafted the 2.0 entry: 3 features, 5 fixes, 1 breaking change (operator precedence).")
        }
        TurnStep.delegate(description: "Run benchmarks", task: "Run the parser benchmarks and compare with 1.9.") {
            TurnStep.fail("The benchmark harness crashed: missing fixture large.json")
        }
        TurnStep.subagent(agent: "general", description: "Fix docs typos", prompt: "Fix the typos in docs/PLAN.md") {
            TurnStep.text("Found two typos.")
            TurnStep.tool(
                "edit", input: ["path": "docs/PLAN.md", "old": "teh", "new": "the"], output: "Edited docs/PLAN.md",
                duration: 40, permission: PermissionAsk(action: "edit", resources: ["docs/PLAN.md"], save: ["docs/PLAN.md"]))
        }
        TurnStep.tool(
            "send_to_user",
            input: [
                "title": "Release plan — please confirm",
                "markdown": "1. **Parser audit** runs in the background.\n2. **Changelog** is drafted.\n3. Benchmarks need a fixture; I will retry once it exists.\n\nShip 2.0 on **Friday** unless the audit finds a blocker?",
            ], output: "Shown to the user.", duration: 20)
        TurnStep.text("Four tasks are running or done. I'll report when the audit finishes.")
    }

    static let fanOut = TurnScript(name: "snapshot-fanout") {
        TurnStep.text("Three modules are independent, so each gets its own thread.\n\n")
        TurnStep.tool(
            "create_threads",
            input: ["threads": [["title": "Migrate Parser module"], ["title": "Migrate Lexer module"], ["title": "Migrate CLI module"]]],
            output: "Created 3 thread(s).", duration: 30)
        TurnStep.text("Created three threads; they appear under this one in the sidebar.")
    }
}
