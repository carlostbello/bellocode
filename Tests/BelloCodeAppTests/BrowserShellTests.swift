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

    // MARK: NV05: typed browser shortcuts belong to a shown, focused browser

    @Test func focusScopedShortcutsAreTheOnesOtherViewsUse() {
        #expect(BrowserMenu.focusScoped == [.openLocation, .reload, .reloadFromOrigin, .zoomIn, .zoomOut, .actualSize, .pickElement, .nextTab, .previousTab])
        for command in BrowserMenu.focusScoped {
            #expect(!BrowserMenu.allowsShortcut(command, fromKeyboard: true, browserShown: false, focusInBrowser: false), "\(command) hidden")
            #expect(!BrowserMenu.allowsShortcut(command, fromKeyboard: true, browserShown: true, focusInBrowser: false), "\(command) shown, composer focused")
            #expect(BrowserMenu.allowsShortcut(command, fromKeyboard: true, browserShown: true, focusInBrowser: true))
            #expect(BrowserMenu.allowsShortcut(command, fromKeyboard: false, browserShown: false, focusInBrowser: false), "chosen in the menu")
        }
        #expect(BrowserMenu.allowsShortcut(.newTab, fromKeyboard: true, browserShown: false, focusInBrowser: false), "⌃⌘T stays global")
    }

    /// A key event as the keyboard makes it (characters from the current layout), not a hand-built one.
    static func typed(_ code: UInt16, _ flags: CGEventFlags) -> NSEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        event.flags = flags
        return NSEvent(cgEvent: event)!
    }

    /// The premise of the routing: a typed key equivalent whose item validates disabled is not consumed by the menu,
    /// so the focused view (composer, text field, terminal) gets the key.
    @Test func aDisabledItemLeavesItsTypedKeyToTheFocusedView() {
        _ = NSApplication.shared
        final class Target: NSObject, NSMenuItemValidation {
            var enabled = false
            var performed = 0
            @objc func act(_ sender: Any?) { performed += 1 }
            func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { enabled }
        }
        let target = Target()
        let menu = NSMenu(title: "Test")
        let item = NSMenuItem(title: "Reload Page", action: #selector(Target.act(_:)), keyEquivalent: "r")
        item.keyEquivalentModifierMask = [.command]
        item.target = target
        menu.addItem(item)
        #expect(!menu.performKeyEquivalent(with: Self.typed(15, .maskCommand)))
        #expect(target.performed == 0)
        target.enabled = true
        #expect(menu.performKeyEquivalent(with: Self.typed(15, .maskCommand)))
        #expect(target.performed == 1)
    }

    /// In the real window: with a page open but the Browser tab hidden (Changes shown, the composer focused), ⌘R and
    /// the other focus-scoped shortcuts validate disabled, so they reach the composer; shown and focused, they work.
    @Test func browserShortcutsSkipAHiddenBrowser() async throws {
        let shell = try await IntegratedShellTests.Shell.start()
        defer { Task { await shell.stop() } }
        let controller = shell.controller
        let threads = shell.threads
        let browser = try #require(controller.browser)
        #expect(await shell.driver.select(.thread(threads[0])))
        shell.driver.settle()
        let endpoint = try await shell.server.start()
        #expect(browser.open(endpoint.url))
        #expect(controller.isBrowserPanelShown)
        let webView = try #require(browser.pane?.set?.selectedTab?.webView)
        let menu = BrowserMenu.make()
        func item(_ command: BrowserPaneCommand) -> NSMenuItem? { menu.items.first { $0.representedObject as? String == command.rawValue } }
        let reload = try #require(item(.reload))
        let newTab = try #require(item(.newTab))
        let keyDown = Self.typed(15, .maskCommand)
        let router = BrowserMenuRouter.shared
        // Shown and focused: typed shortcuts go to the browser.
        controller.window?.makeFirstResponder(webView)
        #expect(browser.focusIsInBrowser)
        #expect(router.validate(reload, surfaces: browser, event: keyDown))
        // Shown but the composer has focus: the composer keeps ⌘R.
        controller.focusComposer(nil)
        shell.driver.settle()
        #expect(!browser.focusIsInBrowser)
        #expect(!router.validate(reload, surfaces: browser, event: keyDown))
        // Hidden (Changes shown): never from the keyboard; still from the menu itself; ⌃⌘ shortcuts stay global.
        controller.rightPanel.select("changes")
        #expect(!controller.isBrowserPanelShown)
        #expect(!router.validate(reload, surfaces: browser, event: keyDown))
        #expect(router.validate(reload, surfaces: browser, event: nil), "chosen in the menu")
        #expect(router.validate(newTab, surfaces: browser, event: keyDown))
    }
}

