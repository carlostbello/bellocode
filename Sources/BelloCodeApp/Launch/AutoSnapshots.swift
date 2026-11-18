import AppKit
import BelloCore
import Engine
import MockOpenCode

/// `--snapshot auto` (docs/features/auto-mode.md): the permission-mode picker with Auto, Auto-approved chips and the
/// audit tab, an escalation card from Auto, Full-access risk notices (transcript, tray, Needs you), and a thread
/// another agent stopped (banner with Resume) next to the interrupting thread's note. Light and dark.
extension SnapshotRunner {
    func runAuto() async -> Bool {
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
        guard await waitUntil(timeout: .seconds(20), { engine.root.connection == .live && !engine.root.projects.isEmpty }),
            let project = engine.root.projects.first?.directory
        else {
            log("FAIL mock never became live")
            return false
        }
        func open(_ title: String, _ mode: PermissionMode) async -> ThreadModel? {
            guard let session = try? await engine.createThread(in: project, title: title, permissionMode: mode) else { return nil }
            _ = await waitUntil(timeout: .seconds(5)) { workspace.projectModel(engine.root.projects[0])?.sessionIDs.contains(session.id) == true }
            _ = await driver.select(.thread(session.id))
            let thread = workspace.threadModel(session.id)
            _ = await waitUntil(timeout: .seconds(5)) { thread.phase == .ready }
            return thread
        }

        guard let autoThread = await open("Fix the flaky parser test", .auto) else { return false }

        // 2. Auto-approved chips (policy edit, reviewer build) and the audit tab.
        await runtime.enqueueMockScript(Self.autoWork, for: autoThread.session?.id)
        driver.type("The parser test is flaky; find out why and fix it.")
        driver.send()
        _ = await waitUntil(timeout: .seconds(15)) { autoThread.messageIDs.count >= 2 && !autoThread.isRunning }
        if let id = autoThread.session?.id { await engine.auto.loadAudit(id) }
        driver.perform(.showAutoAudit)
        driver.settle(10)
        await shoot("chip-audit")

        // 3. An escalation from Auto: the existing pinned card with Auto's reason.
        guard let secretThread = await open("Rotate the staging token", .auto) else { return false }
        await runtime.enqueueMockScript(Self.secretRead, for: secretThread.session?.id)
        driver.type("Rotate the staging API token used by the deploy script.")
        driver.send()
        _ = await waitUntil(timeout: .seconds(15)) { !secretThread.pendingRequests.isEmpty }
        controller.split.setCollapsed(controller.split.panelItem, true)
        driver.settle(10)
        await shoot("escalation")

        // 4. Full access: notices under the calls, the tray row and "Review" in Needs you.
        guard let fullThread = await open("Clean up the release branch", .fullAccess) else { return false }
        await runtime.enqueueMockScript(Self.fullAccessWork, for: fullThread.session?.id)
        driver.type("Reset the release branch to origin and redeploy.")
        driver.send()
        _ = await waitUntil(timeout: .seconds(15)) { fullThread.messageIDs.count >= 2 && !fullThread.isRunning }
        _ = await waitUntil(timeout: .seconds(5)) { (fullThread.session.map { engine.auto.noticeCount($0.id) } ?? 0) > 0 }
        driver.settle(10)
        await shoot("risk-notice")

        // 5. Interrupts: the interrupting thread's note, and the stopped thread's banner with Resume.
        guard let target = await open("Refactor the lexer", .fullAccess), let targetID = target.session?.id else { return false }
        guard let caller = await open("Coordinate the 2.0 release", .fullAccess) else { return false }
        await runtime.enqueueMockScript(Self.interrupter(target: targetID.rawValue), for: caller.session?.id)
        driver.type("The lexer refactor conflicts with the release branch; stop it.")
        driver.send()
        _ = await waitUntil(timeout: .seconds(15)) { caller.messageIDs.count >= 2 && !caller.isRunning }
        await runtime.setMockSessionMetadata(
            targetID, key: InterruptRecord.metadataKey,
            json: #"{"by":"\#(caller.session?.id.rawValue ?? "")","byTitle":"Coordinate the 2.0 release","reason":"it edits Lexer.swift, which the release branch also changes","at":1795000000000,"requested":"stop","actual":"stopped","held":true}"#)
        driver.settle(10)
        await shoot("interrupt-caller")
        _ = await driver.select(.thread(targetID))
        _ = await waitUntil(timeout: .seconds(5)) { target.heldInterrupt != nil }
        driver.settle(10)
        await shoot("interrupt-resume")

        // 1 (last, so its popover cannot linger into other shots). The picker with Auto, on the Auto thread.
        if let id = autoThread.session?.id { _ = await driver.select(.thread(id)) }
        controller.split.setCollapsed(controller.split.panelItem, true)
        driver.settle(10)
        driver.perform(.permissionMode)
        driver.settle(10)
        await shoot("mode-picker")
        driver.closeOverlays()

        workspace.close()
        controller.close()
        for path in written { log("wrote \(path)") }
        log(written.isEmpty ? "FAIL nothing written" : "PASS \(written.count) images")
        return !written.isEmpty
    }

    static let autoWork = TurnScript(name: "snapshot-auto-work") {
        TurnStep.text("I'll reproduce it first.\n\n")
        TurnStep.tool(
            "read", input: ["filePath": "Sources/Parser.swift"], output: "struct Parser { … }", duration: 20,
            permission: PermissionAsk(action: "read", resources: ["Sources/Parser.swift"]))
        TurnStep.tool(
            "shell", input: ["command": "swift test --filter ParserTests"], output: "Executed 42 tests, with 1 failure", duration: 60,
            permission: PermissionAsk(action: "shell", resources: ["swift test --filter ParserTests"]))
        TurnStep.tool(
            "edit", input: ["filePath": "Sources/Parser.swift", "oldString": "Date()", "newString": "clock.now"],
            output: "Edited Sources/Parser.swift", duration: 30,
            permission: PermissionAsk(action: "edit", resources: ["Sources/Parser.swift"]))
        TurnStep.text("The test depended on wall-clock time; it now uses the injected clock.")
    }

    static let secretRead = TurnScript(name: "snapshot-auto-secret") {
        TurnStep.text("The token is configured in the environment file; reading it.\n\n")
        TurnStep.tool(
            "read", input: ["filePath": ".env"], output: "", duration: 20,
            permission: PermissionAsk(action: "read", resources: [".env"]))
        TurnStep.text("Updated the token.")
    }

    static let fullAccessWork = TurnScript(name: "snapshot-full-access") {
        TurnStep.text("Resetting the branch to the remote state.\n\n")
        TurnStep.tool("shell", input: ["command": "git reset --hard origin/release"], output: "HEAD is now at 4e1c2d9", duration: 40)
        TurnStep.tool("read", input: ["filePath": ".env.production"], output: "(12 lines)", duration: 20)
        TurnStep.tool("shell", input: ["command": "npm install && npm run deploy"], output: "added 312 packages", duration: 80)
        TurnStep.text("The branch matches origin and the deploy script ran.")
    }

    static func interrupter(target: String) -> TurnScript {
        TurnScript(name: "snapshot-interrupter") {
            TurnStep.text("The lexer thread is editing the same file as the release branch. Stopping it.\n\n")
            TurnStep.tool(
                "thread_interrupt", input: ["threadID": .string(target), "reason": "it edits Lexer.swift, which the release branch also changes"],
                output: "Stopped \(target)\nRequested: stop. Actual: stopped.",
                metadata: [
                    "threadID": .string(target), "title": "Refactor the lexer",
                    "interrupt": ["by": "caller", "reason": "it edits Lexer.swift, which the release branch also changes", "actual": "stopped", "held": true],
                ], duration: 40)
            TurnStep.text("Stopped “Refactor the lexer”; its queued work waits until you resume it.")
        }
    }
}
