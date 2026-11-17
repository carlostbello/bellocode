import AppKit

// Navigation controls (M2-D, docs/features/navigation.md): the drop badge, section headers, shortcut glyphs and
// match highlighting shared by the sidebar, the palette and search.

/// "Pin", "Settle", "Snooze until Tue 09:00", or why a drop is not allowed, shown beside the pointer area during a
/// sidebar drag. Text plus a symbol, never colour alone.
@MainActor
public final class DropBadgeView: NSVisualEffectView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderWidth = DS.Spacing.hairline
        layer?.borderColor = DS.Palette.separator.cgColor
        label.font = DS.Typography.current.captionEmphasized
        label.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [icon, label])
        stack.spacing = DS.Spacing.xs
        stack.edgeInsets = NSEdgeInsets(top: 3, left: DS.Spacing.m, bottom: 3, right: DS.Spacing.m)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func show(_ text: String, allowed: Bool) {
        label.stringValue = text
        label.textColor = allowed ? DS.Palette.text : DS.Palette.secondaryText
        icon.image = NSImage(
            systemSymbolName: allowed ? "arrow.down.to.line" : "nosign", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                .init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [allowed ? DS.Palette.accent : DS.Palette.failure])))
        setAccessibilityLabel(allowed ? "Drop to \(text)" : "Cannot drop: \(text)")
        isHidden = false
    }

    public func hide() { isHidden = true }
}

/// Key equivalents as the menu shows them: "⇧⌘P", "⌃`", "F6".
public enum ShortcutText {
    public static func display(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        guard !key.isEmpty else { return "" }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let scalar = key.unicodeScalars.first.map { Int($0.value) } ?? 0
        let glyph: String = switch scalar {
        case NSF6FunctionKey: "F6"
        case NSUpArrowFunctionKey: "↑"
        case NSDownArrowFunctionKey: "↓"
        case NSLeftArrowFunctionKey: "←"
        case NSRightArrowFunctionKey: "→"
        case NSBackspaceCharacter, NSDeleteCharacter: "⌫"
        case NSCarriageReturnCharacter: "↩"
        case NSTabCharacter: "⇥"
        default:
            switch key {
            case "{": "["
            case "}": "]"
            default: key.uppercased()
            }
        }
        // ⌘{ is ⇧⌘[ on the keyboard.
        if key == "{" || key == "}", !modifiers.contains(.shift) { text = text.replacingOccurrences(of: "⌘", with: "⇧⌘") }
        return text + glyph
    }
}

/// Bold runs for matched characters (fuzzy match positions, search snippet highlights).
public enum MatchHighlight {
    public static func attributed(
        _ text: String, positions: [Int], font: NSFont, color: NSColor = DS.Palette.text, highlightColor: NSColor? = nil
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        guard !positions.isEmpty else { return result }
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let characters = Array(text)
        var utf16Offsets: [Int] = []
        utf16Offsets.reserveCapacity(characters.count + 1)
        var offset = 0
        for character in characters {
            utf16Offsets.append(offset)
            offset += character.utf16.count
        }
        utf16Offsets.append(offset)
        for position in positions where position < characters.count {
            let range = NSRange(location: utf16Offsets[position], length: utf16Offsets[position + 1] - utf16Offsets[position])
            result.addAttribute(.font, value: bold, range: range)
            if let highlightColor { result.addAttribute(.foregroundColor, value: highlightColor, range: range) }
        }
        return result
    }

    public static func attributed(_ text: String, ranges: [Range<Int>], font: NSFont, color: NSColor = DS.Palette.secondaryText) -> NSAttributedString {
        attributed(text, positions: ranges.flatMap { Array($0) }, font: font, color: color, highlightColor: DS.Palette.text)
    }
}
