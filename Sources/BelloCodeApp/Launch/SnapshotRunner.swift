import AgentUI
import AppKit
import BelloCore
import ComposerKit
import Engine
import MockOpenCode

/// `--snapshot <name>`: builds the real window against the mock scenario, drives it through the integrated app's
/// states with `ShellDriver` (the real composer, request cards and pickers), renders each to PNG in light and dark
/// at 1280x800 and 980x640, and exits. The shell cannot take screenshots, so the window renders itself
/// (`cacheDisplay`) with any popovers, panels and utility windows above it composited in place (AGENTS.md
/// "Environment").
///
/// Files: `<directory>/<name>-<state>-<light|dark>-<width>x<height>.png`. States, in order: `empty`, `onboarding`,
/// `draft`, `attachments`, `completion`, `running-queued`, `model-picker`, `mode-popover`, `approval-shell`,
/// `question`, `child-approval`, `error-offline`.
@MainActor
struct SnapshotRunner {
    let runtime: AppRuntime
    let name: String
    let directory: URL
    /// Only these states (all when empty), from `BELLOCODE_SNAPSHOT_STATES` (comma-separated).
    var only: Set<String> = Set(
        (ProcessInfo.processInfo.environment["BELLOCODE_SNAPSHOT_STATES"] ?? "").split(separator: ",").map(String.init))

    static let sizes = [NSSize(width: 1280, height: 800), NSSize(width: 980, height: 640)]

    func run() async -> Bool {
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

        // Empty: the window before the engine has loaded anything (no projects yet).
        await shoot("empty")

        await engine.start()
        guard await waitUntil(timeout: .seconds(20), { engine.root.connection == .live && !engine.root.projects.isEmpty }) else {
            log("FAIL mock never became live (\(engine.root.connection.label))")
            return false
        }
        _ = await waitUntil(timeout: .seconds(5)) {
            engine.root.projects.allSatisfy { item in workspace.projectModel(item).map { !$0.sessionIDs.isEmpty } ?? false }
        }
        _ = await waitUntil(timeout: .seconds(5)) { engine.root.catalog.current != nil }
        Task { await runtime.auth.refresh() }
        let projects = engine.root.projects
        guard let first = projects.first, let firstModel = workspace.projectModel(first), firstModel.sessionIDs.count >= 1 else {
            log("FAIL the mock scenario has no threads")
            return false
        }
        let second = projects.dropFirst().first ?? first
        let threads = firstModel.sessionIDs + (workspace.projectModel(second)?.sessionIDs ?? [])

        // First run: the onboarding window beside a draft.
        _ = await driver.select(.draft(directory: first.directory))
        if only.isEmpty || only.contains("onboarding") {
            let onboarding = UtilityWindowController(
                title: "Welcome to BelloCode",
                content: AgentUIFactories.onboarding(auth: runtime.auth, engine: engine, importSource: nil, style: AppStyle.agentUI) { _ in },
                size: NSSize(width: 520, height: 500))
            onboarding.showWindow(nil)
            written += await render(driver, state: "onboarding") { frame in
                guard let panel = onboarding.window else { return }
                panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
            }
            onboarding.close()
        }

        // Draft: the hero composer.
        await shoot("draft")

        // Attachments: a pasted image, a large paste and a file mention in the draft.
        if let composer = driver.composer {
            composer.insert(text: "Compare the screenshot with ")
            composer.insert(token: ComposerToken(kind: .file, text: "@Sources/App/main.swift", value: first.directory + "/Sources/App/main.swift"))
            composer.insert(text: "and the pasted log.")
            _ = composer.add(attachments: [
                .image(Self.sampleImagePNG(), type: .png, name: "Screenshot 2026-11-16.png"),
                .text(String(repeating: "error: build failed at step 3\n", count: 40), name: "build.log"),
            ])
            await composer.settle()
        }
        await shoot("attachments")

        // Completion: "@Pa" asks the server's file search; the popover sits above the card.
        if let composer = driver.composer {
            composer.textView.setSelectedRange(NSRange(location: (composer.textView.string as NSString).length, length: 0))
            driver.type(" @Pa")
            await composer.settle()
            driver.settle()
        }
        await shoot("completion")
        driver.composer?.completion.close()
        driver.settle()

        // A running thread with a queued follow-up, sent through the real composer.
        let runningID = threads[0]
        _ = await driver.select(.thread(runningID))
        let running = workspace.threadModel(runningID)
        _ = await waitUntil(timeout: .seconds(5)) { running.phase == .ready }
        await runtime.enqueueMockScript(Self.longTurn, for: runningID)
        driver.type("Refactor the parser into smaller functions and keep the tests green.")
        driver.send()
        _ = await waitUntil(timeout: .seconds(10)) { running.isRunning }
        try? await Task.sleep(for: .milliseconds(600))
        driver.type("Then update the README with the new structure.")
        driver.send()
        _ = await waitUntil(timeout: .seconds(5)) { running.queue.contains { $0.state == .queued } }
        driver.settle()
        await shoot("running-queued")

        // The model picker and the permission-mode popover, opened from their menu commands.
        driver.perform(.chooseModel)
        driver.settle(10)
        await shoot("model-picker")
        driver.closeOverlays()
        driver.settle()
        driver.perform(.permissionMode)
        driver.settle(10)
        await shoot("mode-popover")
        driver.closeOverlays()
        driver.perform(.stopRun)
        _ = await waitUntil(timeout: .seconds(5)) { !running.isRunning }

        // A shell command waiting for approval, in "Ask" mode.
        let shellID = threads.count > 1 ? threads[1] : runningID
        _ = await driver.select(.thread(shellID))
        let shell = workspace.threadModel(shellID)
        _ = await waitUntil(timeout: .seconds(5)) { shell.phase == .ready }
        await shell.setPermissionMode(.ask)
        await runtime.enqueueMockScript(Self.shellApproval, for: shellID)
        driver.type("Clean the build folder and rebuild.")
        driver.send()
        _ = await waitUntil(timeout: .seconds(10)) {
            shell.pendingRequests.contains { $0.isPermission } && shell.status?.status == .awaitingApproval
        }
        driver.settle()
        await shoot("approval-shell")

        // A question from the agent.
        let questionID = threads.count > 2 ? threads[2] : shellID
        _ = await driver.select(.thread(questionID))
        let question = workspace.threadModel(questionID)
        _ = await waitUntil(timeout: .seconds(5)) { question.phase == .ready }
        await runtime.enqueueMockScript(Self.question, for: questionID)
        driver.type("Set up continuous integration for this package.")
        driver.send()
        _ = await waitUntil(timeout: .seconds(10)) {
            question.pendingRequests.contains { !$0.isPermission } && question.status?.status == .awaitingAnswer
        }
        driver.settle()
        await shoot("question")

        // A child agent's approval, shown in the parent thread.
        let parentID = threads.count > 3 ? threads[3] : questionID
        _ = await driver.select(.thread(parentID))
        let parent = workspace.threadModel(parentID)
        _ = await waitUntil(timeout: .seconds(5)) { parent.phase == .ready }
        await parent.setPermissionMode(.ask)
        await runtime.enqueueMockScript(Self.childApproval, for: parentID)
        driver.type("Ask a helper to fix the typo in the docs.")
        driver.send()
        _ = await waitUntil(timeout: .seconds(10)) {
            parent.pendingRequests.contains { $0.sessionID != parentID } && parent.status?.status == .awaitingApproval
        }
        driver.settle()
        await shoot("child-approval")

        // Offline with cached content, and a send that failed (text and error back in the composer).
        _ = await driver.select(.thread(runningID))
        await runtime.takeMockOffline()
        _ = await waitUntil(timeout: .seconds(10)) {
            if case .offline = engine.root.connection { return true }
            return false
        }
        driver.type("Run the tests again.")
        driver.send()
        _ = await waitUntil(timeout: .seconds(10)) { driver.composer?.visibleError != nil }
        driver.settle()
        await shoot("error-offline")

        workspace.close()
        controller.close()
        for path in written { log("wrote \(path)") }
        log(written.isEmpty ? "FAIL nothing written" : "PASS \(written.count) images")
        return !written.isEmpty
    }

    // MARK: Scripts

    static let longTurn = TurnScript(name: "snapshot-long") {
        TurnStep.reasoning("Split the parser by grammar rule, run the tests after each step.")
        TurnStep.text("I'll start with the expression rules.\n\n")
        TurnStep.tool("read", input: ["path": "Sources/Core/Parser.swift"], output: "struct Parser { … }", duration: 80)
        TurnStep.text("Extracting `parseExpression` into three functions", chunkSize: 4, rate: 20)
        TurnStep.delay(milliseconds: 60_000)
    }

    static let shellApproval = TurnScript(name: "snapshot-shell") {
        TurnStep.text("I'll remove the stale build products, then rebuild.\n\n")
        TurnStep.tool(
            "shell", input: ["command": "rm -rf .build && swift build", "description": "Clean and rebuild"],
            output: "Build complete!", duration: 200,
            permission: PermissionAsk(action: "shell", resources: ["rm -rf .build && swift build"], save: ["rm *", "swift build"]))
    }

    static let question = TurnScript(name: "snapshot-question") {
        TurnStep.text("Before I add a workflow I need one decision.\n\n")
        TurnStep.question("Which CI service should run the tests?", key: "ci", options: ["GitHub Actions", "Xcode Cloud", "None for now"])
    }

    static let childApproval = TurnScript(name: "snapshot-child") {
        TurnStep.text("I'll hand this to a helper agent.\n\n")
        TurnStep.subagent(agent: "general", description: "Fix docs typo", prompt: "Fix the typo in docs/PLAN.md") {
            TurnStep.text("Found it on line 12.")
            TurnStep.tool(
                "edit", input: ["path": "docs/PLAN.md", "old": "teh", "new": "the"], output: "Edited docs/PLAN.md",
                duration: 40, permission: PermissionAsk(action: "edit", resources: ["docs/PLAN.md"], save: ["docs/PLAN.md"]))
        }
    }

    /// A small generated image for the attachment chip.
    static func sampleImagePNG() -> Data {
        let size = NSSize(width: 64, height: 40)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            NSColor.white.setFill()
            NSRect(x: 8, y: 8, width: 30, height: 6).fill()
            NSRect(x: 8, y: 20, width: 46, height: 6).fill()
            return true
        }
        let rep = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        return rep?.representation(using: .png, properties: [:]) ?? Data()
    }

    // MARK: Rendering

    /// Renders the window (and overlays above it) in light and dark at both sizes. `place` positions extra windows
    /// after each resize.
    private func render(_ driver: ShellDriver, state: String, place: ((NSRect) -> Void)? = nil) async -> [String] {
        var paths: [String] = []
        let window = driver.window
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearanceName)
            window.appearance = NSAppearance(named: appearanceName)
            for size in Self.sizes {
                window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
                place?(window.frame)
                await driver.idle()
                guard let frameView = window.contentView?.superview,
                      let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
                else { continue }
                frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                composite(driver.overlayWindows, onto: bitmap, origin: window.frame.origin)
                let mode = appearanceName == .darkAqua ? "dark" : "light"
                let file = directory.appending(path: "\(name)-\(state)-\(mode)-\(Int(size.width))x\(Int(size.height)).png")
                guard let data = bitmap.representation(using: .png, properties: [:]), (try? data.write(to: file)) != nil else { continue }
                paths.append(file.path)
            }
        }
        NSApp.appearance = nil
        return paths
    }

    /// Draws each overlay window's own rendering (with its transparency) at its place over the main window.
    private func composite(_ windows: [NSWindow], onto bitmap: NSBitmapImageRep, origin: NSPoint) {
        guard !windows.isEmpty, let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for overlay in windows {
            guard let view = overlay.contentView?.superview ?? overlay.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let rect = NSRect(
                x: overlay.frame.minX - origin.x, y: overlay.frame.minY - origin.y, width: overlay.frame.width,
                height: overlay.frame.height)
            // A soft shadow like the window server's, so overlays read as floating.
            if overlay.hasShadow {
                let shadow = NSShadow()
                shadow.shadowBlurRadius = 14
                shadow.shadowOffset = NSSize(width: 0, height: -4)
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
                shadow.set()
            }
            rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSShadow().set()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func log(_ message: String) {
        print("snapshot: \(message)")
        fflush(stdout)
    }
}
