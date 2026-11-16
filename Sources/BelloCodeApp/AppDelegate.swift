import AppKit

/// Owns application-level lifecycle: the main menu and the main window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        showMainWindow()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Agents keep running with no window open (docs/PLAN.md, section 8.3). Clicking the Dock icon reopens it.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func showMainWindow() {
        let controller = mainWindowController ?? MainWindowController()
        mainWindowController = controller
        controller.showWindow(nil)
    }
}
