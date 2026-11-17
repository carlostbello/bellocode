import AppKit
import DesignSystem

/// A one-line bar above the page: symbol, message, optional fields, buttons. Used for agent control, the paused
/// state, page dialogs, permission and sign-in prompts, dev-server offers, picked elements and the bridge status.
/// Status is symbol + text, never colour alone.
@MainActor
final class BrowserBanner: NSView {
    enum Tone { case accent, attention, neutral, failure }

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
    private(set) var textFields: [NSTextField] = []
    var identifier_: String = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.medium
        label.font = DS.Typography.current.caption
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        icon.imageScaling = .scaleProportionallyDown
        icon.setContentHuggingPriority(.required, for: .horizontal)
        fields.spacing = DS.Spacing.xs
        buttons.spacing = DS.Spacing.xs
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = DS.Spacing.s
        stack.edgeInsets = NSEdgeInsets(top: DS.Spacing.xs, left: DS.Spacing.m, bottom: DS.Spacing.xs, right: DS.Spacing.xs)
        stack.detachesHiddenViews = true
        stack.distribution = .fill
        for view in [icon, label, fields, buttons] as [NSView] { stack.addArrangedSubview(view) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
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
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        icon.contentTintColor = tint
        refreshColors()
        label.stringValue = message
        label.toolTip = message
        setAccessibilityLabel(message)
        guard rebuild else {
            handlers = actions.map(\.handler)
            for (button, action) in zip(buttons.arrangedSubviews.compactMap { $0 as? NSButton }, actions) { button.title = action.title }
            return
        }
        for view in fields.arrangedSubviews { view.removeFromSuperview() }
        textFields = fieldSpecs.map { spec in
            let field = spec.secure ? NSSecureTextField() : NSTextField()
            field.placeholderString = spec.placeholder
            field.stringValue = spec.value
            field.controlSize = .small
            field.font = DS.Typography.current.caption
            field.setAccessibilityLabel(spec.placeholder)
            field.widthAnchor.constraint(equalToConstant: 140).isActive = true
            fields.addArrangedSubview(field)
            return field
        }
        fields.isHidden = textFields.isEmpty
        for view in buttons.arrangedSubviews { view.removeFromSuperview() }
        handlers = actions.map(\.handler)
        for (index, action) in actions.enumerated() {
            let button = NSButton(title: action.title, target: self, action: #selector(pressed(_:)))
            button.tag = index
            button.controlSize = .small
            button.bezelStyle = .push
            if action.isDefault { button.keyEquivalent = "\r" }
            button.hasDestructiveAction = action.isDestructive
            buttons.addArrangedSubview(button)
        }
    }

    private var tone: Tone = .neutral

    private var tint: NSColor {
        switch tone {
        case .accent: DS.Palette.accent
        case .attention: DS.Palette.attention
        case .neutral: DS.Palette.secondaryText
        case .failure: DS.Palette.failure
        }
    }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = tint.withAlphaComponent(0.35).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    @objc private func pressed(_ sender: NSButton) {
        guard handlers.indices.contains(sender.tag) else { return }
        handlers[sender.tag]()
    }
}

/// Find in page: field, match count, previous/next, Done. Return and ⌘G go forward, ⇧Return and ⇧⌘G back, Escape closes.
@MainActor
final class BrowserFindBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    let count = NSTextField(labelWithString: "")
    var onChange: ((String) -> Void)?
    var onNext: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = "Find in page"
        field.controlSize = .small
        field.font = DS.Typography.current.caption
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(changed)
        count.font = DS.Typography.current.caption
        count.textColor = DS.Palette.secondaryText
        let previous = BrowserToolbarView.button("chevron.up", "Previous Match (⇧⌘G)")
        previous.target = self
        previous.action = #selector(previousMatch)
        let next = BrowserToolbarView.button("chevron.down", "Next Match (⌘G)")
        next.target = self
        next.action = #selector(nextMatch)
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.controlSize = .small
        done.bezelStyle = .push
        let stack = NSStackView(views: [field, count, previous, next, done])
        stack.spacing = DS.Spacing.xs
        stack.edgeInsets = NSEdgeInsets(top: 3, left: DS.Spacing.m, bottom: 3, right: DS.Spacing.m)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            field.widthAnchor.constraint(equalToConstant: 220),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Find in page")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
    private let clear = NSButton(title: "Clear", target: nil, action: nil)
    weak var downloads: BrowserDownloads?

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.spacing = DS.Spacing.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        clear.controlSize = .small
        clear.bezelStyle = .push
        clear.target = self
        clear.action = #selector(clearFinished)
        clear.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Downloads")
        title.font = DS.Typography.current.sectionHeader
        title.textColor = DS.Palette.secondaryText
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        addSubview(stack)
        addSubview(clear)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.m), title.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: DS.Spacing.m), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: clear.leadingAnchor, constant: -DS.Spacing.m),
            clear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.m), clear.centerYAnchor.constraint(equalTo: centerYAnchor),
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

@MainActor
private final class DownloadChip: NSView {
    private let item: BrowserDownloads.Item
    private weak var downloads: BrowserDownloads?

    init(item: BrowserDownloads.Item, downloads: BrowserDownloads?) {
        self.item = item
        self.downloads = downloads
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.small
        let icon = NSImageView(image: NSWorkspace.shared.icon(for: .data))
        if let destination = item.destination { icon.image = NSWorkspace.shared.icon(forFile: destination.path) }
        icon.imageScaling = .scaleProportionallyDown
        let name = NSTextField(labelWithString: item.filename)
        name.font = DS.Typography.current.caption
        name.lineBreakMode = .byTruncatingMiddle
        let state = NSTextField(labelWithString: "")
        state.font = DS.Typography.current.caption
        state.textColor = DS.Palette.secondaryText
        let action = NSButton()
        action.isBordered = false
        action.bezelStyle = .accessoryBarAction
        action.target = self
        switch item.state {
        case .running(let fraction):
            state.stringValue = fraction.map { "\(Int($0 * 100))%" } ?? ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
            action.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Cancel Download")
            action.action = #selector(cancel)
            action.toolTip = "Cancel"
        case .finished:
            state.stringValue = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
            action.image = NSImage(systemSymbolName: "magnifyingglass.circle", accessibilityDescription: "Show in Finder")
            action.action = #selector(reveal)
            action.toolTip = "Show in Finder"
        case .failed(let reason):
            state.stringValue = "Failed"
            state.toolTip = reason
            action.isHidden = true
        case .cancelled:
            state.stringValue = "Cancelled"
            action.isHidden = true
        }
        let stack = NSStackView(views: [icon, name, state, action])
        stack.spacing = DS.Spacing.xs
        stack.edgeInsets = NSEdgeInsets(top: 2, left: DS.Spacing.xs, bottom: 2, right: DS.Spacing.xs)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel("\(item.filename), \(state.stringValue)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateLayer() {
        layer?.backgroundColor = DS.Palette.groupFill.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    @objc private func cancel() { downloads?.cancel(item) }
    @objc private func reveal() { downloads?.reveal(item) }
}
