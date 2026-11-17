import AppKit
import BelloCore
import SwiftUI

/// One shared, stepped animation clock for every spinner and sweep: a single main-run-loop timer, running only while
/// at least one on-screen subscriber exists (visual-language.md §7: stepped, paused off-screen). Rows subscribe when
/// they enter a window and unsubscribe when they leave, so a virtualised list costs one timer, not one per row.
@MainActor
public final class DSStepClock {
    public static let shared = DSStepClock()

    public private(set) var step = 0
    private let subscribers = NSHashTable<NSView>.weakObjects()
    private var timer: Timer?

    public var subscriberCount: Int { subscribers.allObjects.count }

    public func subscribe(_ view: NSView) {
        subscribers.add(view)
        guard timer == nil else { return }
        let interval = DS.Motion.spinnerPeriod / Double(DS.Motion.spinnerSteps)
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { DSStepClock.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func unsubscribe(_ view: NSView) {
        subscribers.remove(view)
        if subscribers.allObjects.isEmpty { stop() }
    }

    private func tick() {
        step &+= 1
        let views = subscribers.allObjects
        if views.isEmpty { stop(); return }
        for view in views { view.needsDisplay = true }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// The running indicator: a 12 pt drawn arc (1.5 pt stroke, `infoText` head on a `borderStrong` track), stepped,
/// paused off-screen, static under Reduce Motion. Not an `NSProgressIndicator`.
@MainActor
public final class DSSpinner: NSView {
    public var diameter: CGFloat = 12 { didSet { needsDisplay = true } }
    public var headColor: NSColor = DS.Color.infoText { didSet { needsDisplay = true } }
    /// Whether it animates (callers stop it when the work ends; it also pauses off-screen).
    public var isAnimating = true { didSet { updateSubscription() } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Running")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: DS.Size.statusGlyph, height: DS.Size.statusGlyph) }
    public override var isFlipped: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSubscription()
    }

    public override func viewDidHide() { super.viewDidHide(); updateSubscription() }
    public override func viewDidUnhide() { super.viewDidUnhide(); updateSubscription() }

    private func updateSubscription() {
        if isAnimating, window != nil, !isHiddenOrHasHiddenAncestor, !DS.Motion.reduceMotion {
            DSStepClock.shared.subscribe(self)
        } else {
            DSStepClock.shared.unsubscribe(self)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let step = DS.Motion.reduceMotion || !isAnimating ? 0 : DSStepClock.shared.step
        DSSpinner.draw(in: bounds, diameter: diameter, step: step, head: headColor)
    }

    /// Draws the arc spinner at a step (also used by `DSStatusGlyphView`).
    public static func draw(in rect: NSRect, diameter: CGFloat, step: Int, head: NSColor) {
        let lineWidth: CGFloat = 1.5
        let radius = (diameter - lineWidth) / 2
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        DS.Color.borderStrong.setStroke()
        track.stroke()
        let steps = DS.Motion.spinnerSteps
        let start = 90 - CGFloat(step % steps) * (360 / CGFloat(steps))
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - 100, clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        head.setStroke()
        arc.stroke()
    }
}

/// A status glyph in a 14 pt slot (visual-language.md §5): outline symbol tinted by tone, the arc spinner for running,
/// a 6 pt dot for unread; empty for idle unless `showsIdle`. Cheap: one `draw(_:)`, cached template symbols, the shared
/// step clock. Accessibility: an image with the status word as its label (never colour alone).
@MainActor
public final class DSStatusGlyphView: NSView {
    public var status: SessionStatus = .idle {
        didSet {
            guard status != oldValue else { return }
            glyph = StatusGlyph(status)
            setAccessibilityLabel(glyph.label)
            updateSubscription()
            needsDisplay = true
        }
    }
    /// Draws a symbol for idle too (lists that need a slot filler).
    public var showsIdle = false { didSet { needsDisplay = true } }
    public var pointSize: CGFloat = DS.Size.iconPointRow { didSet { needsDisplay = true } }
    /// Overrides the symbol (for example `checkmark` for a finished child task) while keeping the status' tone.
    public var symbolOverride: String? { didSet { needsDisplay = true } }
    public var toneOverride: DS.Tone? { didSet { needsDisplay = true } }

    private var glyph = StatusGlyph(.idle)

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(glyph.label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: DS.Size.statusGlyph, height: DS.Size.statusGlyph) }
    public override var isFlipped: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSubscription()
    }

    public override func viewDidHide() { super.viewDidHide(); updateSubscription() }
    public override func viewDidUnhide() { super.viewDidUnhide(); updateSubscription() }

    private var spins: Bool { glyph.shape == .spinner && symbolOverride == nil }

    private func updateSubscription() {
        if spins, window != nil, !isHiddenOrHasHiddenAncestor, !DS.Motion.reduceMotion {
            DSStepClock.shared.subscribe(self)
        } else {
            DSStepClock.shared.unsubscribe(self)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let tint: NSColor = toneOverride.map { $0 == .neutral ? DS.Color.text3 : DS.Color.tone($0).text } ?? glyph.tint
        if let symbol = symbolOverride {
            if let image = DSDraw.symbol(symbol, pointSize: pointSize) { DSDraw.draw(template: image, in: bounds, color: tint) }
            return
        }
        switch glyph.shape {
        case .spinner:
            DSSpinner.draw(in: bounds, diameter: 12, step: DS.Motion.reduceMotion ? 0 : DSStepClock.shared.step, head: tint)
        case .dot:
            DSDraw.fill(NSRect(x: bounds.midX - 3, y: bounds.midY - 3, width: 6, height: 6), radius: 3, color: tint)
        case .symbol:
            if glyph.isQuiet, !showsIdle { return }
            if let image = DSDraw.symbol(glyph.symbolName, pointSize: pointSize) { DSDraw.draw(template: image, in: bounds, color: tint) }
        }
    }
}

/// SwiftUI wrapper of `DSStatusGlyphView`, so hosted views get the same spinner and glyphs.
public struct DSStatusGlyphRepresentable: NSViewRepresentable {
    public var status: SessionStatus
    public var symbolOverride: String?

    public init(status: SessionStatus, symbolOverride: String? = nil) {
        self.status = status
        self.symbolOverride = symbolOverride
    }

    public func makeNSView(context: Context) -> DSStatusGlyphView { DSStatusGlyphView() }

    public func updateNSView(_ view: DSStatusGlyphView, context: Context) {
        if view.status != status { view.status = status }
        if view.symbolOverride != symbolOverride { view.symbolOverride = symbolOverride }
    }
}
