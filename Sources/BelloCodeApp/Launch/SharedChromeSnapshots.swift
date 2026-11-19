import AppKit
import BelloCore
import ContainerKit
import DesignSystem
import Engine
import OpenCodeKit
import SwiftUI

/// `--snapshot chrome` (docs/features/shared-browser.md): the Chrome tab with the live view and the driver overlay, the
/// Take Over state, Settings ▸ Browser ▸ Shared Chrome, and the approval card for the browse MCP server, light and dark,
/// on mock data. The stream is a drawn stand-in for the noVNC canvas (WebKit cannot render a hidden live page here).
extension SnapshotRunner {
    func runSharedChrome() async -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log("FAIL cannot create \(directory.path): \(error)")
            return false
        }
        DSGlassView.forcesSolidFallback = true
        let engine = runtime.engine
        guard let service = engine.sharedBrowser else { return false }
        let settings = AppSettings(defaults: nil)
        let services = AppServices(settings: settings, auth: runtime.auth)
        let workspace = WorkspaceController(engine: engine, stateStore: ShellStateStore(defaults: nil))
        let controller = MainWindowController(
            workspace: workspace,
            configuration: .init(surfaces: .builtIn(services: services), autosaveSuffix: nil, sourceLabel: runtime.sourceLabel))
        guard controller.window != nil else { return false }
        controller.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
        controller.showWindow(nil)
        let driver = ShellDriver(controller: controller)
        var written: [String] = []

        await engine.start()
        guard await waitUntil(timeout: .seconds(20), { engine.root.connection == .live && !engine.root.projects.isEmpty }) else {
            log("FAIL mock never became live")
            return false
        }
        _ = await waitUntil(timeout: .seconds(5)) {
            engine.root.projects.allSatisfy { workspace.projectModel($0).map { !$0.sessionIDs.isEmpty } ?? false }
        }
        guard let project = engine.root.projects.first, let threads = workspace.projectModel(project)?.sessionIDs, threads.count >= 2 else {
            log("FAIL the mock scenario has too few threads")
            return false
        }
        let thread = threads[0], other = threads[1]
        var mine = BrowserBinding(sessionID: thread.rawValue, project: project.directory, group: BrowserNaming.group(sessionID: thread.rawValue))
        mine.remember(mine.group + "-docs")
        let theirs = BrowserBinding(sessionID: other.rawValue, project: project.directory, group: BrowserNaming.group(sessionID: other.rawValue))
        let status = BrowserRuntimeStatus(sandbox: "ok", relay: "up", extension: "connected", paired: true, caCount: 3, chromiumRestarts: 0,
                                          profileBytes: 186_000_000, downloadBytes: 2_400_000, cacheBytes: 41_000_000, extensionID: "edmgncelohfohgbnndopcehdehmeoblj",
                                          chromium: "Chromium 156.0.8078.79 built on Debian GNU/Linux 12 (bookworm)", browse: "0.1.5")
        let title = engine.orchestration?.graph.nodes[thread]?.title ?? "this thread"
        service.showForSnapshots(
            phase: .ready, status: status, bindings: [mine, theirs],
            activity: [mine.mainTab: BrowserTabGate.TabActivity(running: title, driver: nil, human: false, queued: 1, lastUsedBy: title)],
            humanControl: [], approved: [project.directory], imageTag: "bellocode-browser:3f9c2a71d04be6e5", viewers: 1)

        // 1. The Chrome tab: live view with the overlay naming the thread that drives.
        _ = await driver.select(.thread(thread))
        let model = workspace.threadModel(thread)
        _ = await waitUntil(timeout: .seconds(5)) { model.phase == .ready }
        controller.showSharedChromePanel()
        controller.sharedChrome?.pane?.snapshotStream = Self.mockChromeStream(group: mine.group, label: service.labels[project.directory] ?? "project")
        driver.settle(10)
        if only.isEmpty || only.contains("panel") { written += await render(driver, state: "panel") }

        // 2. Take Over: the person has control; agents get Busy.
        service.showForSnapshots(phase: .ready, status: status, bindings: [mine, theirs], activity: [:], humanControl: ["*"],
                                 approved: [project.directory], imageTag: "bellocode-browser:3f9c2a71d04be6e5", viewers: 1)
        driver.settle(6)
        if only.isEmpty || only.contains("takeover") { written += await render(driver, state: "takeover") }

        // 3. The approval card for the browse MCP server (pinned above the composer).
        service.showForSnapshots(phase: .stopped, status: nil, bindings: [], activity: [:], humanControl: [], approved: [])
        _ = await service.requestAccess(session: other.rawValue, directory: project.directory)
        _ = await driver.select(.thread(other))
        let otherModel = workspace.threadModel(other)
        _ = await waitUntil(timeout: .seconds(5)) { otherModel.pendingRequests.contains { $0.isApp } }
        controller.split.setCollapsed(controller.split.panelItem, true)
        driver.settle(10)
        if only.isEmpty || only.contains("approval") { written += await render(driver, state: "approval") }

        // 4. Settings ▸ Browser ▸ Shared Chrome.
        service.showForSnapshots(phase: .ready, status: status, bindings: [mine, theirs], activity: [:], humanControl: [],
                                 approved: [project.directory], imageTag: "bellocode-browser:3f9c2a71d04be6e5", viewers: 1)
        written += await renderHosted(
            ScrollView { SharedChromeSettingsGroup(service: service, confirmClear: { false }).frame(width: 520).padding(20) }
                .frame(width: 560, height: 980).background(SwiftUI.Color.ds.canvas),
            state: "settings", title: "Browser")

        workspace.close()
        controller.close()
        for path in written { log("wrote \(path)") }
        log(written.isEmpty ? "FAIL nothing written" : "PASS \(written.count) images")
        return !written.isEmpty
    }

    /// A drawn stand-in for the noVNC canvas: a Chromium window with a tab group and a sign-in form.
    static func mockChromeStream(group: String, label: String) -> NSImage {
        NSImage(size: NSSize(width: 1280, height: 800), flipped: true) { rect in
            NSColor(white: 0.93, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.85, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 84).fill()
            let groupChip = NSRect(x: 12, y: 10, width: 150, height: 28)
            NSColor.systemBlue.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: groupChip, xRadius: 8, yRadius: 8).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white]
            (group as NSString).draw(at: NSPoint(x: 22, y: 15), withAttributes: attrs)
            for (index, tabTitle) in ["Sign in · Atlas", "Docs"].enumerated() {
                let tab = NSRect(x: 172 + CGFloat(index) * 210, y: 8, width: 200, height: 32)
                NSColor(white: index == 0 ? 0.98 : 0.9, alpha: 1).setFill()
                NSBezierPath(roundedRect: tab, xRadius: 8, yRadius: 8).fill()
                (tabTitle as NSString).draw(at: NSPoint(x: tab.minX + 14, y: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.2, alpha: 1)])
            }
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 12, y: 48, width: rect.width - 24, height: 28), xRadius: 14, yRadius: 14).fill()
            ("https://\(label).bc:5173/login" as NSString).draw(at: NSPoint(x: 30, y: 54), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(white: 0.25, alpha: 1)])
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 440, y: 200, width: 400, height: 330), xRadius: 12, yRadius: 12).fill()
            ("Sign in to Atlas" as NSString).draw(at: NSPoint(x: 470, y: 228), withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: NSColor(white: 0.1, alpha: 1)])
            for (index, field) in ["Email", "Password"].enumerated() {
                let box = NSRect(x: 470, y: 290 + CGFloat(index) * 70, width: 340, height: 40)
                NSColor(white: 0.6, alpha: 1).setStroke()
                NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).stroke()
                (field as NSString).draw(at: NSPoint(x: box.minX + 12, y: box.minY + 11), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(white: 0.5, alpha: 1)])
            }
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: NSRect(x: 470, y: 440, width: 340, height: 44), xRadius: 6, yRadius: 6).fill()
            ("Continue" as NSString).draw(at: NSPoint(x: 610, y: 452), withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.white])
            return true
        }
    }
}
