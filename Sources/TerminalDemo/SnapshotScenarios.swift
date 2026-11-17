import AppKit
import BelloCore
import DesignSystem
import Engine
import Foundation
import MockOpenCode
import OpenCodeKit
@testable import SwiftTerm
@testable import TerminalKit

/// Renders the drawer in its states against MockOpenCode's scripted shell: empty, one terminal, two tabs, split,
/// exited, find bar, and a right-panel tab, each in light and dark.
@MainActor
final class SnapshotScenarios: TerminalWorkspaceDelegate {
    let project = "/Users/you/Projects/bellocode"
    var server: MockOpenCodeServer!
    var service: TerminalService!
    var workspace: TerminalWorkspace!
    var drawer: TerminalSurfaceController!
    var panel: TerminalSurfaceController!
    var terminals: ThreadTerminals!
    var window: DemoWindow!
    var panelWindow: DemoWindow!
    var failures: [String] = []
    var written: [String] = []

    func run() async -> Int32 {
        do {
            try await setUp()
            try await scenarios()
        } catch {
            failures.append("setup: \(error)")
        }
        workspace?.close()
        await service?.shutdown()
        await server?.stop()
        for path in written { print("snapshot: \(path)") }
        for failure in failures { print("FAIL: \(failure)") }
        print(failures.isEmpty ? "terminal snapshots: \(written.count) written" : "terminal snapshots: \(failures.count) failures")
        return failures.isEmpty ? 0 : 1
    }

    private func setUp() async throws {
        server = MockOpenCodeServer(
            scenario: .empty(directory: project), options: MockServerOptions(clock: .realTime, heartbeatInterval: nil))
        let endpoint = try await server.start()
        let client = OpenCodeClient(
            connection: ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? "")))
        let session = try await client.createSession(SessionCreateRequest(directory: project, title: "Terminal demo"))
        service = TerminalService(
            store: try ProjectionStore(location: .inMemory), client: { client },
            launch: TerminalLaunch(command: "/bin/zsh", args: ["-l"], environment: [:]))
        workspace = TerminalWorkspace(service: service, preferences: TerminalPreferences(fontSize: 12))
        workspace.delegate = self
        drawer = workspace.makeSurface(.drawer)
        panel = workspace.makeSurface(.panel)
        window = makeWindow(drawer.view, size: NSSize(width: 980, height: 280))
        panelWindow = makeWindow(panel.view, size: NSSize(width: 420, height: 360))
        terminals = service.terminals(for: SessionID(session.id))
        await terminals.waitUntilLoaded()
    }

    private func makeWindow(_ content: NSView, size: NSSize) -> DemoWindow {
        let window = DemoWindow(
            contentRect: NSRect(origin: NSPoint(x: -4000, y: 0), size: size), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.contentView = content
        window.setContentSize(size)
        return window
    }

    // MARK: Scenarios

    private func scenarios() async throws {
        drawer.display(nil, directory: project, isDraft: true)
        await snapshot("drawer-draft", drawer.view)
        drawer.display(terminals, directory: project)
        await snapshot("drawer-empty", drawer.view)

        // One terminal with a listing, colours and a link.
        guard let first = await terminals.create(directory: project, size: PTYSize(cols: 120, rows: 14)) else {
            throw DemoError("could not create a terminal")
        }
        await settle()
        try await type(first.id, ["ls", "colors", "link https://github.com/anomalyco/opencode opencode repository", "pwd"])
        await snapshot("drawer-one", drawer.view)

        // Two tabs; the second renamed and selected.
        guard let second = await terminals.create(directory: project + "/Sources", size: PTYSize(cols: 120, rows: 14)) else {
            throw DemoError("could not create a second terminal")
        }
        await terminals.rename(second.id, to: "dev server")
        await settle()
        try await type(second.id, ["echo Listening on http://localhost:5173", "title vite"])
        await snapshot("drawer-two-tabs", drawer.view)

        // Split side by side.
        terminals.select(first.id, in: .drawer)
        terminals.setSplit(second.id)
        drawer.reload()
        await settle()
        await snapshot("drawer-split", drawer.view)
        check(drawer.mountedIDs == [first.id, second.id], "split mounts both terminals")

        // Exited: the code stays on the tab and the bar offers Restart.
        terminals.setSplit(nil)
        terminals.select(second.id, in: .drawer)
        drawer.reload()
        try await type(second.id, ["false", "exit 1"])
        _ = await waitUntil(timeout: .seconds(3)) { self.terminals.record(second.id)?.state == .exited(code: 1) }
        check(terminals.record(second.id)?.state == .exited(code: 1), "exit code recorded")
        await settle()
        await snapshot("drawer-exited", drawer.view)

        // Find in scrollback.
        terminals.select(first.id, in: .drawer)
        drawer.reload()
        try await type(first.id, ["seq 40", "echo build finished: 0 errors"])
        if let pane = workspace.existingPane(first.id) {
            pane.showFind(useSelection: false)
            pane.findBarSet("repository")
        }
        await settle()
        await snapshot("drawer-find", drawer.view)
        workspace.existingPane(first.id)?.hideFind()

        // A terminal moved to the right panel.
        terminals.setPlacement(first.id, .panel)
        drawer.reload()
        panel.display(terminals, directory: project)
        await settle()
        await snapshot("panel", panel.view)
        check(panel.mountedIDs == [first.id], "panel shows the moved terminal")
        check(drawer.mountedIDs == [second.id], "drawer keeps the other terminal")
    }

    // MARK: Helpers

    private func type(_ id: String, _ commands: [String]) async throws {
        guard let pane = workspace.existingPane(id) else { throw DemoError("no pane for \(id)") }
        _ = await waitUntil(timeout: .seconds(3)) { pane.stream.status == .live }
        for command in commands {
            pane.stream.send(Array((command + "\r").utf8))
            try? await Task.sleep(for: .milliseconds(60))
        }
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func settle() async {
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            panelWindow.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    private func snapshot(_ name: String, _ view: NSView) async {
        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let appearance = NSAppearance(named: appearanceName) else { continue }
            view.window?.appearance = appearance
            view.layoutSubtreeIfNeeded()
            let panes = (drawer.mountedIDs + panel.mountedIDs).compactMap { workspace.existingPane($0) }
            for pane in panes {
                pane.applyAppearance()
                Render.frame(pane.terminalView)
            }
            try? await Task.sleep(for: .milliseconds(40))
            let url = DemoPaths.snapshots.appending(path: "terminal-\(name)-\(suffix).png")
            if Render.png(view, terminals: panes.map(\.terminalView), to: url) {
                written.append(url.path.replacingOccurrences(of: DemoPaths.root.path + "/", with: ""))
            } else {
                failures.append("could not render \(name)")
            }
        }
    }

    private func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }

    // MARK: TerminalWorkspaceDelegate

    func terminalWorkspace(_ workspace: TerminalWorkspace, sendToComposer text: String, from record: TerminalRecord) {}
}

struct DemoError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
