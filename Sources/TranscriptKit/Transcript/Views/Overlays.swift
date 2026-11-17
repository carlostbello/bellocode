import AppKit
import DesignSystem

/// The transcript's root view: the table's scroll view plus the floating find bar and jump pill.
public final class TranscriptContainerView: NSView {
    var onAppearanceChange: (() -> Void)?

    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        layer?.backgroundColor = DS.Palette.contentBackground.cgColor
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
/// on hide). A button: keyboard and VoiceOver reachable.
final class JumpPillView: NSButton {
    var onJump: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            return shadow
        }()
        font = .systemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
        imagePosition = .imageTrailing
        imageHugsTitle = true
        target = self
        action = #selector(jump(_:))
        isHidden = true
        setTitle(newOutput: false)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Scroll to the newest output (⇧⌘J)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 26, height: 28)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = DS.Palette.cardBackground.cgColor
        layer?.borderColor = DS.Palette.cardBorder.cgColor
        contentTintColor = DS.Palette.text
    }

    func setTitle(newOutput: Bool) {
        title = newOutput ? "New output" : "Jump to Latest"
        setAccessibilityLabel(newOutput ? "New output below. Jump to latest" : "Jump to latest")
    }

    @objc private func jump(_ sender: Any?) { onJump?() }
}

/// The find bar (⌘F): field, match count, previous/next, done. Floats at the top right of the transcript and never
/// moves the content under it.
final class FindBarView: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    let count = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private let done = NSButton(title: "Done", target: nil, action: nil)
    var onChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
            return shadow
        }()
        field.placeholderString = "Find in Thread"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.controlSize = .regular
        field.setAccessibilityLabel("Find in thread")
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        for (button, symbol, label, selector) in [
            (previous, "chevron.up", "Previous match", #selector(previousMatch(_:))),
            (next, "chevron.down", "Next match", #selector(nextMatch(_:))),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.target = self
            button.action = selector
            button.toolTip = label
        }
        previous.toolTip = "Previous match (⇧⌘G)"
        next.toolTip = "Next match (⌘G)"
        done.bezelStyle = .push
        done.controlSize = .small
        done.target = self
        done.action = #selector(close(_:))
        let stack = NSStackView(views: [field, count, previous, next, done])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 220),
        ])
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Find")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = DS.Palette.cardBackground.cgColor
        layer?.borderColor = DS.Palette.cardBorder.cgColor
    }

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
