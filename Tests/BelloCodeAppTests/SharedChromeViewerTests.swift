import AppKit
import BelloCore
import Foundation
import Testing

@testable import BelloCodeApp
@testable import Engine

/// v1.0.1 NF17: every open Shared Chrome viewer follows who has control, and the menu's Take Over acts in the detached
/// window when that is where the person watches.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct SharedChromeViewerTests {
    static func service() throws -> SharedBrowserService {
        SharedBrowserService(
            store: try ProjectionStore(location: .inMemory), configuration: nil,
            defaults: UserDefaults(suiteName: "bellocode.tests.chrome-viewer.\(UUID().uuidString)")!)
    }

    static func control(_ service: SharedBrowserService, _ human: Set<String>) {
        service.showForSnapshots(phase: .ready, status: nil, bindings: [], activity: [:], humanControl: human, approved: [])
    }

    @Test func aConnectedViewerFollowsControlChangedElsewhere() throws {
        let service = try Self.service()
        Self.control(service, [])
        let detached = SharedChromePaneController(service: service, detached: true)
        var scripts: [String] = []
        detached.runScript = { scripts.append($0) }
        detached.loadViewIfNeeded()
        detached.viewerConnected(viewOnly: true)
        #expect(scripts.isEmpty, "connected in the right mode")
        // Take Over from the panel or the menu: this viewer turns interactive too.
        Self.control(service, ["*"])
        detached.follow()
        #expect(scripts == ["window.bellocodeSetViewOnly(false)"])
        detached.follow()
        #expect(scripts.count == 1, "applied once")
        // Give Back from the menu: back to view-only.
        Self.control(service, [])
        detached.follow()
        #expect(scripts.last == "window.bellocodeSetViewOnly(true)")
        // Control changed while it connected: corrected at once.
        let late = SharedChromePaneController(service: service, detached: false)
        var lateScripts: [String] = []
        late.runScript = { lateScripts.append($0) }
        late.loadViewIfNeeded()
        Self.control(service, ["*"])
        late.viewerConnected(viewOnly: true)
        #expect(lateScripts == ["window.bellocodeSetViewOnly(false)"])
    }

    @Test func menuTakeOverUsesTheOpenDetachedWindow() async throws {
        let shell = try await IntegratedShellTests.Shell.start()
        defer { Task { await shell.stop() } }
        let controller = shell.controller
        let surfaces = try #require(controller.sharedChrome)
        surfaces.openWindow()
        let detached = try #require(surfaces.windowPane, "the detached window is open")
        defer { detached.view.window?.close() }
        var scripts: [String] = []
        detached.runScript = { scripts.append($0) }
        let panelBefore = controller.rightPanel.selectedID
        SharedChromeMenuRouter.run(.takeOver, in: controller)
        #expect(controller.rightPanel.selectedID == panelBefore, "the panel is not forced open")
        #expect(await waitUntil(timeout: .seconds(5)) { scripts.contains("window.bellocodeFocus()") }, "the detached viewer took over")
    }
}
