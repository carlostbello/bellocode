import AppKit
import BelloCore
import Engine

/// `--snapshot <name>`: builds the real window against a mock scenario, renders it to PNG in light and dark
/// appearance at two sizes, and exits. The shell cannot take screenshots, so the window renders itself
/// (`cacheDisplay`) from inside the process (AGENTS.md, "Environment").
///
/// Files: `<directory>/<name>-<state>-<light|dark>-<width>x<height>.png`. States: `thread` (a thread with a pending
/// approval pinned above the composer), `panels` (same, with the right panel and terminal drawer open), `draft`
/// (a new-thread draft), `empty` (no projects).
@MainActor
struct SnapshotRunner {
    let runtime: AppRuntime
    let name: String
    let directory: URL

    func run() async -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log("FAIL cannot create \(directory.path): \(error)")
            return false
        }
        let engine = runtime.engine
        let workspace = WorkspaceController(engine: engine, stateStore: ShellStateStore(defaults: nil))
        let controller = MainWindowController(
            workspace: workspace, configuration: .init(autosaveSuffix: nil, sourceLabel: runtime.sourceLabel))
        guard let window = controller.window else { return false }
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        controller.showWindow(nil)

        // Empty state first: the window before the engine has loaded anything.
        var written: [String] = []
        written += render(window, state: "empty", sizes: [NSSize(width: 980, height: 640)], appearances: [.aqua])

        await engine.start()
        guard await waitUntil(timeout: .seconds(20), { engine.root.connection == .live && !engine.root.projects.isEmpty }) else {
            log("FAIL mock never became live (\(engine.root.connection.label))")
            return false
        }
        // Wait for every project's sessions so the sidebar is complete.
        _ = await waitUntil(timeout: .seconds(5)) {
            engine.root.projects.allSatisfy { item in workspace.projectModel(item).map { !$0.sessionIDs.isEmpty } ?? false }
        }
        guard let project = engine.root.projects.first, let threadID = workspace.projectModel(project)?.sessionIDs.first else {
            log("FAIL no thread in the mock scenario")
            return false
        }
        workspace.select(.thread(threadID))
        let thread = workspace.threadModel(threadID)
        _ = await waitUntil(timeout: .seconds(5)) { thread.phase == .ready && !thread.messageIDs.isEmpty }
        // Start a scripted turn that stops at a permission request, so the request stack shows.
        await runtime.enqueueMockScript(named: "full-tour")
        thread.draft = "Give me a tour of this project."
        _ = await thread.send()
        if !(await waitUntil(timeout: .seconds(15), { !thread.pendingRequests.isEmpty })) {
            log("note: no pending request appeared; rendering without one")
        }
        try? await Task.sleep(for: .milliseconds(300))

        let sizes = [NSSize(width: 1280, height: 800), NSSize(width: 980, height: 640)]
        written += render(window, state: "thread", sizes: sizes, appearances: [.aqua, .darkAqua])

        controller.split.setCollapsed(controller.split.panelItem, false)
        controller.split.setCollapsed(controller.split.contentSplit.drawerItem, false)
        written += render(window, state: "panels", sizes: [sizes[0]], appearances: [.aqua, .darkAqua])
        controller.split.setCollapsed(controller.split.panelItem, true)
        controller.split.setCollapsed(controller.split.contentSplit.drawerItem, true)

        workspace.select(.draft(directory: engine.root.projects.last?.directory ?? project.directory))
        try? await Task.sleep(for: .milliseconds(100))
        written += render(window, state: "draft", sizes: [sizes[1]], appearances: [.aqua, .darkAqua])

        workspace.close()
        controller.close()
        for path in written { log("wrote \(path)") }
        log(written.isEmpty ? "FAIL nothing written" : "PASS \(written.count) images")
        return !written.isEmpty
    }

    private func render(_ window: NSWindow, state: String, sizes: [NSSize], appearances: [NSAppearance.Name]) -> [String] {
        var paths: [String] = []
        for appearanceName in appearances {
            window.appearance = NSAppearance(named: appearanceName)
            for size in sizes {
                window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
                settle(window)
                guard let frameView = window.contentView?.superview else { continue }
                let bounds = frameView.bounds
                guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
                frameView.cacheDisplay(in: bounds, to: bitmap)
                let mode = appearanceName == .darkAqua ? "dark" : "light"
                let file = directory.appending(path: "\(name)-\(state)-\(mode)-\(Int(size.width))x\(Int(size.height)).png")
                guard let data = bitmap.representation(using: .png, properties: [:]), (try? data.write(to: file)) != nil else { continue }
                paths.append(file.path)
            }
        }
        return paths
    }

    /// Lets observation loops and layout catch up (they run on the next main run-loop turns).
    private func settle(_ window: NSWindow) {
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func log(_ message: String) {
        print("snapshot: \(message)")
        fflush(stdout)
    }
}
