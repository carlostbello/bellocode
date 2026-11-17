import AppKit
import DesignSystem
import Engine
import OpenCodeKit
import SwiftTerm

/// One terminal: the emulator view fed from its PTY stream, plus a find bar, a status line for exited/ended
/// terminals (with Restart), and an observer bar when another client controls the PTY.
///
/// Ownership: created and cached by `TerminalWorkspace` (bounded), so switching threads keeps the emulator and its
/// scrollback; `attach()`/`detach()` connect and drop the socket (the PTY keeps running). The controller is the view's
/// `TerminalViewDelegate`; it owns the stream and tears both down in `discard()`.
@MainActor
public final class TerminalPaneController: NSViewController, TerminalViewDelegate {
    public let terminalID: String
    public let terminals: ThreadTerminals
    public let terminalView: TerminalPaneView
    /// The PTY attachment feeding this emulator (keystrokes go out through it).
    public let stream: TerminalStream
    private unowned let workspace: TerminalWorkspace
    let findBar = TerminalFindBar()
    let statusPill = TerminalStatusPill()
    let endedBar = TerminalEndedBar()
    let observerBar = TerminalEndedBar()
    private let prompt = SemanticPromptTracker()
    private var oscObservation: TerminalOscObservation?
    private var observation: TerminalObservation?
    private var noticeTask: Task<Void, Never>?
    private var appliedTheme: TerminalTheme?
    /// Paste confirmation is shown at most once at a time.
    private var isConfirmingPaste = false

    init(record: TerminalRecord, terminals: ThreadTerminals, workspace: TerminalWorkspace, service: TerminalService) {
        terminalID = record.id
        self.terminals = terminals
        self.workspace = workspace
        let preferences = workspace.preferences
        var options = TerminalOptions(cols: 80, rows: 24, scrollback: preferences.scrollback)
        // OSC payloads are untrusted; one OSC is capped at 1 MiB instead of SwiftTerm's 65 MiB default.
        options.maximumOscBytes = 1 << 20
        terminalView = TerminalPaneView(frame: NSRect(x: 0, y: 0, width: 640, height: 320), font: preferences.font, options: options)
        stream = service.makeStream(record.id, in: terminals, sink: TerminalFeedSink(sender: terminalView.feedSender))
        super.init(nibName: nil, bundle: nil)
        terminalView.pane = self
        terminalView.terminalDelegate = self
        terminalView.optionAsMetaKey = preferences.optionAsMeta
        terminalView.linkReporting = .implicit
        terminalView.linkHighlightMode = .hoverWithModifier
        terminalView.setAccessibilityLabel("Terminal: \(record.displayTitle)")
        let tracker = prompt
        oscObservation = terminalView.observeOscEvents { event in tracker.observe(event) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        observation?.cancel()
        noticeTask?.cancel()
    }

    public var record: TerminalRecord? { terminals.record(terminalID) }
    public var status: TerminalStreamStatus { stream.status }

    // MARK: View

    public override func loadView() {
        let container = TerminalPaneContainer()
        container.terminalView = terminalView
        // Bars above and below the emulator; hidden ones take no space.
        // The emulator sits inset from the pane's edges, on the pane's background (drawn by the container).
        let terminalHost = NSView()
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: terminalHost.topAnchor, constant: 4),
            terminalView.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor, constant: 8),
            terminalView.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
        ])
        terminalHost.setContentHuggingPriority(.defaultLow, for: .vertical)
        terminalHost.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let column = NSStackView(views: [findBar, terminalHost, endedBar, observerBar])
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .width
        column.detachesHiddenViews = true
        column.setHuggingPriority(.defaultLow, for: .vertical)
        terminalView.setContentHuggingPriority(.defaultLow, for: .vertical)
        terminalView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        for subview in [column, statusPill] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        findBar.isHidden = true
        statusPill.isHidden = true
        endedBar.isHidden = true
        observerBar.isHidden = true
        findBar.delegate = self
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: container.topAnchor),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusPill.topAnchor.constraint(equalTo: terminalView.topAnchor, constant: 6),
            statusPill.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
        ])
        endedBar.onPrimary = { [weak self] in self?.restart() }
        endedBar.onSecondary = { [weak self] in self?.closeTerminal() }
        observerBar.onPrimary = { [weak self] in self?.stream.takeControl() }
        view = container
        applyAppearance()
        observation = TerminalObservation { [weak self] in self?.render() }
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        applyAppearance()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        if view.effectiveAppearance.name != appliedAppearanceName { applyAppearance() }
    }

    private var appliedAppearanceName: NSAppearance.Name?

    func applyAppearance() {
        let appearance = view.effectiveAppearance
        appliedAppearanceName = appearance.name
        let theme = TerminalTheme.current(for: appearance)
        theme.apply(to: terminalView, appearance: appearance)
        appliedTheme = theme
        (view as? TerminalPaneContainer)?.backgroundColor = terminalView.nativeBackgroundColor
    }

    /// Applies changed preferences (font, scrollback, Option as Meta).
    func apply(_ preferences: TerminalPreferences) {
        if terminalView.font != preferences.font { terminalView.font = preferences.font }
        terminalView.changeScrollback(preferences.scrollback)
        terminalView.optionAsMetaKey = preferences.optionAsMeta
    }

    private func render() {
        let status = stream.status
        let record = terminals.record(terminalID)
        if let record {
            terminalView.setAccessibilityLabel("Terminal: \(record.displayTitle)")
            if let label = record.state.label {
                endedBar.show(
                    text: label.prefix(1).uppercased() + label.dropFirst(), symbol: "stop.circle",
                    primary: "Restart", secondary: "Close")
            } else {
                endedBar.isHidden = true
            }
        }
        switch status {
        case .reconnecting(let attempt):
            statusPill.show(attempt > 1 ? "Reconnecting (try \(attempt))…" : "Reconnecting…", symbol: "arrow.triangle.2.circlepath")
        case .connecting where terminals.record(terminalID)?.state.isRunning == true:
            statusPill.show("Connecting…", symbol: "arrow.triangle.2.circlepath")
        default:
            if noticeTask == nil { statusPill.isHidden = true }
        }
        if status == .observing {
            observerBar.show(
                text: "Read-only: another client controls this terminal", symbol: "eye", primary: "Take Control", secondary: nil)
        } else {
            observerBar.isHidden = true
        }
    }

    // MARK: Attach

    /// Connects the socket (the view's current grid is sent first).
    public func attach() {
        guard terminals.record(terminalID)?.state.isRunning == true else { return }
        sendSizeIfVisible()
        stream.activate()
    }

    /// Drops the socket; the PTY keeps running and the emulator keeps its content for a later `attach()`.
    public func detach() { stream.deactivate() }

    /// Detaches and releases the emulator (evicted from the cache or the terminal is gone).
    func discard() {
        stream.deactivate()
        observation?.cancel()
        oscObservation = nil
        terminalView.terminalDelegate = nil
        view.removeFromSuperview()
    }

    func sendSizeIfVisible() {
        guard terminalView.window != nil, !terminalView.isHiddenOrHasHiddenAncestor else { return }
        let dims = terminalView.terminalDimensions
        guard dims.cols >= 2, dims.rows >= 1 else { return }
        stream.resize(to: PTYSize(cols: dims.cols, rows: dims.rows))
    }

    /// The emulator joined a window or became visible: its grid is now real, so tell the PTY.
    func terminalViewDidChangeVisibility() { sendSizeIfVisible() }

    // MARK: Commands

    public func focus() {
        view.window?.makeFirstResponder(terminalView)
    }

    public func clear() {
        // Clears the local screen and scrollback, then asks the shell to redraw its prompt (Ctrl-L).
        terminalView.feedSender.feed(text: "\u{1B}[H\u{1B}[2J\u{1B}[3J")
        if stream.status == .live { stream.send([0x0C]) }
    }

    public var selectedText: String? {
        let text = terminalView.getSelection() ?? ""
        return text.isEmpty ? nil : text
    }

    public func sendSelectionToComposer() {
        guard let text = selectedText, let record else { return NSSound.beep() }
        workspace.delegate?.terminalWorkspace(workspace, sendToComposer: text, from: record)
    }

    func restart() {
        let dims = terminalView.terminalDimensions
        let size = PTYSize(cols: max(dims.cols, 2), rows: max(dims.rows, 1))
        Task { await workspace.restart(terminalID, in: terminals, size: size) }
    }

    func closeTerminal() {
        Task { await workspace.close(terminalID, in: terminals) }
    }

    // MARK: Paste policy

    /// Confirm only a multi-line paste that a shell prompt would run line by line: bracketed paste off (zsh and
    /// bash 5.1+ turn it on at their prompt, which makes the paste safe) and the shell at its prompt (OSC 133) or,
    /// without OSC 133, a shell in the foreground.
    func shouldConfirmPaste(_ text: String) -> Bool {
        guard workspace.preferences.confirmsMultilinePaste, stream.status == .live else { return false }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.count > 1, !(lines.count == 2 && lines[1].isEmpty) else { return false }
        guard !terminalView.bracketedPasteMode else { return false }
        if let atPrompt = prompt.atPrompt { return atPrompt }
        let foreground = record?.foregroundProcess.map { ($0 as NSString).lastPathComponent }
        return foreground.map(interactiveShells.contains) ?? true
    }

    func confirmPaste(_ text: String, completion: @escaping @MainActor (Bool) -> Void) {
        guard !isConfirmingPaste, let window = view.window else { return completion(false) }
        isConfirmingPaste = true
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        let alert = NSAlert()
        alert.messageText = "Paste \(lines) lines into the shell?"
        alert.informativeText = "Each line runs as a command as soon as it is pasted."
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.isConfirmingPaste = false
                if alert.suppressionButton?.state == .on, let workspace = self?.workspace {
                    workspace.preferences.confirmsMultilinePaste = false
                    workspace.delegate?.terminalWorkspace(workspace, didChange: workspace.preferences)
                }
                completion(response == .alertFirstButtonReturn)
            }
        }
    }

    // MARK: Find

    public func showFind(useSelection: Bool) {
        if useSelection, let selection = selectedText { findBar.searchText = selection }
        findBar.isHidden = false
        findBar.focus()
        updateFindCount()
    }

    public func hideFind() {
        findBar.isHidden = true
        terminalView.clearSearch()
        focus()
    }

    public var isFindVisible: Bool { !findBar.isHidden }

    /// Sets the search text as if typed (demo and tests).
    func findBarSet(_ text: String) {
        findBar.searchText = text
        findBarDidChange(findBar)
    }

    func findAgain(forward: Bool) {
        let term = findBar.searchText
        guard !term.isEmpty else { return showFind(useSelection: false) }
        let found = forward
            ? terminalView.findNext(term, options: findBar.options)
            : terminalView.findPrevious(term, options: findBar.options)
        if !found { NSSound.beep() }
        updateFindCount()
    }

    private func updateFindCount() {
        let term = findBar.searchText
        guard !term.isEmpty else { return findBar.setCount(nil) }
        let summary = terminalView.searchMatchSummary(term, options: findBar.options)
        // SwiftTerm's index is 1-based, 0 when no match is current.
        findBar.setCount((summary.index, summary.total))
    }

    // MARK: Notices

    private func notice(_ text: String, symbol: String) {
        statusPill.show(text, symbol: symbol)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.noticeTask = nil
            self?.render()
        }
    }

    // MARK: TerminalViewDelegate

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        sendSizeIfVisible()
    }

    public func setTerminalTitle(source: TerminalView, title: String) {}

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        let path = URL(string: directory).flatMap { $0.isFileURL ? $0.path : nil } ?? directory
        terminals.updateDirectory(terminalID, path)
    }

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        stream.send(data)
    }

    public func scrolled(source: TerminalView, position: Double) {}

    public func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
        let link = TerminalLink(text: request.link, isExplicit: request.isExplicit) { request.openDefault() }
        if let delegate = workspace.delegate {
            delegate.terminalWorkspace(workspace, open: link)
        } else {
            link.openInDefaultBrowser()
        }
    }

    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}

    public func bell(source: TerminalView) {}

    public func clipboardCopy(source: TerminalView, content: Data) {
        guard workspace.preferences.allowsClipboardWrites else {
            notice("Blocked a clipboard write from the terminal", symbol: "hand.raised")
            return
        }
        guard content.count <= 1 << 20, let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice("The terminal copied to the clipboard", symbol: "doc.on.clipboard")
    }

    public func clipboardRead(source: TerminalView) -> Data? { nil }

    public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

extension TerminalPaneController: TerminalFindBarDelegate {
    func findBarDidChange(_ bar: TerminalFindBar) {
        let term = bar.searchText
        if term.isEmpty {
            terminalView.clearSearch()
        } else if !terminalView.findNext(term, options: bar.options) {
            _ = terminalView.findPrevious(term, options: bar.options)
        }
        updateFindCount()
    }

    func findBar(_ bar: TerminalFindBar, next forward: Bool) { findAgain(forward: forward) }

    func findBarDidClose(_ bar: TerminalFindBar) { hideFind() }
}

/// A link the user activated in a terminal (OSC 8 or detected). `openInDefaultBrowser` checks the untrusted target
/// (SwiftTerm blocks unsafe local files and confirms custom schemes) before opening it.
public struct TerminalLink {
    public let text: String
    public let isExplicit: Bool
    public let openInDefaultBrowser: @MainActor () -> Void
}

/// The bar under a terminal that has ended ("Exited (1)  [Restart] [Close]") or is read-only ("[Take Control]").
@MainActor
final class TerminalEndedBar: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let secondary = NSButton(title: "", target: nil, action: nil)
    var onPrimary: (() -> Void)?
    var onSecondary: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        for button in [primary, secondary] {
            button.bezelStyle = .push
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.target = self
        }
        primary.action = #selector(primaryPressed)
        secondary.action = #selector(secondaryPressed)
        primary.keyEquivalent = ""
        let stack = NSStackView(views: [icon, label, NSView(), secondary, primary])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(stack)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor), separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: separator.bottomAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    func show(text: String, symbol: String, primary primaryTitle: String, secondary secondaryTitle: String?) {
        label.stringValue = text
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        icon.contentTintColor = .secondaryLabelColor
        primary.title = primaryTitle
        secondary.title = secondaryTitle ?? ""
        secondary.isHidden = secondaryTitle == nil
        setAccessibilityElement(false)
        label.setAccessibilityLabel(text)
        isHidden = false
    }

    @objc private func primaryPressed() { onPrimary?() }
    @objc private func secondaryPressed() { onSecondary?() }
}
