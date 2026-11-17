import AppKit

// Shared AppKit controls that predate the visual language, restyled onto it (CountBadge, EmptyStateView, UndoToastView)
// or kept for the shell restyle (MonogramView, SidebarRowView, ToolbarButton). New controls live in `Controls/`.

// MARK: - Count badge

/// A count ("3"), hidden when zero. Prominent (attention) counts are a pill: the tint's 16 % (dark) / 10 % (light)
/// surface with the tint as text ("Needs you 2"); others are plain `meta` digits in the tint (`text3` by default).
/// Accessibility: "<count> <noun>".
@MainActor
public final class CountBadge: NSView {
    public var noun = "items" { didSet { updateAccessibility() } }
    public var tint: NSColor = DS.Color.text3 { didSet { needsDisplay = true } }
    public var isProminent = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    public var count = 0 {
        didSet {
            guard count != oldValue else { return }
            isHidden = count == 0
            invalidateIntrinsicContentSize()
            needsDisplay = true
            updateAccessibility()
        }
    }

    private var text: String { count > 999 ? "999+" : "\(count)" }
    private var font: NSFont { DS.TextRole.metaEmph.font(base: DS.Typography.current.baseSize, monospacedDigits: true) }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        let width = DSDraw.width(of: text, font: font)
        return isProminent ? NSSize(width: max(DS.Size.pill, width + 10), height: DS.Size.pill) : NSSize(width: width + 2, height: 16)
    }

    public override func draw(_ dirtyRect: NSRect) {
        if isProminent {
            let dark = DS.Variant(effectiveAppearance).isDark
            DSDraw.fill(bounds, radius: DS.Radius.xs, color: tint.withAlphaComponent(dark ? 0.16 : 0.1))
        }
        DSDraw.text(text, in: bounds, font: font, color: tint, alignment: .center)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func updateAccessibility() {
        setAccessibilityLabel("\(count) \(noun)")
    }
}

// MARK: - Monogram

/// A project's two-letter monogram on a colour derived from its name (stable across launches).
///
/// - Deprecated: coloured monograms are out of the visual language (audit #5). Use `ProjectIcon` (folder glyph or
///   favicon). Kept until the shell restyle (restyle-plan step 1) removes its last use.
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
        // Below every split-view holding priority (250-260): a long title truncates instead of widening the sidebar.
        title.setContentCompressionResistancePriority(.defaultLow - 10, for: .horizontal)
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
        // Unread is an `infoText` dot plus a medium title (visual-language.md §6 Sidebar), never the accent.
        unreadDot.layer?.backgroundColor = DS.Color.infoText.cgColor
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

/// A centred empty, offline or failure state (visual-language.md §6): 32 pt glyph `text4`, `body` title, `label text2`
/// hint, one outline button. No illustrations; never a bare spinner.
@MainActor
public final class EmptyStateView: NSView {
    public let symbol = NSImageView()
    public let title = NSTextField(labelWithString: "")
    public let detail = NSTextField(wrappingLabelWithString: "")
    public let button: DSButton

    public init(symbolName: String, title: String, detail: String, actionTitle: String? = nil, action: Selector? = nil) {
        button = DSButton(title: actionTitle ?? "", variant: .outline, action: action)
        super.init(frame: .zero)
        symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .light))
        symbol.contentTintColor = DS.Color.text4
        self.title.stringValue = title
        self.title.font = DS.TextRole.bodyEmph.font
        self.title.textColor = DS.Color.text
        self.title.alignment = .center
        self.detail.stringValue = detail
        self.detail.font = DS.TextRole.label.font
        self.detail.textColor = DS.Color.text2
        self.detail.alignment = .center
        self.detail.preferredMaxLayoutWidth = 320
        button.isHidden = actionTitle == nil

        let stack = NSStackView(views: [symbol, self.title, self.detail, button])
        stack.orientation = .vertical
        stack.spacing = DS.Space.s6
        stack.setCustomSpacing(DS.Space.s10, after: symbol)
        stack.setCustomSpacing(DS.Space.s14, after: self.detail)
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

/// "Archived 'Fix tests'  [Undo]" (visual-language.md §6 Toast): glass, `r.lg`, 36 high, icon + text + ghost "Undo".
/// The owner decides when to show and hide it (`DS.Motion.toastDismissDelay`, 6 s); showing and hiding are instant.
@MainActor
public final class UndoToastView: NSView {
    public let message = NSTextField(labelWithString: "")
    public let undoButton = DSButton(title: "Undo", variant: .ghost, size: .small)
    public let icon = NSImageView()
    private let glass = DSGlassView(surface: .popover, radius: DS.Radius.lg)

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        message.font = DS.TextRole.body.font
        message.textColor = DS.Color.text
        message.lineBreakMode = .byTruncatingMiddle
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: DS.Size.iconPointRow, weight: .regular))
        icon.contentTintColor = DS.Color.icon
        let stack = NSStackView(views: [icon, message, undoButton])
        stack.spacing = DS.Space.s8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: DS.Space.s12, bottom: 0, right: DS.Space.s6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: DS.Size.toast),
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
        glass.applyFallback()
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
