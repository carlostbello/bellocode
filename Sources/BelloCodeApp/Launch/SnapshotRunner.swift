import AgentUI
import AppKit
import BelloCore
import ComposerKit
import DesignSystem
import DiffKit
import Engine
import MockOpenCode
import OpenCodeKit
import WebKit

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
        if name == "nav" { return await runNavigation() }
        if name == "orch" { return await runOrchestration() }
        if name == "extras" { return await runExtras() }
        if name == "gitlab" { return await runGitLab() }
        if name == "gitlab2" { return await runGitLab2() }
        if name == "containers" { return await runContainers() }
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

        // M2-C: the Changes tab beside the thread (a turn's diff from the mock), unified and side by side.
        if only.isEmpty || only.contains("changes") || only.contains("changes-split") {
            _ = await driver.select(.thread(runningID))
            await runtime.setMockTurnDiff(Self.sampleTurnDiff, for: runningID)
            driver.perform(.showChanges)
            if let changes = controller.changes, let model = changes.model {
                changes.panel.setScope(.turn(nil))
                model.load()
                _ = await waitUntil(timeout: .seconds(5)) { model.phase == .ready && changes.panel.diff.rowCount > 0 }
                driver.settle(10)
                await shoot("changes")
                changes.panel.setLayout(.split)
                driver.settle(10)
                await shoot("changes-split")
                changes.panel.setLayout(.unified)
            }
        }

        // The built-in browser beside a thread: the agent is filling a shared tab (banner, cursor, ownership markers).
        if only.isEmpty || only.contains("browser") {
            await shootBrowser(driver, controller: controller, threadID: questionID)
            await shoot("browser")
            controller.browser?.pane?.set?.stopAgent()
            try? await Task.sleep(for: .milliseconds(300))
        }

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

    /// A turn that edited two files (full-file patches, as opencode returns without `context`).
    static var sampleTurnDiff: [MockOpenCode.JSONValue] {
        func full(_ path: String, _ old: String?, _ new: String?) -> MockOpenCode.JSONValue {
            let hunks = LineDiff.hunks(old: LineDiff.lines(old ?? ""), new: LineDiff.lines(new ?? ""), context: 1_000_000)
            let patch = PatchFile(oldPath: old == nil ? nil : path, newPath: new == nil ? nil : path, hunks: hunks).render()
            return MockVCSRepository.fileDiff(path, status: old == nil ? "added" : "modified", patch: patch)
        }
        let parserOld = """
            struct Parser {
                var tokens: [Token]
                var index = 0

                mutating func parseExpression() throws -> Expression {
                    let lhs = try parsePrimary()
                    if peek() == .plus {
                        advance()
                        return .binary(lhs, .plus, try parseExpression())
                    }
                    return lhs
                }
            }

            """
        let parserNew = """
            struct Parser {
                var tokens: [Token]
                var index = 0

                mutating func parseExpression() throws -> Expression {
                    try parseBinary(precedence: 0)
                }

                /// Precedence climbing: one function per level instead of recursion on the right.
                mutating func parseBinary(precedence: Int) throws -> Expression {
                    var lhs = try parsePrimary()
                    while let op = peek()?.binaryOperator, op.precedence >= precedence {
                        advance()
                        lhs = .binary(lhs, op, try parseBinary(precedence: op.precedence + 1))
                    }
                    return lhs
                }
            }

            """
        return [
            full("Sources/Core/Parser.swift", parserOld, parserNew),
            full("Tests/CoreTests/ParserTests.swift", nil, "import Testing\n\n@Test func precedence() throws {\n    #expect(try parse(\"1 + 2 * 3\") == .binary(1, .plus, .binary(2, .times, 3)))\n}\n"),
        ]
    }

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
            rect.fill(using: .sourceOver)
            NSColor.white.setFill()
            NSRect(x: 8, y: 8, width: 30, height: 6).fill(using: .sourceOver)
            NSRect(x: 8, y: 20, width: 46, height: 6).fill(using: .sourceOver)
            return true
        }
        let rep = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        return rep?.representation(using: .png, properties: [:]) ?? Data()
    }

    // MARK: Browser

    static let browserPage = """
        <!doctype html><html><head><title>Sign up · Preview</title><meta name="color-scheme" content="light dark"><style>
        body{font:15px -apple-system,system-ui,sans-serif;margin:28px;color:#1d1d1f;background:#fbfbfd}
        @media (prefers-color-scheme: dark){body{color:#f5f5f7;background:#1c1c1e} input,select{background:#2c2c2e;color:#f5f5f7;border-color:#48484a}}
        h1{font-size:22px;margin:0 0 16px} label{display:block;margin:10px 0 4px;font-weight:500}
        input,select{font:inherit;width:280px;padding:7px 9px;border:1px solid #c7c7cc;border-radius:7px}
        button{margin-top:16px;font:600 14px -apple-system;padding:8px 16px;border-radius:8px;border:0;background:#0a84ff;color:white}
        </style></head><body><h1>Create your account</h1>
        <label for=n>Full name</label><input id=n placeholder="Ada Lovelace">
        <label for=e>Email</label><input id=e placeholder="ada@example.com">
        <label for=p>Plan</label><select id=p><option>Free</option><option>Pro</option></select>
        <div><button id=s>Create account</button></div></body></html>
        """

    /// Opens a preview page in the thread's browser, shares it, and has the (mock) agent fill a field and wait.
    private func shootBrowser(_ driver: ShellDriver, controller: MainWindowController, threadID: SessionID) async {
        _ = await driver.select(.thread(threadID))
        controller.showBrowserPanel()
        driver.settle()
        guard let browser = controller.browser,
              let url = URL(string: "data:text/html;charset=utf-8," + (Self.browserPage.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")),
              browser.open(url), let set = browser.pane?.set, let tab = set.selectedTab
        else { return log("browser: could not open the preview page") }
        set.setShared(true, tab: tab.id)
        _ = set.newTab(url: URL(string: "data:text/html,<title>Docs</title>"), select: false, owner: .agent)
        let model = runtime.engine.browser.model(for: threadID)
        _ = await waitUntil(timeout: .seconds(10)) { model.status == .attached && !tab.isLoading }
        try? await Task.sleep(for: .milliseconds(400))
        let snapshot = await runtime.issueMockBrowserCommand(threadID, ["type": "snapshot", "tabID": .string(tab.id)])
        let content = snapshot?.value?["content"]?.stringValue ?? ""
        func ref(_ name: String) -> String? {
            content.split(separator: "\n").first { $0.contains(name) && $0.contains("@e") }.flatMap { $0.firstMatch(of: /@(e\d+)/).map { String($0.1) } }
        }
        if let name = ref("Full name") {
            _ = await runtime.issueMockBrowserCommand(threadID, ["type": "fill", "tabID": .string(tab.id), "ref": .string(name), "text": "Ada Lovelace"])
        }
        if let email = ref("Email") {
            _ = await runtime.issueMockBrowserCommand(threadID, ["type": "click", "tabID": .string(tab.id), "ref": .string(email)])
        }
        Task { _ = await runtime.issueMockBrowserCommand(threadID, ["type": "wait", "tabID": .string(tab.id), "condition": "text", "text": "never", "timeoutMs": 20_000]) }
        _ = await waitUntil(timeout: .seconds(5)) { tab.agentActivity != nil }
        driver.settle()
    }

    // MARK: Rendering

    /// Renders the window (and overlays above it) in light and dark at both sizes. `place` positions extra windows
    /// after each resize.
    func render(_ driver: ShellDriver, state: String, place: ((NSRect) -> Void)? = nil) async -> [String] {
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
                SnapshotRunner.draw(frameView, into: bitmap)
                await compositeWebViews(in: frameView, onto: bitmap)
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

    /// `cacheDisplay` cannot see WebKit's remote layers: draws each visible web view's own snapshot at its place, then
    /// the browser's agent overlays above it.
    private func compositeWebViews(in frameView: NSView, onto bitmap: NSBitmapImageRep) async {
        var webViews: [WKWebView] = []
        var overlays: [NSView] = []
        func collect(_ view: NSView) {
            if let webView = view as? WKWebView, !webView.isHiddenOrHasHiddenAncestor { webViews.append(webView) }
            if ["BrowserHighlightView", "AgentCursorView"].contains(String(describing: type(of: view))), !view.isHiddenOrHasHiddenAncestor {
                overlays.append(view)
            }
            for child in view.subviews { collect(child) }
        }
        collect(frameView)
        var layers: [(NSImage, NSRect)] = []
        for webView in webViews {
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = false
            guard let image = try? await webView.takeSnapshot(configuration: configuration) else { continue }
            layers.append((image, webView.convert(webView.bounds, to: frameView)))
        }
        for overlay in overlays {
            guard let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else { continue }
            SnapshotRunner.draw(overlay, into: rep)
            let image = NSImage(size: overlay.bounds.size)
            image.addRepresentation(rep)
            layers.append((image, overlay.convert(overlay.bounds, to: frameView)))
        }
        guard !layers.isEmpty, let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for (image, rect) in layers {
            var target = rect
            if frameView.isFlipped { target.origin.y = frameView.bounds.height - rect.maxY }
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
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
            SnapshotRunner.draw(view, into: rep)
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

    /// Renders a view into a bitmap like `cacheDisplay`, but without font smoothing: in-process rendering otherwise
    /// thickens stems so 13 pt regular reads as medium, unlike the screen (docs/design/implementation-guide.md).
    /// Glass surfaces draw their opaque fallback (in-process rendering cannot capture vibrancy).
    static func draw(_ view: NSView, into bitmap: NSBitmapImageRep) {
        DSGlassView.forcesSolidFallback = true
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return view.cacheDisplay(in: view.bounds, to: bitmap) }
        context.cgContext.setAllowsFontSmoothing(false)
        context.cgContext.setShouldSmoothFonts(false)
        view.displayIgnoringOpacity(view.bounds, in: context)
    }

    func log(_ message: String) {
        print("snapshot: \(message)")
        fflush(stdout)
    }
}
