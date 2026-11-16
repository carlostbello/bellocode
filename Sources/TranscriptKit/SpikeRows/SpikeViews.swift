// SPIKE G1-B: AppKit views. The table owns all mouse handling (transcript-level selection); row views are passive
// renderers that take their state from the controller each time they are configured, so selection and expansion
// survive row reuse.

import AppKit

/// Single-column view-based table. Row selection is disabled; text selection is the controller's model.
public final class SpikeTableView: NSTableView {
    weak var controller: SpikeTranscriptController?

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) { controller?.mouseDown(event) }
    public override func mouseDragged(with event: NSEvent) { controller?.mouseDragged(event) }
    public override func mouseUp(with event: NSEvent) { controller?.mouseUp(event) }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { controller?.clearSelection(); return }  // Escape
        super.keyDown(with: event)
    }

    @objc public func copy(_ sender: Any?) { controller?.copySelection() }
    public override func selectAll(_ sender: Any?) { controller?.selectAll() }

    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return controller?.hasSelection ?? false }
        return super.validateUserInterfaceItem(item)
    }

    public override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .iBeam)
    }
}

/// Row view without selection drawing; never a hit-test target so the table receives mouse events.
final class SpikeRowView: NSTableRowView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override var isOpaque: Bool { false }
}

/// Reusable cell for one transcript item. Draws through a canvas subview that covers only the visible part of
/// very tall rows, so a 40,000-point row (the 100 KB code block) never gets a 40,000-point backing layer.
final class SpikeItemView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("SpikeItem")
    static let tallRowThreshold: CGFloat = 1_000

    var itemID = 0
    var layout: SpikeItemLayout?
    var rowSelection: SpikeRowSelection?
    var findMatch: (block: Int, range: Range<Int>)?
    weak var imageSource: SpikeTranscriptController?
    let canvas = SpikeCanvasView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        canvas.owner = self
        addSubview(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateCanvas(force: true)
    }

    func invalidate(_ rect: CGRect? = nil) {
        guard let rect else { canvas.needsDisplay = true; return }
        let local = rect.offsetBy(dx: -canvas.frame.minX, dy: -canvas.frame.minY)
        canvas.setNeedsDisplay(local.intersection(canvas.bounds))
    }

    /// Keeps the canvas covering the visible part (plus margin) of tall rows. Hysteresis avoids redrawing it on
    /// every scroll step.
    func updateCanvas(force: Bool = false) {
        let bounds = self.bounds
        let target: CGRect
        if bounds.height <= Self.tallRowThreshold {
            target = bounds
        } else {
            let visible = visibleRect
            if !force, !canvas.frame.isEmpty, !visible.isEmpty,
               canvas.frame.insetBy(dx: 0, dy: -1).contains(visible.insetBy(dx: 1, dy: -200).intersection(bounds)) {
                return
            }
            let margin: CGFloat = 900
            let center = visible.isEmpty ? CGRect(x: 0, y: 0, width: bounds.width, height: 1) : visible
            target = CGRect(x: 0, y: center.minY - margin, width: bounds.width, height: center.height + 2 * margin)
                .intersection(bounds).integral
        }
        if canvas.frame != target {
            canvas.frame = target
            canvas.needsDisplay = true
        }
    }
}

final class SpikeCanvasView: NSView {
    weak var owner: SpikeItemView?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner, let layout = owner.layout, let context = NSGraphicsContext.current?.cgContext else { return }
        let state = spikeSignposter.beginInterval("draw")
        let origin = frame.origin
        context.translateBy(x: -origin.x, y: -origin.y)
        let source = owner.imageSource
        layout.draw(in: context, dirty: dirtyRect.offsetBy(dx: origin.x, dy: origin.y), selection: owner.rowSelection,
                    find: owner.findMatch, images: { source?.image($0) })
        spikeSignposter.endInterval("draw", state)
    }
}
