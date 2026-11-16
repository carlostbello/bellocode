import AppKit

/// Builds the main menu in code. App commands come from `ShellCommand` and use a nil target, so they travel the
/// responder chain (text views first, then the window controller) and are validated there. Standard items use the
/// AppKit selectors so text editing, Undo, Find and window commands keep their native behaviour.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let appName = ProcessInfo.processInfo.processName
        let mainMenu = NSMenu()

        mainMenu.addItem(submenu: applicationMenu(appName: appName))
        mainMenu.addItem(submenu: fileMenu())
        mainMenu.addItem(submenu: editMenu())
        mainMenu.addItem(submenu: viewMenu())
        mainMenu.addItem(submenu: threadMenu())

        let windowMenu = windowMenu()
        mainMenu.addItem(submenu: windowMenu)
        NSApp.windowsMenu = windowMenu

        let helpMenu = helpMenu(appName: appName)
        mainMenu.addItem(submenu: helpMenu)
        NSApp.helpMenu = helpMenu

        return mainMenu
    }

    private static func applicationMenu(appName: String) -> NSMenu {
        let menu = NSMenu(title: appName)
        menu.addItem(title: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), key: "")
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        menu.addItem(submenu: services, title: "Services")
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(title: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), key: "h")
        menu.addItem(
            title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h",
            modifiers: [.command, .option])
        menu.addItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), key: "")
        menu.addItem(.separator())
        menu.addItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), key: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.add(.newThread)
        menu.add(.addProject)
        menu.addItem(.separator())
        menu.add(.togglePinProject)
        menu.add(.removeProject)
        menu.addItem(.separator())
        menu.add(.revealInFinder)
        menu.add(.copyPath)
        menu.addItem(.separator())
        menu.addItem(title: "Close", action: #selector(NSWindow.performClose(_:)), key: "w")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(title: "Undo", action: Selector(("undo:")), key: "z")
        menu.addItem(title: "Redo", action: Selector(("redo:")), key: "z", modifiers: [.command, .shift])
        menu.addItem(.separator())
        menu.addItem(title: "Cut", action: #selector(NSText.cut(_:)), key: "x")
        menu.addItem(title: "Copy", action: #selector(NSText.copy(_:)), key: "c")
        menu.addItem(title: "Paste", action: #selector(NSText.paste(_:)), key: "v")
        menu.addItem(
            title: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), key: "v",
            modifiers: [.command, .option, .shift])
        menu.addItem(title: "Delete", action: #selector(NSText.delete(_:)), key: "")
        menu.addItem(title: "Select All", action: #selector(NSText.selectAll(_:)), key: "a")
        menu.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(findItem("Find…", key: "f", action: .showFindInterface))
        find.addItem(findItem("Find Next", key: "g", action: .nextMatch))
        find.addItem(findItem("Find Previous", key: "g", modifiers: [.command, .shift], action: .previousMatch))
        find.addItem(findItem("Use Selection for Find", key: "e", action: .setSearchString))
        menu.addItem(submenu: find, title: "Find")
        // AppKit appends AutoFill, Writing Tools, Start Dictation and Emoji & Symbols to a menu titled "Edit".
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(
            title: "Show Toolbar", action: #selector(NSWindow.toggleToolbarShown(_:)), key: "t", modifiers: [.command, .option])
        menu.addItem(title: "Customize Toolbar…", action: #selector(NSWindow.runToolbarCustomizationPalette(_:)), key: "")
        menu.addItem(.separator())
        // AppKit retitles these to Show/Hide Sidebar and Show/Hide Inspector as the state changes.
        menu.addItem(
            title: "Show Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), key: "s",
            modifiers: [.command, .control])
        menu.addItem(
            title: "Show Inspector", action: #selector(NSSplitViewController.toggleInspector(_:)), key: "i",
            modifiers: [.command, .option])
        menu.add(.toggleTerminal)
        menu.addItem(.separator())
        menu.add(.focusComposer)
        menu.add(.focusNextRegion)
        menu.add(.focusPreviousRegion)
        menu.addItem(.separator())
        menu.addItem(
            title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control])
        return menu
    }

    private static func threadMenu() -> NSMenu {
        let menu = NSMenu(title: "Thread")
        menu.add(.sendMessage)
        menu.add(.stopRun)
        menu.addItem(.separator())
        menu.add(.renameThread)
        menu.add(.markUnread)
        menu.add(.archiveThread)
        menu.add(.deleteThread)
        menu.addItem(.separator())
        menu.add(.nextNeedsAttention)
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m")
        menu.addItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), key: "")
        menu.addItem(.separator())
        menu.addItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), key: "")
        return menu
    }

    private static func helpMenu(appName: String) -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(title: "\(appName) Help", action: #selector(NSApplication.showHelp(_:)), key: "?")
        return menu
    }

    private static func findItem(
        _ title: String, key: String, modifiers: NSEvent.ModifierFlags = .command, action: NSTextFinder.Action
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = action.rawValue
        return item
    }
}

@MainActor
private extension NSMenu {
    @discardableResult
    func addItem(title: String, action: Selector?, key: String, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        addItem(item)
        return item
    }

    func add(_ command: ShellCommand) {
        let shortcut = command.shortcut
        addItem(title: command.title, action: command.selector, key: shortcut.key, modifiers: shortcut.modifiers)
    }

    func addItem(submenu: NSMenu, title: String? = nil) {
        let item = NSMenuItem(title: title ?? submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
