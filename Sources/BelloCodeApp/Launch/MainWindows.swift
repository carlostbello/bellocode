import AppKit
import BelloCore
import Engine

/// The app's main windows (⇧⌘N opens another): each has its own workspace (selection, history, layout, undo) and
/// they share one Engine. The first window's state lives under the M1 key; others under their own, listed in
/// `openWindowsKey` so they reopen after relaunch, honouring the system "Close windows when quitting" setting:
/// when it is on, only the first window reopens (it still shows the last thread, drafts and layout; see
/// docs/features/navigation.md).
@MainActor
final class MainWindows {
    static let primaryID = "main"
    static let openWindowsKey = "BelloCode.OpenWindows"

    private let defaults: UserDefaults
    private let make: @MainActor (String) -> MainWindowController
    private(set) var controllers: [String: MainWindowController] = [:]
    /// Window IDs in the order they were opened.
    private(set) var order: [String] = []
    /// One window-close observer per open window, removed when it closes (NV08).
    private var observers: [String: any NSObjectProtocol] = [:]
    var closeObserverCount: Int { observers.count }
    private var isTerminating = false

    init(defaults: UserDefaults, make: @escaping @MainActor (String) -> MainWindowController) {
        self.defaults = defaults
        self.make = make
    }

    isolated deinit {
        for observer in observers.values { NotificationCenter.default.removeObserver(observer) }
    }

    /// The system "Close windows when quitting" setting is off (so windows should come back).
    static func restoresWindows(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "NSQuitAlwaysKeepsWindows")
    }

    static func stateKey(for id: String) -> String {
        id == primaryID ? "BelloCode.ShellState" : "BelloCode.ShellState.\(id)"
    }

    /// Opens the first window, and the other windows open at quit when the system setting allows.
    func restore(restoresWindows: Bool = MainWindows.restoresWindows()) {
        open(id: Self.primaryID)
        let saved = defaults.stringArray(forKey: Self.openWindowsKey) ?? []
        if restoresWindows {
            for id in saved where id != Self.primaryID { open(id: id) }
        } else {
            for id in saved where id != Self.primaryID { defaults.removeObject(forKey: Self.stateKey(for: id)) }
            defaults.set([String](), forKey: Self.openWindowsKey)
        }
    }

    /// Shows the first window (Dock click with no window open), recreating it if it was closed.
    func showPrimary() {
        if let controller = controllers[Self.primaryID] {
            controller.showWindow(nil)
        } else {
            open(id: Self.primaryID)
        }
    }

    /// Opens a new window (⇧⌘N), optionally showing `selection`; `background` orders it behind the current one.
    @discardableResult
    func openNew(selection: ShellSelection? = nil, background: Bool = false, reveal: PendingReveal? = nil) -> MainWindowController {
        let id = UUID().uuidString
        let key = (NSApp.keyWindow ?? NSApp.mainWindow).flatMap { window in controllers.values.first { $0.window === window } }
        // Start from the current window's selection (as a browser's new window starts blank, a new workspace window
        // starts on the same project).
        let start = selection ?? key?.workspace.selection
        let controller = open(id: id, show: false)
        if let start { controller.workspace.select(start, recordsHistory: false) }
        if let reveal { controller.workspace.pendingReveal = reveal }
        if let window = controller.window, let keyFrame = key?.window?.frame {
            window.setFrame(keyFrame.offsetBy(dx: 24, dy: -24), display: false)
        }
        if background, let current = key?.window {
            controller.window?.order(.below, relativeTo: current.windowNumber)
        } else {
            controller.showWindow(nil)
        }
        persistList()
        return controller
    }

    @discardableResult
    private func open(id: String, show: Bool = true) -> MainWindowController {
        if let existing = controllers[id] {
            if show { existing.showWindow(nil) }
            return existing
        }
        let controller = make(id)
        controllers[id] = controller
        order.append(id)
        if let window = controller.window {
            let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.closed(id) }
            }
            observers[id] = observer
        }
        if show { controller.showWindow(nil) }
        return controller
    }

    /// A window closed: its workspace saves and closes. A secondary window is forgotten (closing it is deliberate);
    /// the first window keeps its state for the next time it opens.
    private func closed(_ id: String) {
        if let observer = observers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(observer) }
        guard !isTerminating, let controller = controllers.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        controller.workspace.close()
        if id != Self.primaryID { defaults.removeObject(forKey: Self.stateKey(for: id)) }
        persistList()
    }

    private func persistList() {
        defaults.set(order.filter { $0 != Self.primaryID }, forKey: Self.openWindowsKey)
    }

    /// The window to act in: the key main window, else the first, else any.
    var current: MainWindowController? {
        if let key = NSApp.keyWindow ?? NSApp.mainWindow, let controller = controllers.values.first(where: { $0.window === key }) {
            return controller
        }
        return controllers[Self.primaryID] ?? order.first.flatMap { controllers[$0] }
    }

    var all: [MainWindowController] { order.compactMap { controllers[$0] } }

    /// Quitting: every workspace saves (secondary windows stay listed so they can reopen).
    func closeAllForTermination() {
        isTerminating = true
        persistList()
        for controller in all { controller.workspace.close() }
    }
}
