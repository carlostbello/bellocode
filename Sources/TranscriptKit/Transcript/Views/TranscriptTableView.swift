import AppKit
import QuartzCore
import Synchronization
import DesignSystem

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
        label.font = DS.TextRole.meta.font
        label.textColor = DS.Color.text3
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
    var row: TranscriptRow? {
        didSet { if row != oldValue { accessibilityTextCache = nil } }
    }
    var layout: RowLayout? {
        didSet {
            if layout !== oldValue {
                accessibilityTextCache = nil
                spinnerRects = layout?.spinnerRects ?? []
                updateSpinnerSubscription()
            }
        }
    }
    /// Row-local rects of running spinners; redrawn (only these bands) on each step of the shared clock.
    private(set) var spinnerRects: [CGRect] = []
    private let spinnerTicker = SpinnerTicker()
    /// The row's accessibility text, built when an assistive client first asks (one per live cell).
    private var accessibilityTextCache: RowAccessibilityText?
    var drawState = RowLayout.DrawState(selectionColor: DS.Color.textSelection.cgColor)
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
        spinnerTicker.owner = self
        addSubview(spinnerTicker)
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSpinnerSubscription()
    }

    /// One shared stepped clock for every spinner (DesignSystem): subscribed only while this row shows a spinner in a
    /// window, never under Reduce Motion (the glyph is then drawn static).
    func updateSpinnerSubscription() {
        if !spinnerRects.isEmpty, window != nil, !DS.Motion.reduceMotion {
            DSStepClock.shared.subscribe(spinnerTicker)
        } else {
            DSStepClock.shared.unsubscribe(spinnerTicker)
        }
    }

    fileprivate func spinnerStepped() {
        for rect in spinnerRects { invalidate(rect.insetBy(dx: 0, dy: -1)) }
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

    /// Canvas heights come in 128 pt steps. A reused cell then usually keeps its canvas size, and with it its backing
    /// store: before, nearly every row drawn while scrolling (2,338 of 2,526) resized its canvas, so Core Animation
    /// allocated a new surface through the window server for each, and the main thread waited on that IPC under load.
    /// The part below a short row is transparent and never drawn or hit-tested.
    static func bucket(_ height: CGFloat) -> CGFloat { max(128, ceil(height / 128) * 128) }

    /// Keeps the canvas covering the visible part (plus margin) of tall rows, with hysteresis.
    func updateCanvas(force: Bool = false) {
        let bounds = self.bounds
        let column = columnFrame()
        let target: CGRect
        if bounds.height <= Self.tallRowThreshold {
            target = CGRect(x: column.x, y: 0, width: column.width, height: Self.bucket(bounds.height))
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
            target = CGRect(x: column.x, y: top, width: column.width, height: Self.bucket(max(1, bottom - top)))
        }
        if canvas.frame.size != target.size || canvas.frame.minY != target.minY {
            if canvas.frame.size != target.size { TranscriptProfiler.shared.count("canvasResizes") }
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
        accessibilityTextCache = nil
        guard controller?.isVoiceOverRunning == true else { return }
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func accessibilityLabel() -> String? {
        guard let controller, let row else { return nil }
        return controller.accessibilityLabel(row)
    }

    override func accessibilityValue() -> Any? { accessibilityText()?.text.string as String? }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let controller, let row, let index = controller.rowIndex[row.id] else { return nil }
        return controller.accessibilityActions(index, layout: layout)
    }

    override func accessibilityRoleDescription() -> String? {
        guard let row else { return nil }
        return row.role == .user ? "prompt" : row.role == .system ? "event" : "reply"
    }

    // MARK: Accessibility text (review m2)
    //
    // The row is a static-text element with the parameterized text attributes, so VoiceOver can read it by
    // character, word and line and select a passage. Everything is derived from the row's blocks and its current
    // layout; rows off screen have no cell and no element (the table's own navigation scrolls them in).

    private func accessibilityText() -> (text: RowAccessibilityText, index: Int)? {
        guard let controller, let row, let index = controller.rowIndex[row.id] else { return nil }
        if let cached = accessibilityTextCache { return (cached, index) }
        let text = controller.accessibilityText(index, layout: layout)
        accessibilityTextCache = text
        return (text, index)
    }

    /// The column's offset in this view (the layout's coordinates start at the text column).
    private var columnX: CGFloat {
        TranscriptGeometry.columnX(forTableWidth: bounds.width, contentWidth: layout?.width ?? bounds.width)
    }

    private func clamp(_ range: NSRange, _ text: RowAccessibilityText) -> NSRange {
        let location = min(max(0, range.location), text.length)
        return NSRange(location: location, length: min(max(0, range.length), text.length - location))
    }

    override func accessibilityNumberOfCharacters() -> Int { accessibilityText()?.text.length ?? 0 }

    override func accessibilityString(for range: NSRange) -> String? {
        guard let text = accessibilityText()?.text else { return nil }
        return text.string.substring(with: clamp(range, text))
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map { NSAttributedString(string: $0) }
    }

    override func accessibilityLine(for index: Int) -> Int { accessibilityText()?.text.line(for: index) ?? 0 }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        accessibilityText()?.text.range(forLine: line) ?? NSRange(location: NSNotFound, length: 0)
    }

    override func accessibilityRange(for index: Int) -> NSRange {
        guard let text = accessibilityText()?.text, index >= 0, index < text.length else { return NSRange(location: NSNotFound, length: 0) }
        return text.string.rangeOfComposedCharacterSequence(at: index)
    }

    override func accessibilityStyleRange(for index: Int) -> NSRange {
        accessibilityText()?.text.blockRange(for: index) ?? NSRange(location: NSNotFound, length: 0)
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        guard let (text, index) = accessibilityText(), let controller, let layout else { return NSRange(location: 0, length: 0) }
        let visible = visibleRect
        if visible.minY <= bounds.minY + 0.5, visible.maxY >= bounds.maxY - 0.5 { return text.fullRange }
        guard !visible.isEmpty else { return NSRange(location: 0, length: 0) }
        let top = controller.accessibilityIndex(at: CGPoint(x: 0, y: visible.minY), row: index, text: text, layout: layout)
        let bottom = controller.accessibilityIndex(at: CGPoint(x: layout.width, y: visible.maxY - 1), row: index, text: text, layout: layout)
        let lineStart = text.range(forLine: text.line(for: top))?.location ?? top
        let lineEnd = text.range(forLine: text.line(for: bottom)).map { $0.location + $0.length } ?? bottom
        return NSRange(location: lineStart, length: max(0, lineEnd - lineStart))
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let (text, index) = accessibilityText(), let controller, let window else { return .zero }
        var rect = bounds
        if let layout, let local = controller.accessibilityRect(for: clamp(range, text), row: index, text: text, layout: layout) {
            rect = local.offsetBy(dx: columnX, dy: 0)
        }
        return window.convertToScreen(convert(rect, to: nil))
    }

    override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let (text, index) = accessibilityText(), let controller, let layout, let window else { return NSRange(location: NSNotFound, length: 0) }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let at = controller.accessibilityIndex(at: CGPoint(x: local.x - columnX, y: local.y), row: index, text: text, layout: layout)
        if at < text.length { return text.string.rangeOfComposedCharacterSequence(at: at) }
        return NSRange(location: text.length, length: 0)
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        guard let (text, index) = accessibilityText(), let controller else { return NSRange(location: 0, length: 0) }
        return controller.accessibilitySelectedRange(index, text: text) ?? NSRange(location: 0, length: 0)
    }

    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        guard let (text, index) = accessibilityText(), let controller else { return }
        controller.setAccessibilitySelectedRange(clamp(range, text), row: index, text: text)
    }

    override func accessibilitySelectedText() -> String? {
        guard let (text, index) = accessibilityText(), let controller,
            let range = controller.accessibilitySelectedRange(index, text: text), range.length > 0
        else { return nil }
        return text.string.substring(with: range)
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        guard let (text, _) = accessibilityText() else { return 0 }
        return text.line(for: accessibilitySelectedTextRange().location)
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
        let profiler = TranscriptProfiler.shared
        if profiler.isEnabled {
            profiler.count("canvasDraws")
            profiler.count("canvasDrawKPoints", Int(dirtyRect.width * dirtyRect.height / 1000))
            profiler.count("canvasDraws." + (owner.row.map { TranscriptCanvasView.kindName($0.content) } ?? "none"))
        }
        let start = CACurrentMediaTime()
        profiler.measure(.draw) { drawNow(dirtyRect, owner: owner, layout: layout, context: context) }
        if profiler.isEnabled, let row = owner.row {
            profiler.count("drawMicros." + TranscriptCanvasView.kindName(row.content), Int((CACurrentMediaTime() - start) * 1e6))
        }
    }

    static func kindName(_ content: RowContent) -> String {
        switch content {
        case .user: "user"
        case .markdown(let text, _): text.contains("```") ? "markdownCode" : text.contains("\n|") ? "markdownTable" : "markdown"
        case .reasoning: "reasoning"
        case .work: "work"
        case .file: "file"
        default: "other"
        }
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
        var state = owner.drawState
        if !owner.spinnerRects.isEmpty, !DS.Motion.reduceMotion { state.spinnerStep = DSStepClock.shared.step }
        layout.draw(in: context, dirty: dirty, state: state) { controller?.image($0) }
        if owner.isHovered, let row = owner.row { drawTimestamp(row, layout: layout, context: context, columnX: columnX) }
    }

    /// Timestamps on hover, outside the text: left of a prompt bubble, or in the left gutter for replies.
    private func drawTimestamp(_ row: TranscriptRow, layout: RowLayout, context: CGContext, columnX: CGFloat) {
        guard row.created.milliseconds > 0 else { return }
        let text = TranscriptController.timeFormatter.string(from: Date(timeIntervalSince1970: Double(row.created.milliseconds) / 1000))
        let theme = layout.theme
        let font = NSFont.monospacedDigitSystemFont(ofSize: theme.smallSize, weight: .regular)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: theme.quaternary) ?? DS.Color.text4]))
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

/// Receives the shared step clock's ticks for a cell (the clock marks it for display) and redraws only the cell's
/// spinner bands. Zero-sized and never drawn itself.
final class SpinnerTicker: NSView {
    weak var owner: TranscriptCellView?

    override var needsDisplay: Bool {
        get { false }
        set { if newValue { owner?.spinnerStepped() } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}
