import AppKit
import BrowserKit
import OrchestrationUI
import BelloCore
import Engine
import MockOpenCode
import OpenCodeKit
import TranscriptKit

/// `--snapshot extras` (M3-B, docs/features/orchestration-extras.md): the Scheduled Tasks pane, MR chips and the Merge
/// Requests tab, a secret request card, an app approval card and an HTML visual in the transcript (snapshot and live),
/// in light and dark, on mock data (in-memory vault, recorded GitLab answers on a self-managed instance with a path prefix).
extension SnapshotRunner {
    func runExtras() async -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log("FAIL cannot create \(directory.path): \(error)")
            return false
        }
        let engine = runtime.engine
        guard let extras = engine.extras else { return false }
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
        let renderer = HTMLVisualRendererHolder.shared
        extras.visuals.renderer = renderer

        await engine.start()
        guard await waitUntil(timeout: .seconds(20), { engine.root.connection == .live && !engine.root.projects.isEmpty }) else {
            log("FAIL mock never became live")
            return false
        }
        _ = await waitUntil(timeout: .seconds(5)) {
            engine.root.projects.allSatisfy { workspace.projectModel($0).map { !$0.sessionIDs.isEmpty } ?? false }
        }
        guard let project = engine.root.projects.first, let threads = workspace.projectModel(project)?.sessionIDs, threads.count >= 3 else {
            log("FAIL the mock scenario has too few threads")
            return false
        }
        for id in threads { try? await engine.markViewed(id) }
        let orchestration = engine.orchestration!
        func call(_ tool: String, _ arguments: [String: OpenCodeKit.JSONValue], from thread: SessionID) async -> ClientMCPResult {
            await orchestration.handleAppTool(
                ClientMCPCall(tool: tool, arguments: .object(arguments), sessionID: thread.rawValue, directory: project.directory))
        }

        // 1. Merge requests: a linked, watched MR whose pipeline fails while a review is in progress; a second, approved one
        // linked from the branch. The instance is configured as the person would in Settings ▸ GitLab.
        _ = try? await extras.mergeRequests.saveInstance(baseURL: MockGitLab.instance.baseURL, token: nil)
        let mrThread = threads[0]
        _ = await driver.select(.thread(mrThread))
        _ = await waitUntil(timeout: .seconds(5)) { workspace.threadModel(mrThread).phase == .ready }
        _ = try? await extras.mergeRequests.link([MockGitLab.ref], to: mrThread, source: .output, watch: false)
        _ = try? await extras.mergeRequests.link([MockGitLab.secondRef], to: mrThread, source: .branch)
        try? await extras.mergeRequests.setWatching(MockGitLab.ref, for: mrThread, true)
        await extras.mergeRequests.waitForFetches()
        await extras.mergeRequests.pollDue()
        _ = await waitUntil(timeout: .seconds(5)) { extras.mergeRequests.watch(mrThread, MockGitLab.ref.url)?.baseline != nil }
        if let transport = engine.configuration.forgeTransport as? FixtureForgeTransport { MockGitLab.finish(transport) }
        // The 2 s mock poll interval finds the finished checks and wakes the thread once.
        _ = await waitUntil(timeout: .seconds(8)) { extras.mergeRequests.watch(mrThread, MockGitLab.ref.url)?.wakes == 1 }
        _ = await waitUntil(timeout: .seconds(5)) { !workspace.threadModel(mrThread).isRunning }
        driver.perform(.showMergeRequests)
        driver.settle(10)
        try? await Task.sleep(for: .milliseconds(300))
        driver.settle(6)
        await shoot("mr")

        // 2. A secret request card (pinned above the composer), from a scripted turn that calls request_secret.
        let secretThread = threads[1]
        _ = await driver.select(.thread(secretThread))
        let secretModel = workspace.threadModel(secretThread)
        _ = await waitUntil(timeout: .seconds(5)) { secretModel.phase == .ready }
        let askedText = "Asked the user for “npm publish token” in a private card. You will be woken with a message when they save it (with a one-use reference, never the value) or decline. End your turn now; do not ask for the value in chat."
        await runtime.enqueueMockScript(
            TurnScript(name: "snapshot-secret") {
                TurnStep.text("The release build passed. Publishing needs an npm token, so I asked for it privately.\n\n")
                TurnStep.tool(
                    "bellocode_app_request_secret",
                    input: ["label": "npm publish token", "reason": "To publish @acme/rocket 2.0.0.", "url": "https://www.npmjs.com/settings/tokens"],
                    output: askedText, duration: 15)
                TurnStep.text("I'll continue once you save it; you'll approve the command that uses it.")
            }, for: secretThread)
        driver.type("Publish 2.0.0 to npm.")
        driver.send()
        _ = await waitUntil(timeout: .seconds(15)) { secretModel.messageIDs.count >= 2 && !(secretModel.session?.isRunning ?? true) }
        // What the tool call did during that turn: the card (the mock does not route client-MCP calls).
        _ = await call(
            ExtrasTools.requestSecret,
            ["label": "npm publish token", "reason": "To publish @acme/rocket 2.0.0 to the npm registry after the release build.",
             "url": "https://www.npmjs.com/settings/tokens"], from: secretThread)
        if !(await waitUntil(timeout: .seconds(5)) { secretModel.pendingRequests.contains { $0.isApp } }) {
            log("note: the secret card did not appear")
        }
        controller.split.setCollapsed(controller.split.panelItem, true)
        driver.settle(10)
        await shoot("secret")
        controller.split.setCollapsed(controller.split.panelItem, false)

        // 3. An HTML visual in the transcript: a chart rendered through html_render (snapshot row), then made live.
        let visualThread = threads[2]
        _ = await driver.select(.thread(visualThread))
        let visualModel = workspace.threadModel(visualThread)
        _ = await waitUntil(timeout: .seconds(5)) { visualModel.phase == .ready }
        let rendered = await call(ExtrasTools.htmlRender, ["title": "Parser benchmark, 1.9 vs 2.0", "html": .string(Self.chartHTML)], from: visualThread)
        await runtime.enqueueMockScript(
            TurnScript(name: "snapshot-visual") {
                TurnStep.text("Here is the comparison across the five benchmark inputs.\n\n")
                TurnStep.tool(
                    "bellocode_app_html_render", input: ["title": "Parser benchmark, 1.9 vs 2.0", "html": "<html>…</html>"],
                    output: rendered.text, duration: 120)
                TurnStep.text("2.0 is faster on every input; the biggest win is deeply nested expressions (−41 %).")
            }, for: visualThread)
        driver.type("Chart the benchmark results.")
        driver.send()
        _ = await waitUntil(timeout: .seconds(8)) { !visualModel.isRunning && visualModel.messageIDs.count >= 2 }
        controller.split.setCollapsed(controller.split.panelItem, true)
        driver.settle(10)
        try? await Task.sleep(for: .milliseconds(800))
        driver.settle(10)
        await shoot("visual")
        if let surface = controller.container.transcriptSurface, let id = rendered.text.split(separator: "\n").first?.split(separator: " ").last {
            surface.visualOverlay?.focus(String(id))
            try? await Task.sleep(for: .milliseconds(800))
            driver.settle(6)
            await shoot("visual-live")
        }
        controller.split.setCollapsed(controller.split.panelItem, false)

        // 4. An agent's first scheduled task in a project: the approval card.
        _ = await driver.select(.thread(mrThread))
        _ = await call(
            ExtrasTools.scheduleTask,
            ["name": "Nightly dependency check", "prompt": "Check for outdated dependencies and open a merge request with safe updates.", "time": "02:30",
             "weekdays": .array(["mon", "tue", "wed", "thu", "fri"])], from: mrThread)
        _ = await waitUntil(timeout: .seconds(5)) { workspace.threadModel(mrThread).pendingRequests.contains { $0.isApp } }
        driver.settle(10)
        await shoot("approval")

        // 5. Settings ▸ Scheduled Tasks: user tasks (one ran, one paused) beside the agent's pending one.
        let now = Date()
        if let daily = try? await extras.schedules.create(
            ScheduledTask(name: "Morning triage", prompt: "Triage issues opened since yesterday and label them.", rule: .daily(hour: 9, minute: 0, weekdays: [2, 3, 4, 5, 6]),
                directory: project.directory, created: now))
        {
            try? await extras.schedules.runNow(daily.id)
        }
        if let paused = try? await extras.schedules.create(
            ScheduledTask(name: "Weekly changelog", prompt: "Draft the changelog for merged PRs this week.", rule: .daily(hour: 17, minute: 30, weekdays: [6]),
                directory: project.directory, created: now))
        {
            try? await extras.schedules.setEnabled(paused.id, false)
        }
        _ = try? await extras.schedules.create(
            ScheduledTask(name: "CI flake watch", prompt: "Re-run flaky CI jobs on open PRs.", rule: .interval(minutes: 30), directory: project.directory, created: now))
        let settingsWindow = SettingsWindowController(
            settings: settings, auth: nil, importSource: nil, engine: engine, notifier: nil, openThread: { _ in })
        settingsWindow.show(pane: "schedules")
        if let model = Self.scheduleModel(in: settingsWindow), let first = extras.schedules.tasks.first(where: { $0.name == "Morning triage" }) {
            model.select(first.id)
        }
        settingsWindow.window?.setFrameOrigin(NSPoint(x: 60, y: 60))
        try? await Task.sleep(for: .milliseconds(300))
        if only.isEmpty || only.contains("schedules") { written += await renderWindow(settingsWindow.window, state: "schedules") }
        settingsWindow.show(pane: "gitlab")
        if let model = extras.mergeRequests as MergeRequestService? { _ = await model.testConnection(MockGitLab.instance) }
        try? await Task.sleep(for: .milliseconds(200))
        if only.isEmpty || only.contains("gitlab") { written += await renderWindow(settingsWindow.window, state: "gitlab") }
        settingsWindow.show(pane: "secrets")
        _ = try? await extras.respond(to: (await extras.pendingAppRequests().first { if case .secret = $0.kind { true } else { false } })?.id ?? "", .saveSecret(SecretValue("mock-not-a-real-token")))
        try? await Task.sleep(for: .milliseconds(200))
        if only.isEmpty || only.contains("secrets") { written += await renderWindow(settingsWindow.window, state: "secrets") }
        settingsWindow.close()

        workspace.close()
        controller.close()
        for path in written { log("wrote \(path)") }
        log(written.isEmpty ? "FAIL nothing written" : "PASS \(written.count) images")
        return !written.isEmpty
    }

    /// Renders a non-main window (Settings) in light and dark at its own size.
    func renderWindow(_ window: NSWindow?, state: String) async -> [String] {
        guard let window else { return [] }
        var paths: [String] = []
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearanceName)
            window.appearance = NSAppearance(named: appearanceName)
            window.displayIfNeeded()
            for _ in 0..<6 { try? await Task.sleep(for: .milliseconds(30)) }
            guard let frameView = window.contentView?.superview, let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
                continue
            }
            SnapshotRunner.draw(frameView, into: bitmap)
            let mode = appearanceName == .darkAqua ? "dark" : "light"
            let file = directory.appending(path: "\(name)-\(state)-\(mode).png")
            guard let data = bitmap.representation(using: .png, properties: [:]), (try? data.write(to: file)) != nil else { continue }
            paths.append(file.path)
        }
        NSApp.appearance = nil
        return paths
    }

    static func scheduleModel(in controller: SettingsWindowController) -> ScheduledTasksModel? {
        ScheduledTasksModelRegistry.last
    }

    static let chartHTML = """
        <!doctype html><html><head><style>
        h3 { margin: 0 0 6px; font-weight: 600; font-size: 13px; }
        .legend { display: flex; gap: 14px; font-size: 12px; color: var(--muted); margin-bottom: 10px; }
        .sw { display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 5px; vertical-align: -1px; }
        .row { display: grid; grid-template-columns: 150px 1fr; align-items: center; gap: 10px; margin: 6px 0; font-size: 12px; }
        .bars { display: flex; flex-direction: column; gap: 3px; }
        .bar { height: 10px; border-radius: 3px; }
        .val { font: 11px var(--font-mono); color: var(--muted); margin-left: 6px; }
        .axis { border-top: 1px solid var(--border); margin-top: 8px; padding-top: 4px; font-size: 11px; color: var(--muted); }
        </style></head><body>
        <h3>Parse time per input (ms, lower is better)</h3>
        <div class="legend"><span><span class="sw" style="background:var(--chart-2)"></span>1.9</span><span><span class="sw" style="background:var(--chart-1)"></span>2.0</span></div>
        <div id="rows"></div>
        <div class="axis">Median of 30 runs on an M2 Pro · bars scaled to 200 ms</div>
        <script>
        const data = [["small.json", 12, 10], ["config.yaml", 31, 24], ["grammar.ebnf", 88, 61], ["nested.expr", 190, 112], ["large.json", 164, 140]];
        const rows = document.getElementById("rows");
        for (const [name, old, now] of data) {
          const row = document.createElement("div"); row.className = "row";
          row.innerHTML = `<div>${name}</div><div class="bars">
            <div><span class="bar" style="display:inline-block;width:${old / 2}%;background:var(--chart-2)"></span><span class="val">${old}</span></div>
            <div><span class="bar" style="display:inline-block;width:${now / 2}%;background:var(--chart-1)"></span><span class="val">${now}</span></div></div>`;
          rows.appendChild(row);
        }
        </script></body></html>
        """
}

/// The Scheduled Tasks pane's model (snapshots select a task in it).
@MainActor
enum ScheduledTasksModelRegistry {
    static weak var last: ScheduledTasksModel?
}

/// The offscreen renderer the snapshot run shares (one hidden window).
@MainActor
enum HTMLVisualRendererHolder {
    static let shared = HTMLVisualRenderer()
}
