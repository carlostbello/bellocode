import AppKit
import BelloCore
import Engine
import Foundation
import Testing

@testable import BelloCodeApp

/// The menu-bar item's menu (Settings ▸ Notifications).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct StatusItemTests {
    /// NF21: Scheduled Tasks… brings BelloCode forward before opening Settings, like the other entries (another app
    /// is frontmost whenever the menu-bar item is used).
    @Test func scheduledTasksActivatesTheAppFirst() async throws {
        let shell = try await IntegratedShellTests.Shell.start()
        defer { Task { await shell.stop() } }
        try #require(shell.engine.extras?.schedules != nil, "the integrated shell has scheduled tasks")
        let controller = StatusItemController(engine: shell.engine, settings: AppSettings(defaults: nil))
        var calls: [String] = []
        controller.activateApp = { calls.append("activate") }
        controller.onShowScheduledTasks = { calls.append("schedules") }
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        let item = try #require(menu.items.first { $0.title == "Scheduled Tasks…" })
        let target = try #require(item.target as? NSObject, "the item has its own target")
        let action = try #require(item.action)
        _ = target.perform(action, with: item)
        #expect(calls == ["activate", "schedules"])
    }
}
