import AppKit

// Shared AppKit controls. Small, dense, appearance-following, and accessible: each exposes a text label so nothing is
// conveyed by colour or shape alone. All are `@MainActor` (NSView).

// MARK: - Count badge

/// A capsule with a number ("3"). Hidden when the count is zero. Accessibility: "<count> <noun>".
@MainActor
public final class CountBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    public var noun = "items" { didSet { updateAccessibility() } }
    public var tint: NSColor = DS.Palette.secondaryText { didSet { needsDisplay = true } }
    /// Filled badges (attention) use the tint as fill with white text; others a subtle fill with tinted text.
    public var isProminent = false { didSet { applyStyle() } }

    public var count = 0 {
        didSet {
            guard count != oldValue else { return }
            label.stringValue = count > 999 ? "999+" : "\(count)"
            isHidden = count == 0
            invalidateIntrinsicContentSize()
            updateAccessibility()
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.font = DS.Typography.current.badge
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize {
        let text = label.intrinsicContentSize
        return NSSize(width: max(16, text.width + 8), height: 15)
    }

    public override func updateLayer() {
        layer?.cornerRadius = DS.Radius.capsule(height: bounds.height)
        layer?.backgroundColor = (isProminent ? tint : DS.Palette.groupFill).cgColor
    }

    public override var wantsUpdateLayer: Bool { true }

    private func applyStyle() {
        label.textColor = isProminent ? .white : tint
        needsDisplay = true
    }

    private func updateAccessibility() {
        setAccessibilityLabel("\(count) \(noun)")
    }
}

// MARK: - Monogram

/// A project's two-letter monogram on a colour derived from its name (stable across launches).
@MainActor
public final class MonogramView: NSView {
    private let label = NSTextField(labelWithString: "")
    public var name = "" {
        didSet {
            guard name != oldValue else { return }
            label.stringValue = Self.initials(name)
            needsDisplay = true
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.font = .systemFont(ofSize: 8.5, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 16),
            heightAnchor.constraint(equalToConstant: 16),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        layer?.cornerRadius = DS.Radius.small
        layer?.backgroundColor = Self.color(for: name).cgColor
    }

    /// Up to two letters: the first letters of the first two words, else the first two characters.
    public nonisolated static func initials(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        let letters: [Character] = words.count >= 2 ? [words[0].first!, words[1].first!] : Array(name.filter { $0.isLetter || $0.isNumber }.prefix(2))
        return String(letters).uppercased()
    }

    /// One of a fixed palette of system colours, chosen by a stable hash (not `hashValue`, which is seeded per run).
    public nonisolated static func paletteIndex(for name: String, paletteSize: Int = 12) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Int(hash % UInt32(paletteSize))
    }

    private static let palette: [NSColor] = [
        .systemBlue, .systemPurple, .systemPink, .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemMint,
        .systemTeal, .systemCyan, .systemIndigo, .systemBrown,
    ]

    static func color(for name: String) -> NSColor { palette[paletteIndex(for: name)] }
}

// MARK: - Sidebar row

/// A dense sidebar row: leading image, title (inline-editable), trailing detail text and an optional badge. Hosts in
/// an `NSOutlineView`/`NSTableView` (it is an `NSTableCellView`, so `textField` editing and accessibility work).
@MainActor
open class SidebarRowView: NSTableCellView {
    public let leading = NSImageView()
    public let monogram = MonogramView()
    public let title = NSTextField(labelWithString: "")
    public let detail = NSTextField(labelWithString: "")
    public let badge = CountBadge()
    /// A small accent dot before the title (unread). Paired with an accessibility value, never colour alone.
    public let unreadDot = NSView()
    /// Shown on hover and on keyboard selection (for example "New thread" on a project row).
    public let accessoryButton = NSButton()
    private var leadingConstraint: NSLayoutConstraint!

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let typography = DS.Typography.current
        title.font = typography.body
        title.lineBreakMode = .byTruncatingTail
        title.cell?.truncatesLastVisibleLine = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.font = typography.caption
        detail.textColor = DS.Palette.secondaryText
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        leading.imageScaling = .scaleProportionallyDown
        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = 3
        unreadDot.isHidden = true
        accessoryButton.isBordered = false
        accessoryButton.bezelStyle = .accessoryBarAction
        accessoryButton.imagePosition = .imageOnly
        accessoryButton.isHidden = true
        monogram.isHidden = true
        textField = title
        imageView = leading

        let stack = NSStackView(views: [leading, monogram, unreadDot, title, badge, detail, accessoryButton])
        stack.orientation = .horizontal
        stack.spacing = DS.Spacing.s
        stack.alignment = .centerY
        stack.setCustomSpacing(DS.Spacing.xs, after: unreadDot)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.detachesHiddenViews = true
        addSubview(stack)
        leadingConstraint = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.xxs)
        NSLayoutConstraint.activate([
            leadingConstraint,
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.s),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading.widthAnchor.constraint(equalToConstant: 16),
            leading.heightAnchor.constraint(equalToConstant: 16),
            unreadDot.widthAnchor.constraint(equalToConstant: 6),
            unreadDot.heightAnchor.constraint(equalToConstant: 6),
            accessoryButton.widthAnchor.constraint(equalToConstant: 18),
            accessoryButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    open override func updateLayer() {
        unreadDot.layer?.backgroundColor = DS.Palette.accent.cgColor
    }

    open override var wantsUpdateLayer: Bool { true }

    public var leadingInset: CGFloat {
        get { leadingConstraint.constant }
        set { leadingConstraint.constant = newValue }
    }

    public var showsUnread: Bool {
        get { !unreadDot.isHidden }
        set {
            unreadDot.isHidden = !newValue
            needsDisplay = true
        }
    }
}

// MARK: - Empty state

/// A centred symbol, title, one line of detail and an optional action button. For empty, offline and failure
/// states; never a bare spinner.
@MainActor
public final class EmptyStateView: NSView {
    public let symbol = NSImageView()
    public let title = NSTextField(labelWithString: "")
    public let detail = NSTextField(wrappingLabelWithString: "")
    public let button = NSButton()

    public init(symbolName: String, title: String, detail: String, actionTitle: String? = nil, action: Selector? = nil) {
        super.init(frame: .zero)
        symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .light))
        symbol.contentTintColor = DS.Palette.tertiaryText
        self.title.stringValue = title
        self.title.font = DS.Typography.current.title
        self.title.alignment = .center
        self.detail.stringValue = detail
        self.detail.font = DS.Typography.current.body
        self.detail.textColor = DS.Palette.secondaryText
        self.detail.alignment = .center
        self.detail.preferredMaxLayoutWidth = 320
        button.bezelStyle = .push
        button.controlSize = .regular
        button.title = actionTitle ?? ""
        button.action = action
        button.isHidden = actionTitle == nil

        let stack = NSStackView(views: [symbol, self.title, self.detail, button])
        stack.orientation = .vertical
        stack.spacing = DS.Spacing.m
        stack.setCustomSpacing(DS.Spacing.l, after: self.detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.detachesHiddenViews = true
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -DS.Spacing.xxl),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: DS.Spacing.xl),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DS.Spacing.xl),
            self.detail.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - Undo toast

/// "Archived 'Fix tests'  [Undo]" at the bottom of a region. The owner decides when to show and hide it (5 s by
/// convention); showing and hiding are instant under Reduce Motion.
@MainActor
public final class UndoToastView: NSVisualEffectView {
    public let message = NSTextField(labelWithString: "")
    public let undoButton = NSButton(title: "Undo", target: nil, action: nil)

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.large
        layer?.borderWidth = DS.Spacing.hairline
        layer?.borderColor = DS.Palette.separator.cgColor
        message.font = DS.Typography.current.body
        message.lineBreakMode = .byTruncatingMiddle
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        undoButton.bezelStyle = .push
        undoButton.controlSize = .small
        undoButton.keyEquivalent = ""
        let stack = NSStackView(views: [message, undoButton])
        stack.spacing = DS.Spacing.m
        stack.edgeInsets = NSEdgeInsets(top: DS.Spacing.s, left: DS.Spacing.l, bottom: DS.Spacing.s, right: DS.Spacing.s)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `text` and announces it to VoiceOver.
    public func show(_ text: String) {
        message.stringValue = text
        setAccessibilityLabel(text)
        alphaValue = 1
        isHidden = false
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [.announcement: "\(text). Undo available.", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    public func hide() {
        isHidden = true
    }
}

// MARK: - Toolbar

/// Builds a toolbar button item with an SF Symbol, a label (shown in "Icon and Text" mode and to VoiceOver) and a
/// tooltip that names the shortcut. The action travels the responder chain (nil target) so menu validation and the
/// toolbar agree.
@MainActor
public enum ToolbarButton {
    public static func make(
        _ identifier: NSToolbarItem.Identifier, label: String, symbolName: String, action: Selector, toolTip: String? = nil
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = toolTip ?? label
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        item.action = action
        item.target = nil
        item.isBordered = true
        return item
    }
}
