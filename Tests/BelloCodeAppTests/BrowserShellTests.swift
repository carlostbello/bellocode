import AppKit
import BelloCore
import BrowserKit
import Engine
import Foundation
import Testing

@testable import BelloCodeApp

/// The browser seam in the real main window against MockOpenCode's simulated browser plugin.
@MainActor @Suite(.serialized) struct BrowserShellTests {
    /// Every key equivalent in the whole main menu (shell commands, standard items and the Browser menu) is unique.
    @Test func everyMainMenuShortcutIsUnique() {
        _ = NSApplication.shared
        let menu = MainMenu.make()
        func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) } }
        let shortcuts = all(menu).filter { !$0.keyEquivalent.isEmpty }.map { item in
            var mask = item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift])
            if item.keyEquivalent != item.keyEquivalent.lowercased() { mask.insert(.shift) }
            return "\(item.keyEquivalent.lowercased())-\(mask.rawValue) (\(item.title))"
        }
        let keys = shortcuts.map { $0.components(separatedBy: " (").first ?? $0 }
        let duplicates = Dictionary(grouping: shortcuts, by: { $0.components(separatedBy: " (").first ?? $0 }).filter { $0.value.count > 1 }
        #expect(Set(keys).count == keys.count, "duplicate shortcuts: \(duplicates.values.flatMap { $0 })")
        #expect(Set(BrowserMenu.shortcuts).isDisjoint(with: ShellCommand.allCases.map(\.shortcut).filter { !$0.key.isEmpty }.map { "\($0.key)-\($0.modifiers.rawValue)" }))
        let titles = Set(all(menu).map(\.title))
        for title in ["Show Browser", "New Browser Tab", "Pick Element for Composer", "Let Agent Control Browser", "Open in Default Browser"] {
            #expect(titles.contains(title), "\(title) is in the menu")
        }
    }

    @Test func browserTabFollowsTheThreadAttachesAndKeepsTabsAcrossSwitches() async throws {
        let shell = try await IntegratedShellTests.Shell.start()
        defer { Task { await shell.stop() } }
        let controller = shell.controller
        let threads = shell.threads
        try #require(threads.count >= 2)
        let browser = try #require(controller.browser, "the Browser tab provides the window's browser")
        #expect(await shell.driver.select(.thread(threads[0])))
        shell.driver.settle()
        let endpoint = try await shell.server.start()
        #expect(browser.open(endpoint.url), "links open in the displayed thread's browser")
        #expect(controller.isBrowserPanelShown, "opening a link shows the Browser tab")
        let set = try #require(browser.pane?.set)
        #expect(set.sessionID == threads[0])
        let tabID = try #require(set.selectedTabID)
        let model = shell.engine.browser.model(for: threads[0])
        let attached = await waitUntil(timeout: .seconds(10)) { model.status == .attached }
        #expect(attached, "the thread's browser attaches to its session (\(model.status.label))")
        #expect(await shell.server.browserAttachment(for: threads[0].rawValue) != nil)

        // Another thread: its own (new) set; switching back shows the same set and tab without reloading.
        #expect(await shell.driver.select(.thread(threads[1])))
        shell.driver.settle()
        #expect(browser.pane?.set !== set)
        #expect(await shell.driver.select(.thread(threads[0])))
        shell.driver.settle()
        #expect(browser.pane?.set === set && browser.pane?.set?.selectedTabID == tabID)
        // The browser's own swap (no reload): well inside the 100 ms feedback budget.
        let start = ContinuousClock.now
        browser.display(browser.context)
        #expect(ContinuousClock.now - start < .milliseconds(100))

        // The pane commands are wired to the Browser menu router.
        #expect(browser.canPerform(.newTab))
        browser.perform(.newTab)
        #expect(set.tabs.count == 2)
        browser.perform(.closeTab)
        #expect(set.tabs.count == 1)
        #expect(browser.canPerform(.reopenClosedTab))
    }
}
