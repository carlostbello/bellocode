import AppKit
import SwiftTerm

/// SwiftTerm's plain `TerminalView` (never `LocalProcessTerminalView`, which writes OSC 52 to the general pasteboard
/// on its own) with BelloCode's key, paste, find and context-menu policy. Its `TerminalViewDelegate` is the pane
/// controller, which feeds it from the PTY socket.
///
/// Keys: while this view has focus it keeps every key without ⌘ (control sequences, function keys such as F6,
/// Option-as-Meta), so app shortcuts cannot shadow them; only `reservedShortcuts` (⌃` for the drawer) and ⌘
/// shortcuts reach the menu. SwiftTerm's `performKeyEquivalent` is not open, so `TerminalPaneContainer` (the
/// emulator's superview, which AppKit asks first) applies this policy.
@MainActor
public final class TerminalPaneView: TerminalView {
    /// Shortcuts without ⌘ that the app keeps even while a terminal has focus.
    public static var reservedShortcuts: [(key: String, modifiers: NSEvent.ModifierFlags)] = [("`", .control)]

    weak var pane: TerminalPaneController?

    /// Whether a key equivalent belongs to the program in the terminal: anything without ⌘ except reserved app
    /// shortcuts (control combinations, function keys such as F6, Option-as-Meta), and nothing while composing.
    func claimsKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let window, window.firstResponder === self else { return false }
        return !event.modifierFlags.contains(.command) && !Self.isReserved(event) && !hasMarkedText()
    }

    static func isReserved(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        return reservedShortcuts.contains { $0.key == key && $0.modifiers == modifiers }
    }

    // MARK: Paste

    public override func paste(_ sender: Any) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        guard let pane, pane.shouldConfirmPaste(text) else {
            super.paste(sender)
            return
        }
        pane.confirmPaste(text) { [weak self] confirmed in
            if confirmed { self?.insertPaste(text) }
        }
    }

    /// Pastes `text` as the program expects it (wrapped in bracketed-paste markers when the program enabled them).
    func insertPaste(_ text: String) {
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Whether the program enabled bracketed paste (DECSET 2004).
    var bracketedPasteMode: Bool { terminalInputStateSnapshot()?.bracketedPasteMode ?? false }

    // MARK: Find

    public override func performTextFinderAction(_ sender: Any?) {
        guard let item = sender as? any NSValidatedUserInterfaceItem, let action = NSTextFinder.Action(rawValue: item.tag) else { return }
        switch action {
        case .showFindInterface: pane?.showFind(useSelection: false)
        case .setSearchString: pane?.showFind(useSelection: true)
        case .nextMatch: pane?.findAgain(forward: true)
        case .previousMatch: pane?.findAgain(forward: false)
        case .hideFindInterface: pane?.hideFind()
        default: break
        }
    }

    public override func performFindPanelAction(_ sender: Any?) {
        pane?.showFind(useSelection: false)
    }

    // MARK: Actions (responder chain)

    @objc public func sendTerminalSelectionToComposer(_ sender: Any?) { pane?.sendSelectionToComposer() }
    @objc public func clearTerminal(_ sender: Any?) { pane?.clear() }

    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(sendTerminalSelectionToComposer(_:)): return !(getSelection() ?? "").isEmpty
        case #selector(clearTerminal(_:)): return true
        case #selector(performTextFinderAction(_:)), #selector(performFindPanelAction(_:)): return true
        default: return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: Context menu

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let hasSelection = !(getSelection() ?? "").isEmpty
        let copy = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copy.isEnabled = hasSelection
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let send = menu.addItem(withTitle: "Send Selection to Composer", action: #selector(sendTerminalSelectionToComposer(_:)), keyEquivalent: "")
        send.isEnabled = hasSelection
        let find = menu.addItem(withTitle: "Find…", action: #selector(performTextFinderAction(_:)), keyEquivalent: "")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        menu.addItem(withTitle: "Clear", action: #selector(clearTerminal(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pane?.terminalViewDidChangeVisibility()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        pane?.terminalViewDidChangeVisibility()
    }

    // MARK: Accessibility

    public override func accessibilityRoleDescription() -> String? { "terminal" }
}

/// The emulator's superview. AppKit offers key equivalents down the view hierarchy before the menu, so this view
/// hands keys the terminal claims straight to it (see `TerminalPaneView.claimsKeyEquivalent`).
@MainActor
final class TerminalPaneContainer: NSView {
    weak var terminalView: TerminalPaneView?
    var backgroundColor: NSColor = .textBackgroundColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()  // views do not clip to bounds (macOS 14+)
    }

    /// After any layout the grid may have changed; the stream debounces and sends only a real change.
    override func layout() {
        super.layout()
        terminalView?.pane?.sendSizeIfVisible()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let terminalView, terminalView.claimsKeyEquivalent(event) {
            terminalView.keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
