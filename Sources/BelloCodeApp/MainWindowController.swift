import AppKit

/// The main window: a unified toolbar over a three-region split view. Its frame is saved and restored by AppKit.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private static let frameAutosaveName = "BelloCodeMainWindow"
    private static let toolbarIdentifier = "BelloCodeMainToolbar"

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "BelloCode"
        window.minSize = NSSize(width: 720, height: 420)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.contentViewController = MainSplitViewController()
        // Assigning a content view controller resizes the window to that controller's view; restore the default.
        window.setContentSize(NSSize(width: 1200, height: 780))
        window.center()
        // Must come after the content is set: restoring the saved frame wins over the default size and position.
        window.setFrameAutosaveName(Self.frameAutosaveName)

        super.init(window: window)

        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .inspectorTrackingSeparator, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        // Every identifier we use is a system item that AppKit builds itself.
        nil
    }
}
