import AgentUI
import AppKit
import BelloCore
import Engine
import MockOpenCode

/// `--snapshot nav`: the sidebar sections in every state, multi-selection, a drop's insertion gap (forced), the snooze
/// picker, the Undo toast, the palette (actions, threads, files), message search, grouping by state and the
/// Notifications settings, in light and dark (docs/features/navigation.md).
extension SnapshotRunner {
    func runNavigation() async -> Bool {
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
        func shoot(_ state: String, place: ((NSRect) -> Void)? = nil) async {
            guard only.isEmpty || only.contains(state) else { return }
            written += await render(driver, state: state, place: place)
        }

        await engine.start()
        guard await waitUntil(timeout: .seconds(20), { engine.root.connection == .live && engine.root.projects.count >= 3 }) else {
            log("FAIL mock never became live")
            return false
        }
        _ = await waitUntil(timeout: .seconds(5)) {
            engine.root.projects.allSatisfy { workspace.projectModel($0).map { $0.sessionIDs.count >= 3 } ?? false }
        }
        let projects = engine.root.projects
        let main = workspace.projectModel(projects[0])?.sessionIDs ?? []
        let second = workspace.projectModel(projects[1])?.sessionIDs ?? []
        guard main.count >= 8, second.count >= 3 else {
            log("FAIL the workspace scenario is too small (\(main.count), \(second.count))")
            return false
        }
        let now = Timestamp.now
        // The mock's history is all unread; mark it seen so the snapshot shows a realistic "Needs you".
        for project in projects {
            for id in workspace.projectModel(project)?.sessionIDs ?? [] { try? await engine.markViewed(id) }
        }

        // Every state: pinned, running (Working), blocked (Needs you), failed, finished unread, snoozed, settled.
        engine.organise([main[0], main[1]], .pin, now: now)
        engine.organise([main[6], main[7]], .settle, now: now)
        if main.count > 8 { engine.organise(Array(main[8...]), .settle, now: now) }
        engine.organise([main[5]], .snooze(until: Timestamp(SnoozePreset.tomorrow.date(from: Date()))), now: now)
        await runtime.enqueueMockScript(Self.longTurn, for: main[2])
        _ = try? await engine.send("Refactor the parser into smaller functions.", to: main[2])
        try? await engine.setPermissionMode(.ask, for: main[3])
        await runtime.enqueueMockScript(Self.shellApproval, for: main[3])
        _ = try? await engine.send("Clean the build folder and rebuild.", to: main[3])
        await runtime.enqueueMockScript(Self.failure, for: second[0])
        _ = try? await engine.send("Upgrade the dependencies.", to: second[0])
        await runtime.enqueueMockScript(Self.quick, for: second[1])
        _ = try? await engine.send("Summarise the open issues.", to: second[1])
        _ = await waitUntil(timeout: .seconds(10)) {
            engine.root.attention.counts.approvals > 0 && engine.root.attention.counts.failed > 0 && engine.root.attention.counts.running > 0
        }
        _ = await waitUntil(timeout: .seconds(5)) { engine.root.attention.counts.unread > 0 }

        // The selected thread is the running one; Snoozed and Settled are opened to show their rows.
        _ = await driver.select(.thread(main[2]))
        controller.sidebar.setSection(.section(scope: projects[0].directory, .snoozed), expanded: true)
        controller.sidebar.setSection(.section(scope: projects[0].directory, .settled), expanded: true)
        await driver.idle(8)
        await shoot("sections")

        // Multi-selection (⇧-click): three threads, the toolbar and menus act on all of them.
        controller.window?.makeFirstResponder(controller.sidebar.outlineView)
        controller.sidebar.selectThreads([main[0], main[1], main[4]])
        await driver.idle(4)
        await shoot("multiselect")

        // A drop's insertion gap and badge, forced (a real drag needs a person).
        controller.sidebar.selectThreads([main[4]])
        controller.sidebar.showDropPreview(threads: [main[4]], section: .section(scope: projects[0].directory, .pinned), index: 1)
        await driver.idle(4)
        await shoot("drag-gap")
        controller.sidebar.showDropPreview(threads: [], section: nil)
        controller.sidebar.showDropPreview(
            threads: [main[4]], section: .section(scope: projects[1].directory, .active), index: 0)
        await driver.idle(4)
        await shoot("drag-forbidden")
        controller.sidebar.showDropPreview(threads: [], section: nil)

        // The snooze picker beside its row.
        controller.window?.makeFirstResponder(controller.sidebar.outlineView)
        controller.sidebar.selectThreads([main[4]])
        controller.presentSnoozePicker(for: [main[4]])
        await driver.idle(6)
        await shoot("snooze")
        driver.closeOverlays()

        // The Undo toast after settling from the Thread menu.
        controller.sidebar.selectThreads([main[4]])
        controller.window?.makeFirstResponder(controller.sidebar.outlineView)
        driver.perform(.settleThread)
        await driver.idle(4)
        await shoot("undo-toast")
        workspace.undo.undoFromToast()
        await driver.idle(4)

        // The palette: actions (⌘K), threads (@), files (/), and message search (⇧⌘F).
        let palette = controller.palette
        let place: (NSRect) -> Void = { _ in palette.reposition() }
        _ = await driver.select(.thread(main[2]))
        palette.show(.commands, in: controller)
        await driver.idle(3)
        await shoot("palette-actions", place: place)
        let title = workspace.session(main[6])?.displayTitle ?? "a"
        palette.setQuery("@" + String(title.split(separator: " ").first ?? "a").lowercased())
        await driver.idle(3)
        await shoot("palette-threads", place: place)
        palette.show(.quickOpen, in: controller, query: "/pars")
        palette.setQuery("/pars")
        await palette.settleSearches()
        await driver.idle(3)
        await shoot("palette-files", place: place)
        palette.hide()
        let thread = workspace.threadModel(main[6])
        _ = await waitUntil(timeout: .seconds(5)) { thread.phase == .ready }
        await engine.flush()
        let word = thread.messageIDs.compactMap { thread.message($0)?.message.searchableText }
            .flatMap { $0.split(whereSeparator: { !$0.isLetter }).map(String.init) }.first { $0.count >= 6 } ?? "parser"
        palette.show(.messages, in: controller, query: word)
        palette.setQuery(word)
        await palette.settleSearches()
        await driver.idle(3)
        await shoot("search", place: place)
        palette.hide()

        // All threads by state (the flat list).
        workspace.setGrouping(.byState)
        await driver.idle(6)
        await shoot("by-state")
        workspace.setGrouping(.byProject)

        // Settings ▸ Notifications and ▸ Threads.
        if only.isEmpty || only.contains("settings-notifications") || only.contains("settings-threads") || only.contains("settings-acknowledgements") {
            let notifier = AttentionNotifier(engine: engine, settings: settings, delivery: nil, defaults: nil)
            let settingsWindow = SettingsWindowController(
                settings: settings, auth: nil, importSource: nil, engine: engine, notifier: notifier)
            settings.notifications.mutedProjects = [projects[2].directory]
            for pane in ["notifications", "threads", "acknowledgements"] where only.isEmpty || only.contains("settings-\(pane)") {
                settingsWindow.show(pane: pane)
                await driver.idle(6)
                if let panel = settingsWindow.window { written += renderStandalone(panel, state: "settings-\(pane)") }
            }
            settingsWindow.close()
        }

        workspace.close()
        controller.close()
        for path in written { log("wrote \(path)") }
        log(written.isEmpty ? "FAIL nothing written" : "PASS \(written.count) images")
        return !written.isEmpty
    }

    /// Renders a window on its own in light and dark (Settings).
    private func renderStandalone(_ window: NSWindow, state: String) -> [String] {
        var paths: [String] = []
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearanceName)
            window.appearance = NSAppearance(named: appearanceName)
            for _ in 0..<4 {
                MainRunLoop.run(for: .milliseconds(30))
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            guard let frameView = window.contentView?.superview,
                  let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
            else { continue }
            SnapshotRunner.draw(frameView, into: bitmap)
            let mode = appearanceName == .darkAqua ? "dark" : "light"
            let file = directory.appending(path: "\(name)-\(state)-\(mode).png")
            guard let data = bitmap.representation(using: .png, properties: [:]), (try? data.write(to: file)) != nil else { continue }
            paths.append(file.path)
        }
        NSApp.appearance = nil
        return paths
    }

    static let failure = TurnScript(name: "snapshot-failure") {
        TurnStep.text("Checking the lock file first.\n\n")
        TurnStep.fail("The provider is overloaded. Try again in a minute.", status: 529)
    }

    static let quick = TurnScript(name: "snapshot-quick") {
        TurnStep.text("There are four open issues; two are about the parser.", chunkSize: 8, rate: 200)
    }
}
