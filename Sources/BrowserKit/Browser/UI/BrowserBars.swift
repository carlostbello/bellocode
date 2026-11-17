import AppKit
import DesignSystem

/// A one-line bar above the page: symbol, message, optional fields, buttons. Used for agent control, the paused
/// state, page dialogs, permission and sign-in prompts, dev-server offers, picked elements and the bridge status.
/// The banner recipe (§6, restyle step 7): a tinted row (`r.md`, the tone's surface, no border), 14 pt glyph in the
/// tone's text colour, message `label text`; actions: the default one primary, otherwise the last one outline and the
/// rest ghost ("Stop" ghost, "Take Over" outline). Status is symbol + text, never colour alone.
@MainActor
final class BrowserBanner: NSView, NSTextFieldDelegate {
    enum Tone {
        case accent, attention, neutral, failure

        var ds: DS.Tone {
            switch self {
            case .accent: .info
            case .attention: .warning
            case .neutral: .neutral
            case .failure: .danger
            }
        }
    }

    struct Action {
        var title: String
        var isDefault = false
        var isDestructive = false
        var handler: @MainActor () -> Void
    }

    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let fields = NSStackView()
    private let buttons = NSStackView()
    private let stack = NSStackView()
    private var handlers: [@MainActor () -> Void] = []
    private var defaultIndex: Int?
    private(set) var textFields: [NSTextField] = []
    var identifier_: String = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = DS.TextRole.label.font
        label.textColor = DS.Color.text
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        icon.imageScaling = .scaleProportionallyDown
        icon.setContentHuggingPriority(.required, for: .horizontal)
        fields.spacing = DS.Space.s6
        buttons.spacing = DS.Space.s6
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = DS.Space.s8
        stack.edgeInsets = NSEdgeInsets(top: DS.Space.s4, left: DS.Space.s10, bottom: DS.Space.s4, right: DS.Space.s6)
        stack.detachesHiddenViews = true
        stack.distribution = .fill
        for view in [icon, label, fields, buttons] as [NSView] { stack.addArrangedSubview(view) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.widthAnchor.constraint(equalToConstant: DS.Size.iconBox), heightAnchor.constraint(greaterThanOrEqualToConstant: DS.Size.toolbar),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(
        id: String, symbol: String, tone: Tone, message: String, fields fieldSpecs: [(placeholder: String, secure: Bool, value: String)] = [],
        actions: [Action]
    ) {
        let rebuild = identifier_ != id || textFields.count != fieldSpecs.count || buttons.arrangedSubviews.count != actions.count
        identifier_ = id
        self.tone = tone
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: DS.Size.iconPointRow + 1, weight: .regular))
        icon.contentTintColor = DS.Color.tone(tone.ds).text
        needsDisplay = true
        label.stringValue = message
        label.toolTip = message
        setAccessibilityLabel(message)
        defaultIndex = actions.firstIndex(where: \.isDefault)
        guard rebuild else {
            handlers = actions.map(\.handler)
            for (button, action) in zip(buttons.arrangedSubviews.compactMap { $0 as? DSButton }, actions) { button.title = action.title }
            return
        }
        for view in fields.arrangedSubviews { view.removeFromSuperview() }
        textFields = fieldSpecs.map { spec in
            let box = DSTextField(placeholder: spec.placeholder, field: spec.secure ? DSSecureBareTextField() : nil)
            box.showsHalo = false
            box.field.stringValue = spec.value
            box.field.delegate = self
            box.field.setAccessibilityLabel(spec.placeholder)
            box.widthAnchor.constraint(equalToConstant: 150).isActive = true
            box.heightAnchor.constraint(equalToConstant: DS.Size.controlSmall + 2).isActive = true
            fields.addArrangedSubview(box)
            return box.field
        }
        fields.isHidden = textFields.isEmpty
        for view in buttons.arrangedSubviews { view.removeFromSuperview() }
        handlers = actions.map(\.handler)
        for (index, action) in actions.enumerated() {
            let variant: DSButton.Variant = action.isDefault ? .primary : (index == actions.count - 1 ? .outline : .ghost)
            let button = DSButton(title: action.title, variant: action.isDestructive ? .destructive : variant, size: .small, target: self, action: #selector(pressed(_:)))
            button.tag = index
            if action.isDefault { button.shortcutHint = "↩" }
            buttons.addArrangedSubview(button)
        }
    }

    private var tone: Tone = .neutral

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let colors = DS.Color.tone(tone.ds)
        DSDraw.fill(bounds, radius: DS.Radius.md, color: tone == .neutral ? DS.Color.fillSubtle : colors.surface)
        if tone == .neutral { DSDraw.ring(bounds, radius: DS.Radius.md, color: DS.Color.border) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @objc private func pressed(_ sender: NSView) {
        let tag = (sender as? DSButton)?.tag ?? -1
        guard handlers.indices.contains(tag) else { return }
        handlers[tag]()
    }

    /// Return in a field runs the default action (the banner's fields replaced the push button's key equivalent).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), let defaultIndex, handlers.indices.contains(defaultIndex) else { return false }
        handlers[defaultIndex]()
        return true
    }
}

/// A secure editable field for `DSTextField` (sign-in prompts).
@MainActor
final class DSSecureBareTextField: DSBareTextField {
    override class var cellClass: AnyClass? {
        get { NSSecureTextFieldCell.self }
        set {}
    }
}

/// Find in page (§6 find bars): the DS search field, match count (`meta text3`), previous / next icon buttons and a
/// ghost Done on a 32 pt `canvas` strip. Return and ⌘G go forward, ⇧Return and ⇧⌘G back, Escape closes.
@MainActor
final class BrowserFindBar: NSView, NSTextFieldDelegate {
    private let input = DSTextField(style: .search, placeholder: "Find in page")
    var field: NSTextField { input.field }
    let count = NSTextField(labelWithString: "")
    var onChange: ((String) -> Void)?
    var onNext: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        input.showsHalo = false
        field.delegate = self
        field.setAccessibilityLabel("Find in page")
        count.font = .monospacedDigitSystemFont(ofSize: DS.TextRole.meta.font.pointSize, weight: .regular)
        count.textColor = DS.Color.text3
        let previous = BrowserToolbarView.button("chevron.up", "Previous Match (⇧⌘G)")
        previous.target = self
        previous.action = #selector(previousMatch)
        let next = BrowserToolbarView.button("chevron.down", "Next Match (⌘G)")
        next.target = self
        next.action = #selector(nextMatch)
        let done = DSButton(title: "Done", variant: .ghost, size: .small, target: self, action: #selector(close))
        let stack = NSStackView(views: [input, count, previous, next, done])
        stack.spacing = DS.Space.s4
        stack.alignment = .centerY
        stack.setCustomSpacing(DS.Space.s8, after: input)
        stack.setCustomSpacing(DS.Space.s8, after: count)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: DS.Space.s8, bottom: 0, right: DS.Space.s8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            input.widthAnchor.constraint(equalToConstant: 220),
            input.heightAnchor.constraint(equalToConstant: DS.Size.controlSmall),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Find in page")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func controlTextDidChange(_ notification: Notification) { changed() }

    @objc private func changed() { onChange?(field.stringValue) }
    @objc private func previousMatch() { onNext?(false) }
    @objc private func nextMatch() { onNext?(true) }
    @objc private func close() { onClose?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onNext?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

/// The downloads shelf at the bottom of the pane: recent downloads with progress, Show in Finder, Cancel, Clear.
@MainActor
final class DownloadsShelfView: NSView {
    private let stack = NSStackView()
    private let clear = DSButton(title: "Clear", variant: .ghost, size: .small)
    weak var downloads: BrowserDownloads?

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.spacing = DS.Space.s8
        stack.translatesAutoresizingMaskIntoConstraints = false
        clear.isMuted = true
        clear.target = self
        clear.action = #selector(clearFinished)
        clear.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Downloads")
        title.font = DS.TextRole.labelEmph.font
        title.textColor = DS.Color.text3
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        addSubview(stack)
        addSubview(clear)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DS.Size.toolbar),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.s12), title.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: DS.Space.s12), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: clear.leadingAnchor, constant: -DS.Space.s12),
            clear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.s8), clear.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Downloads")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        for item in (downloads?.items ?? []).prefix(4) {
            stack.addArrangedSubview(DownloadChip(item: item, downloads: downloads))
        }
    }

    @objc private func clearFinished() { downloads?.clearFinished() }
}

/// A download (§6 pills/chips): `fillSubtle` with a `border` ring, `r.md`, file icon, name `label`, state `meta text3`
/// (a word, plus a thin accent bar while running), and a ghost icon button (Cancel / Show in Finder).
@MainActor
private final class DownloadChip: NSView {
    private let item: BrowserDownloads.Item
    private weak var downloads: BrowserDownloads?

    init(item: BrowserDownloads.Item, downloads: BrowserDownloads?) {
        self.item = item
        self.downloads = downloads
        super.init(frame: .zero)
        let icon = NSImageView(image: NSWorkspace.shared.icon(for: .data))
        if let destination = item.destination { icon.image = NSWorkspace.shared.icon(forFile: destination.path) }
        icon.imageScaling = .scaleProportionallyDown
        let name = NSTextField(labelWithString: item.filename)
        name.font = DS.TextRole.label.font
        name.textColor = DS.Color.text
        name.lineBreakMode = .byTruncatingMiddle
        let state = NSTextField(labelWithString: "")
        state.font = .monospacedDigitSystemFont(ofSize: DS.TextRole.meta.font.pointSize, weight: .regular)
        state.textColor = DS.Color.text3
        let action = DSButton(icon: "xmark", accessibilityTitle: "Cancel Download", size: .small)
        action.target = self
        switch item.state {
        case .running(let fraction):
            state.stringValue = fraction.map { "\(Int($0 * 100))%" } ?? ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
            action.action = #selector(cancel)
            action.toolTip = "Cancel"
            progress = fraction
        case .finished:
            state.stringValue = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
            action.symbolName = "magnifyingglass"
            action.accessibilityTitle = "Show in Finder"
            action.action = #selector(reveal)
            action.toolTip = "Show in Finder"
        case .failed(let reason):
            state.stringValue = "Failed"
            state.textColor = DS.Color.dangerText
            state.toolTip = reason
            action.isHidden = true
        case .cancelled:
            state.stringValue = "Cancelled"
            action.isHidden = true
        case .queued:
            state.stringValue = "Queued"
            action.action = #selector(cancel)
            action.toolTip = "Cancel"
        case .refused(let reason):
            state.stringValue = "Refused"
            state.toolTip = reason
            action.isHidden = true
        }
        let stack = NSStackView(views: [icon, name, state, action])
        stack.spacing = DS.Space.s6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: DS.Space.s6, bottom: 0, right: DS.Space.s2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            heightAnchor.constraint(equalToConstant: DS.Size.control),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel("\(item.filename), \(state.stringValue)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The running download's fraction (a 2 pt accent bar along the bottom).
    private var progress: Double?

    override func draw(_ dirtyRect: NSRect) {
        DSDraw.fill(bounds, radius: DS.Radius.md, color: DS.Color.fillSubtle)
        DSDraw.ring(bounds, radius: DS.Radius.md, color: DS.Color.border)
        if let progress {
            let bar = NSRect(x: 6, y: 1, width: max(4, (bounds.width - 12) * progress), height: 2)
            DSDraw.fill(bar, radius: 1, color: DS.Color.accent)
        }
    }

    @objc private func cancel() { downloads?.cancel(item) }
    @objc private func reveal() { downloads?.reveal(item) }
}
