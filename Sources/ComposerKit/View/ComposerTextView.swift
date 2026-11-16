import AppKit

/// What the text view asks its owner. All key decisions live in the owner (`ComposerViewController`).
@MainActor
protocol ComposerTextViewOwner: AnyObject {
    /// Return or keypad Enter with these modifiers, outside composition. True when handled.
    func composerTextView(_ textView: ComposerTextView, handleReturn modifiers: KeyModifiers) -> Bool
    /// Paste or drop. True when handled (attachments or a large paste); false to insert plain text.
    func composerTextView(_ textView: ComposerTextView, read pasteboard: NSPasteboard, inline: Bool) -> Bool
    func composerTextViewFocusChanged(_ textView: ComposerTextView)
    func composerTextViewModifiersChanged(_ textView: ComposerTextView, flags: NSEvent.ModifierFlags)
}

/// The composer's `NSTextView` (TextKit 2). Native editing, input methods, services, dictation and undo come from
/// AppKit; this subclass only routes Return and paste, draws the placeholder and reports focus.
public final class ComposerTextView: NSTextView {
    weak var owner: (any ComposerTextViewOwner)?
    var placeholder = "" {
        didSet {
            setAccessibilityPlaceholderValue(placeholder)
            needsDisplay = true
        }
    }
    var placeholderColor: NSColor = .placeholderTextColor
    /// Modifiers of the key event being interpreted, for `doCommand(by:)` decisions.
    private(set) var currentKeyModifiers: NSEvent.ModifierFlags?

    static let returnKeyCodes: Set<UInt16> = [36, 76]

    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff, .string]
    }

    /// Copy and drag out as plain text: tokens become their text form, attributes never leave the composer.
    public override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    public override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        let string = string as NSString
        let text = selectedRanges.map { string.substring(with: $0.rangeValue) }.joined(separator: "\n")
        return pboard.setString(text, forType: .string)
    }

    public override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(.string) else { return false }
        pboard.declareTypes([.string], owner: nil)
        return writeSelection(to: pboard, type: .string)
    }

    public override func keyDown(with event: NSEvent) {
        currentKeyModifiers = event.modifierFlags
        defer { currentKeyModifiers = nil }
        // Command-Return is not bound to a text command; route it here unless an input method is composing.
        if Self.returnKeyCodes.contains(event.keyCode), event.modifierFlags.contains(.command), !hasMarkedText(),
           owner?.composerTextView(self, handleReturn: KeyModifiers(event.modifierFlags)) == true {
            return
        }
        super.keyDown(with: event)
    }

    /// Command-Return (and Command-Option-Return) belong to the composer while it has focus: they are handled here,
    /// before the main menu sees them as key equivalents (a host's "Send ⌘↩" or "Submit ⌥⌘↩" items), so the composer's
    /// send-key policy (send, or the alternate follow-up) applies exactly as typed.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, Self.returnKeyCodes.contains(event.keyCode), event.modifierFlags.contains(.command),
           window?.firstResponder === self, !hasMarkedText()
        {
            currentKeyModifiers = event.modifierFlags
            defer { currentKeyModifiers = nil }
            if owner?.composerTextView(self, handleReturn: KeyModifiers(event.modifierFlags)) == true { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        owner?.composerTextViewModifiersChanged(self, flags: event.modifierFlags)
    }

    // MARK: Paste and drop: plain text by default; files and images become attachments.

    public override func paste(_ sender: Any?) {
        if owner?.composerTextView(self, read: .general, inline: false) == true { return }
        pasteAsPlainText(sender)
    }

    public override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    /// Pastes text inline even when it is large (no text attachment). Hosts can bind it to a menu item.
    @objc public func pasteInline(_ sender: Any?) {
        if owner?.composerTextView(self, read: .general, inline: true) == true { return }
        pasteAsPlainText(sender)
    }

    public override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if owner?.composerTextView(self, read: pboard, inline: false) == true { return true }
        guard let string = pboard.string(forType: .string) else { return false }
        insertPlainText(string)
        return true
    }

    /// Inserts plain text at the selection as one undoable edit with the typing attributes.
    func insertPlainText(_ string: String) {
        breakUndoCoalescing()
        insertText(NSAttributedString(string: string, attributes: typingAttributes), replacementRange: selectedRange())
        breakUndoCoalescing()
    }

    // MARK: Focus

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { owner?.composerTextViewFocusChanged(self) }
        return became
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { owner?.composerTextViewFocusChanged(self) }
        return resigned
    }

    // MARK: Placeholder

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 5
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: placeholderColor,
        ]
        let rect = NSRect(x: origin.x + padding, y: origin.y, width: bounds.width - origin.x * 2 - padding * 2, height: 200)
        NSAttributedString(string: placeholder, attributes: attributes)
            .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    public override func didChangeText() {
        super.didChangeText()
        if string.isEmpty || (string as NSString).length < 2 { needsDisplay = true }
    }
}

extension KeyModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var result: KeyModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        self = result
    }
}

/// Draws a rounded background behind token runs (TextKit 2 layout fragment). Text drawing is unchanged.
final class TokenLayoutFragment: NSTextLayoutFragment {
    override func draw(at point: CGPoint, in context: CGContext) {
        if let paragraph = textElement as? NSTextParagraph {
            drawTokenBackgrounds(paragraph.attributedString, at: point, in: context)
        }
        super.draw(at: point, in: context)
    }

    private func drawTokenBackgrounds(_ text: NSAttributedString, at point: CGPoint, in context: CGContext) {
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.composerTokenBackground, in: whole) { value, range, _ in
            guard let color = value as? NSColor else { return }
            for line in textLineFragments {
                let lineRange = line.characterRange
                let start = max(range.location, lineRange.location)
                let end = min(NSMaxRange(range), NSMaxRange(lineRange))
                guard start < end else { continue }
                let startX = line.locationForCharacter(at: start).x
                let endX = line.locationForCharacter(at: end).x
                let bounds = line.typographicBounds
                let rect = NSRect(
                    x: point.x + bounds.minX + startX - 2, y: point.y + bounds.minY,
                    width: endX - startX + 4, height: bounds.height
                ).insetBy(dx: 0, dy: 0.5)
                context.saveGState()
                context.setFillColor(color.cgColor)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
                context.fillPath()
                context.restoreGState()
            }
        }
    }

    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.insetBy(dx: -3, dy: 0) }
}
