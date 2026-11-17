import AppKit
import DesignSystem

/// The transcript's root view: the table's scroll view plus the floating find bar and jump pill.
public final class TranscriptContainerView: NSView {
    var onAppearanceChange: (() -> Void)?

    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        layer?.backgroundColor = DS.Color.canvas.cgColor
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onAppearanceChange?() }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        onAppearanceChange?()
    }
}

/// "New output ↓" / "Jump to Latest ↓": shown when the reader is away from the bottom (debounced on show, immediate
/// on hide). An outline `DSButton` on an opaque `raised` fill with the popover shadow (it floats over text): keyboard
/// and VoiceOver reachable.
final class JumpPillView: DSButton {
    var onJump: (() -> Void)?

    init() {
        super.init(title: "Jump to Latest", variant: .outline, size: .small)
        trailingSymbolName = "arrow.down"
        horizontalPadding = 12
        target = self
        action = #selector(jump(_:))
        isHidden = true
        setTitle(newOutput: false)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Scroll to the newest output (⇧⌘J)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Opaque under the outline recipe so prose never shows through.
        DSDraw.fill(bounds, radius: radius, color: DS.Color.raised)
        super.draw(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyShadow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyShadow()
    }

    private func applyShadow() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.6 : 0.12)
        self.shadow = shadow
    }

    func setTitle(newOutput: Bool) {
        title = newOutput ? "New output" : "Jump to Latest"
        setAccessibilityLabel(newOutput ? "New output below. Jump to latest" : "Jump to latest")
    }

    @objc private func jump(_ sender: Any?) { onJump?() }
}

/// The find bar (⌘F): a `DSTextField` search field, match count (`meta text3`, tabular), previous / next icon buttons
/// and a ghost Done, on the popover surface (glass with a solid `raised` fallback). Floats at the top right of the
/// transcript and never moves the content under it.
final class FindBarView: NSView, NSTextFieldDelegate {
    private let search = DSTextField(style: .search, placeholder: "Find in Thread")
    var field: NSTextField { search.field }
    let count = NSTextField(labelWithString: "")
    private let glass = DSGlassView(surface: .popover, radius: DS.Radius.lg)
    private let previous = DSButton(icon: "chevron.up", accessibilityTitle: "Previous match", size: .small)
    private let next = DSButton(icon: "chevron.down", accessibilityTitle: "Next match", size: .small)
    private let done = DSButton(title: "Done", variant: .ghost, size: .small)
    var onChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        search.showsHalo = false
        field.delegate = self
        field.setAccessibilityLabel("Find in thread")
        count.font = .monospacedDigitSystemFont(ofSize: DS.TextRole.meta.font.pointSize, weight: .regular)
        count.textColor = DS.Color.text3
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        for (button, selector) in [(previous, #selector(previousMatch(_:))), (next, #selector(nextMatch(_:)))] {
            button.target = self
            button.action = selector
        }
        previous.toolTip = "Previous match (⇧⌘G)"
        next.toolTip = "Next match (⌘G)"
        done.target = self
        done.action = #selector(close(_:))
        let stack = NSStackView(views: [search, count, previous, next, done])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.setCustomSpacing(8, after: search)
        stack.setCustomSpacing(6, after: count)
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            search.widthAnchor.constraint(equalToConstant: 220),
            search.heightAnchor.constraint(equalToConstant: DS.Size.control),
        ])
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Find")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(count matches: Int, current: Int?, query: String) {
        if query.isEmpty {
            count.stringValue = ""
        } else if matches == 0 {
            count.stringValue = "No matches"
        } else {
            let total = matches >= FindSearch.matchLimit ? "\(matches.formatted())+" : matches.formatted()
            count.stringValue = "\((current ?? 0) + 1) of \(total)"
        }
        count.setAccessibilityLabel(count.stringValue)
        previous.isEnabled = matches > 0
        next.isEnabled = matches > 0
        if !count.stringValue.isEmpty {
            NSAccessibility.post(
                element: count, notification: .announcementRequested,
                userInfo: [.announcement: count.stringValue, .priority: NSAccessibilityPriorityLevel.low.rawValue])
        }
    }

    func controlTextDidChange(_ notification: Notification) { onChange?(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrevious?() } else { onNext?() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    @objc private func previousMatch(_ sender: Any?) { onPrevious?() }
    @objc private func nextMatch(_ sender: Any?) { onNext?() }
    @objc private func close(_ sender: Any?) { onClose?() }
}
