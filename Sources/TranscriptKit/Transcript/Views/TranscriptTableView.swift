import AppKit
import QuartzCore
import Synchronization

/// Single-column, view-based table. Row selection is off: text selection is the controller's transcript-level model.
/// The table owns all mouse handling; rows are passive renderers configured from controller state, so selection,
/// expansion and inner scroll offsets survive row reuse. Edit and transcript commands arrive through the responder
/// chain.
public final class TranscriptTableView: NSTableView, NSMenuItemValidation {
    weak var controller: TranscriptController?

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        controller?.refreshVisibleRows()
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.controller?.refreshVisibleRows() } }
        return accepted
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) { controller?.mouseDown(event) }
    public override func mouseDragged(with event: NSEvent) { controller?.mouseDragged(event) }
    public override func mouseUp(with event: NSEvent) { controller?.mouseUp(event) }
    public override func mouseMoved(with event: NSEvent) { controller?.mouseMoved(event) }
    public override func mouseExited(with event: NSEvent) { controller?.mouseExited() }

    public override func menu(for event: NSEvent) -> NSMenu? { controller?.contextMenu(for: event) }

    public override func scrollWheel(with event: NSEvent) {
        if controller?.handleScrollWheel(event) == true { return }
        super.scrollWheel(with: event)
    }

    /// Force click: Look Up the word under the pointer.
    public override func quickLook(with event: NSEvent) {
        guard let controller else { return }
        _ = controller.contextMenu(for: event)
        controller.lookUp()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil))
    }

    public override func resetCursorRects() { addCursorRect(visibleRect, cursor: .iBeam) }

    // MARK: Keys

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Escape: dismiss find, then the selection; never stops the agent.
            if controller?.isFindBarVisible == true { controller?.closeFind(); return }
            if controller?.hasSelection == true { controller?.clearSelection(); return }
            super.keyDown(with: event)
            return
        }
        if controller?.keyDown(event) == true { return }
        // Tab and others: standard behaviour (key view loop), not row selection.
        if event.specialKey == .tab || event.specialKey == .backTab {
            if event.specialKey == .backTab { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
            return
        }
        interpretKeyEvents([event])
    }

    // MARK: Edit and transcript commands

    @objc public func copy(_ sender: Any?) { controller?.copySelection() }
    public override func selectAll(_ sender: Any?) { controller?.selectAll() }
    @objc public func copyTranscriptMessage(_ sender: Any?) { controller?.copyMessage() }
    @objc public func copyTranscriptMarkdown(_ sender: Any?) { controller?.copyAsMarkdown() }
    @objc public func copyTranscriptCode(_ sender: Any?) { controller?.copyCode() }
    @objc func openTranscriptLink(_ sender: Any?) { if let link = controller?.contextLink { controller?.open(link: link) } }
    @objc func copyTranscriptLink(_ sender: Any?) {
        guard let link = controller?.contextLink else { return }
        controller?.write(plain: link, markdown: nil)
    }
    @objc func lookUpTranscriptWord(_ sender: Any?) { controller?.lookUp() }
    @objc public func findInTranscript(_ sender: Any?) { controller?.showFind() }
    @objc public func findNextInTranscript(_ sender: Any?) { controller?.findNext() }
    @objc public func findPreviousInTranscript(_ sender: Any?) { controller?.findPrevious() }
    @objc public func useSelectionForTranscriptFind(_ sender: Any?) { controller?.useSelectionForFind() }
    @objc public func jumpToLatestOutput(_ sender: Any?) { controller?.jumpToLatest() }
    @objc public func showPreviousTurn(_ sender: Any?) { controller?.goToTurn(previous: true) }
    @objc public func showNextTurn(_ sender: Any?) { controller?.goToTurn(previous: false) }
    @objc public func showLastFailure(_ sender: Any?) { controller?.goToLastFailure() }

    /// The standard Find menu (NSTextFinder tags) also reaches the transcript.
    public override func performTextFinderAction(_ sender: Any?) {
        guard let tag = (sender as? any NSValidatedUserInterfaceItem)?.tag, let action = NSTextFinder.Action(rawValue: tag) else { return }
        switch action {
        case .showFindInterface: controller?.showFind()
        case .nextMatch: controller?.findNext()
        case .previousMatch: controller?.findPrevious()
        case .setSearchString: controller?.useSelectionForFind()
        case .hideFindInterface: controller?.closeFind()
        default: break
        }
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { validate(menuItem.action, tag: menuItem.tag) ?? true }

    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        validate(item.action, tag: item.tag) ?? super.validateUserInterfaceItem(item)
    }

    /// nil: not a transcript command.
    func validate(_ action: Selector?, tag: Int) -> Bool? {
        guard let controller, let action else { return nil }
        switch action {
        case #selector(copy(_:)): return controller.hasSelection
        case #selector(selectAll(_:)): return !controller.rows.isEmpty
        case #selector(copyTranscriptMessage(_:)), #selector(copyTranscriptMarkdown(_:)): return controller.commandRow != nil
        case #selector(copyTranscriptCode(_:)): return controller.commandCodeBlock != nil
        case #selector(openTranscriptLink(_:)), #selector(copyTranscriptLink(_:)): return controller.contextLink != nil
        case #selector(lookUpTranscriptWord(_:)): return controller.lookUpTerm != nil
        case #selector(findInTranscript(_:)): return !controller.rows.isEmpty
        case #selector(findNextInTranscript(_:)), #selector(findPreviousInTranscript(_:)):
            return !controller.findMatches.isEmpty || !controller.findBar.field.stringValue.isEmpty
        case #selector(useSelectionForTranscriptFind(_:)): return controller.hasSelection
        case #selector(jumpToLatestOutput(_:)): return !controller.rows.isEmpty
        case #selector(showPreviousTurn(_:)), #selector(showNextTurn(_:)): return controller.rows.contains { $0.role == .user }
        case #selector(showLastFailure(_:)): return controller.hasFailure
        case #selector(performTextFinderAction(_:)):
            switch NSTextFinder.Action(rawValue: tag) {
            case .showFindInterface: return !controller.rows.isEmpty
            case .nextMatch, .previousMatch: return !controller.findMatches.isEmpty
            case .setSearchString: return controller.hasSelection
            default: return false
            }
        default: return nil
        }
    }

    // MARK: Services

    public override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if returnType == nil, sendType == .string || sendType == nil, controller?.hasSelection == true { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    @objc public func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let text = controller?.selectedText(), !text.isEmpty else { return false }
        pasteboard.declareTypes([.string], owner: nil)
        return pasteboard.setString(text, forType: .string)
    }

    // MARK: Accessibility

    public override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        // AppKit asks on the main thread.
        let cell: TranscriptCellView? = MainActor.assumeIsolated {
            guard let window else { return nil }
            let local = convert(window.convertPoint(fromScreen: point), from: nil)
            let row = self.row(at: local)
            return row >= 0 ? view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptCellView : nil
        }
        return cell ?? super.accessibilityHitTest(point)
    }
}

/// Row view without selection drawing; never a hit-test target, so the table receives every mouse event.
final class TranscriptRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("TranscriptRow")
    /// Live row views, including AppKit's reuse queue and purgatory (cache report; a regression guard).
    nonisolated static let liveCount = Atomic<Int>(0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        Self.liveCount.add(1, ordering: .relaxed)
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { Self.liveCount.subtract(1, ordering: .relaxed) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override var isOpaque: Bool { false }
}

/// The first table row: "Loading earlier messages…" while history pages in, else top padding.
final class TranscriptEdgeView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("TranscriptEdge")
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(hasOlder: Bool, loading: Bool) {
        label.stringValue = loading ? "Loading earlier messages…" : hasOlder ? "Scroll up for earlier messages" : ""
        label.isHidden = !hasOlder
        setAccessibilityElement(hasOlder)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label.stringValue)
    }
}

/// Reusable cell for one row. Draws through a canvas subview that covers only the visible part of very tall rows, so
/// a 40,000-point row (a 100 KB code block) never gets a 40,000-point backing layer.
final class TranscriptCellView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("TranscriptCell")
    static let tallRowThreshold: CGFloat = 1_000

    weak var controller: TranscriptController?
    var rowID: RowID?
    var row: TranscriptRow?
    var layout: RowLayout?
    var drawState = RowLayout.DrawState(selectionColor: NSColor.selectedTextBackgroundColor.cgColor)
    private(set) var isHovered = false
    let canvas = TranscriptCanvasView()
    /// Live cell views, including AppKit's reuse queue (cache report).
    nonisolated static let liveCount = Atomic<Int>(0)

    override init(frame: NSRect) {
        super.init(frame: frame)
        Self.liveCount.add(1, ordering: .relaxed)
        identifier = Self.identifier
        canvas.owner = self
        addSubview(canvas)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { Self.liveCount.subtract(1, ordering: .relaxed) }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateCanvas(force: true)
    }

    func sameState(_ other: RowLayout.DrawState) -> Bool {
        drawState.selection == other.selection && drawState.copiedBlock == other.copiedBlock
            && drawState.finds.count == other.finds.count
            && zip(drawState.finds, other.finds).allSatisfy { $0.block == $1.block && $0.range == $1.range && $0.current == $1.current }
            && drawState.scrollOffsets == other.scrollOffsets && drawState.hover?.block == other.hover?.block
            && drawState.hover?.action == other.hover?.action && drawState.selectionColor == other.selectionColor
    }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        invalidate()
    }

    func invalidate(_ rect: CGRect? = nil) {
        guard let rect else { canvas.needsDisplay = true; return }
        let local = CGRect(x: 0, y: rect.minY - canvas.frame.minY, width: canvas.bounds.width, height: rect.height)
        canvas.setNeedsDisplay(local.intersection(canvas.bounds))
    }

    /// Space left and right of the text column the canvas also covers (hover timestamps, selection gap fill).
    static let gutter: CGFloat = 96

    /// The canvas spans the text column plus gutters, so a width change that only re-centres the column moves the
    /// canvas (its layer contents move with it) instead of redrawing the row.
    func columnFrame() -> (x: CGFloat, width: CGFloat) {
        let contentWidth = layout?.width ?? bounds.width
        let columnX = TranscriptGeometry.columnX(forTableWidth: bounds.width, contentWidth: contentWidth)
        return (columnX - Self.gutter, contentWidth + 2 * Self.gutter)
    }

    /// Keeps the canvas covering the visible part (plus margin) of tall rows, with hysteresis.
    func updateCanvas(force: Bool = false) {
        let bounds = self.bounds
        let column = columnFrame()
        let target: CGRect
        if bounds.height <= Self.tallRowThreshold {
            target = CGRect(x: column.x, y: 0, width: column.width, height: bounds.height)
        } else {
            let visible = visibleRect
            if !force, !canvas.frame.isEmpty, !visible.isEmpty, canvas.frame.minX == column.x, canvas.frame.width == column.width,
                canvas.frame.minY <= max(0, visible.minY - 200) + 1, canvas.frame.maxY >= min(bounds.height, visible.maxY + 200) - 1
            {
                return
            }
            let margin: CGFloat = 900
            let center = visible.isEmpty ? CGRect(x: 0, y: 0, width: bounds.width, height: 1) : visible
            let top = max(0, floor(center.minY - margin))
            let bottom = min(bounds.height, ceil(center.maxY + margin))
            target = CGRect(x: column.x, y: top, width: column.width, height: max(1, bottom - top))
        }
        if canvas.frame.size != target.size || canvas.frame.minY != target.minY {
            canvas.frame = target
            canvas.needsDisplay = true
        } else if canvas.frame.origin != target.origin {
            canvas.setFrameOrigin(target.origin)  // horizontal re-centring: no redraw
        }
    }

    /// Accessibility attributes are computed when an accessibility client asks, not on every configure: the value is
    /// the row's whole visible text (a 100 KB code block for the largest row) and the custom actions allocate objects
    /// per hotspot. Configure only announces that the element changed, and only to a running client.
    func updateAccessibility() {
        guard controller?.isVoiceOverRunning == true else { return }
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func accessibilityLabel() -> String? {
        guard let controller, let row else { return nil }
        return controller.accessibilityLabel(row)
    }

    override func accessibilityValue() -> Any? {
        guard let controller, let row, let index = controller.rowIndex[row.id] else { return nil }
        return controller.accessibilityValue(index)
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let controller, let row, let index = controller.rowIndex[row.id] else { return nil }
        return controller.accessibilityActions(index, layout: layout)
    }

    override func accessibilityRoleDescription() -> String? {
        guard let row else { return nil }
        return row.role == .user ? "prompt" : row.role == .system ? "event" : "reply"
    }

    // Accessibility text range support for VoiceOver's reading of selected text.
    override func accessibilitySelectedText() -> String? {
        guard let controller, let row, let index = controller.rowIndex[row.id],
            let selection = controller.selection?.rowSelection(row: index, rowID: row.id, { controller.rowIndex[$0] })
        else { return nil }
        _ = selection
        return controller.selectedText()
    }
}

final class TranscriptCanvasView: NSView {
    weak var owner: TranscriptCellView?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // 8 bits per channel. On a wide-gamut/EDR display the automatic format is 16-bit float (rgba64 in samples
        // of slow frames): twice the backing-store memory and a slower rasterization path, for text and sRGB fills
        // that gain nothing from it.
        layer?.contentsFormat = .RGBA8Uint
    }

    /// A plain CALayer (AppKit draws into it through the view as the layer's delegate): NSViewBackingLayer resets
    /// `contentsFormat` to the window's depth, which on this display is 64-bit.
    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.contentsFormat = .RGBA8Uint
        return layer
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        needsDisplay = true
    }

    /// Format of the backing layer (harness check).
    var backingFormat: String {
        guard let layer else { return "no layer" }
        return "\(type(of: layer)) \(layer.contentsFormat.rawValue) contents: \(layer.contents != nil) delegate: \(layer.delegate === self)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner, let layout = owner.layout, let context = NSGraphicsContext.current?.cgContext else { return }
        TranscriptProfiler.shared.measure(.draw) { drawNow(dirtyRect, owner: owner, layout: layout, context: context) }
    }

    private func drawNow(_ dirtyRect: NSRect, owner: TranscriptCellView, layout: RowLayout, context: CGContext) {
        let signpost = transcriptSignposter.beginInterval("draw")
        defer { transcriptSignposter.endInterval("draw", signpost) }
        // Canvas coordinates: x = 0 is `gutter` points left of the text column; y follows the row.
        let originY = frame.origin.y
        let gutter = TranscriptCellView.gutter
        context.translateBy(x: gutter, y: -originY)
        let columnX = TranscriptGeometry.columnX(forTableWidth: owner.bounds.width, contentWidth: layout.width)
        let dirty = dirtyRect.offsetBy(dx: -gutter, dy: originY)
        let controller = owner.controller
        layout.draw(in: context, dirty: dirty, state: owner.drawState) { controller?.image($0) }
        if owner.isHovered, let row = owner.row { drawTimestamp(row, layout: layout, context: context, columnX: columnX) }
    }

    /// Timestamps on hover, outside the text: left of a prompt bubble, or in the left gutter for replies.
    private func drawTimestamp(_ row: TranscriptRow, layout: RowLayout, context: CGContext, columnX: CGFloat) {
        guard row.created.milliseconds > 0 else { return }
        let text = TranscriptController.timeFormatter.string(from: Date(timeIntervalSince1970: Double(row.created.milliseconds) / 1000))
        let theme = layout.theme
        let font = NSFont.monospacedDigitSystemFont(ofSize: theme.smallSize, weight: .regular)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: theme.tertiary) ?? .tertiaryLabelColor]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        var x: CGFloat
        var y: CGFloat
        if row.role == .user, let first = layout.blocks.first, let bubble = first.decorations.first {
            x = bubble.rect.minX - width - 8
            y = layout.origins[0].y + bubble.rect.maxY - 8
        } else {
            guard columnX >= width + 16, let index = layout.visibleBlockIndices.first else { return }
            x = -width - 10
            y = layout.origins[index].y + 14
        }
        x = max(-columnX + 4, x)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }
}
