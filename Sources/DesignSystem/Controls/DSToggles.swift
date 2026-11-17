import AppKit

/// Checkbox, radio and switch (visual-language.md §6 "Inputs, toggles"): custom-drawn, 14 pt box / 14 pt radio /
/// 26×16 switch, `borderStrong` ring off, `accent` fill + white mark on, optional title to the right (part of the hit
/// area). Keyboard: Space toggles (radio: selects). Accessibility: checkbox (switch subrole) or radio button, value
/// 0/1, label = title.
@MainActor
public final class DSToggle: DSControl {
    public enum Kind: String, Sendable, CaseIterable { case checkbox, radio, `switch` }

    public let kind: Kind
    public var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(title) } }
    public var isOn: Bool {
        get { isSelected }
        set { isSelected = newValue }
    }

    public init(kind: Kind, title: String = "", isOn: Bool = false, target: AnyObject? = nil, action: Selector? = nil) {
        self.kind = kind
        self.title = title
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isSelected = isOn
        switch kind {
        case .checkbox: setAccessibilityRole(.checkBox)
        case .radio: setAccessibilityRole(.radioButton)
        case .switch:
            setAccessibilityRole(.checkBox)
            setAccessibilitySubrole(.switch)
        }
        setAccessibilityLabel(title)
        setAccessibilityValue(isOn ? 1 : 0)
    }

    private var markSize: NSSize { kind == .switch ? DS.Size.switchSize : NSSize(width: DS.Size.checkbox, height: DS.Size.checkbox) }

    public override var intrinsicContentSize: NSSize {
        let titleWidth = title.isEmpty ? 0 : 8 + DSDraw.width(of: title, font: DS.TextRole.body.font)
        return NSSize(width: ceil(markSize.width + titleWidth), height: max(markSize.height, 20))
    }

    public override func controlStateDidChange(from old: DSControlState) {
        if old.isSelected != controlState.isSelected { setAccessibilityValue(isSelected ? 1 : 0) }
    }

    public override func activate() {
        if kind == .radio {
            guard !isSelected else { return }
            isSelected = true
        } else {
            isSelected.toggle()
        }
        super.activate()
    }

    public override func draw(_ dirtyRect: NSRect) {
        let state = controlState
        let size = markSize
        let box = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let hover = state.phase == .hover || state.phase == .pressed
        switch kind {
        case .checkbox:
            if state.isSelected {
                DSDraw.fill(box, radius: DS.Radius.xs, color: hover ? DS.Color.accentHover : DS.Color.accent)
                let check = NSBezierPath()
                check.move(to: NSPoint(x: box.minX + 3.5, y: box.midY))
                check.line(to: NSPoint(x: box.minX + 6, y: box.midY + 2.5))
                check.line(to: NSPoint(x: box.maxX - 3.2, y: box.midY - 3))
                check.lineWidth = 1.6
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                DS.Color.onAccent.setStroke()
                check.stroke()
            } else {
                DSDraw.fill(box, radius: DS.Radius.xs, color: hover ? DS.Color.fillHover : DS.Color.canvas)
                DSDraw.ring(box, radius: DS.Radius.xs, color: DS.Color.borderStrong)
            }
            drawFocusRing(around: box, radius: DS.Radius.xs)
        case .radio:
            if state.isSelected {
                DSDraw.fill(box, radius: box.width / 2, color: hover ? DS.Color.accentHover : DS.Color.accent)
                DSDraw.fill(box.insetBy(dx: 4.5, dy: 4.5), radius: 2.5, color: DS.Color.onAccent)
            } else {
                DSDraw.fill(box, radius: box.width / 2, color: hover ? DS.Color.fillHover : DS.Color.canvas)
                DSDraw.ring(box, radius: box.width / 2, color: DS.Color.borderStrong)
            }
            drawFocusRing(around: box, radius: box.width / 2)
        case .switch:
            DSDraw.fill(box, radius: box.height / 2, color: state.isSelected ? DS.Color.accent : DS.Color.borderStrong)
            let knob: CGFloat = box.height - 4
            let x = state.isSelected ? box.maxX - 2 - knob : box.minX + 2
            let knobRect = NSRect(x: x, y: box.minY + 2, width: knob, height: knob)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.shadowBlurRadius = 1
            shadow.set()
            DSDraw.fill(knobRect, radius: knob / 2, color: .white)
            NSGraphicsContext.restoreGraphicsState()
            drawFocusRing(around: box, radius: box.height / 2)
        }
        if !title.isEmpty {
            let x = size.width + 8
            DSDraw.text(title, in: NSRect(x: x, y: 0, width: bounds.width - x, height: bounds.height), font: DS.TextRole.body.font, color: DS.Color.text)
        }
    }

    private func drawFocusRing(around rect: NSRect, radius: CGFloat) {
        guard controlState.isFocused else { return }
        DSDraw.ring(rect.insetBy(dx: -3, dy: -3), radius: radius + 3, color: DS.Color.focusRing, width: DS.Border.focusRing)
    }
}
