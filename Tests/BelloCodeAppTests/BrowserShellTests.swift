import AppKit
import BelloCore
import BrowserKit
import Engine
import Foundation
import Testing

@testable import BelloCodeApp

/// The browser seam in the real main window against MockOpenCode's simulated browser plugin.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct BrowserShellTests {
    /// Every key equivalent in the whole main menu (shell commands, standard items and the Browser menu) is unique.
    @Test func everyMainMenuShortcutIsUnique() {
        _ = NSApplication.shared
        let menu = MainMenu.make()
        func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) } }
        let items = all(menu).filter { !$0.keyEquivalent.isEmpty }
        func key(_ item: NSMenuItem) -> String {
            var mask = item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift])
            if item.keyEquivalent != item.keyEquivalent.lowercased() { mask.insert(.shift) }
            return "\(item.keyEquivalent.lowercased())-\(mask.rawValue)"
        }
        // The same command listed in two menus (e.g. Go and Thread) is one shortcut. The only shared key is ⌘K,
        // focus-aware between Command Palette and Clear Terminal (docs/features/navigation.md; ShellLogicTests).
        let focusAware: Set<Selector> = [ShellCommand.commandPalette.selector, ShellCommand.clearTerminal.selector]
        let duplicates = Dictionary(grouping: items, by: key).filter { _, items in
            let actions = Set(items.compactMap(\.action))
            return actions.count > 1 && actions != focusAware
        }
        #expect(duplicates.isEmpty, "duplicate shortcuts: \(duplicates.mapValues { $0.map(\.title) })")
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
        // The browser's own swap reloads nothing: the same tab, web view and document.
        let tab = try #require(set.tabs.first { $0.id == tabID })
        let webView = tab.webView
        let generation = tab.generation
        browser.display(browser.context)
        #expect(browser.pane?.set === set && set.selectedTabID == tabID)
        #expect(tab.webView === webView && tab.generation == generation && !tab.isLoading)

        // The pane commands are wired to the Browser menu router.
        #expect(browser.canPerform(.newTab))
        browser.perform(.newTab)
        #expect(set.tabs.count == 2)
        browser.perform(.closeTab)
        #expect(set.tabs.count == 1)
        #expect(browser.canPerform(.reopenClosedTab))
    }
}
