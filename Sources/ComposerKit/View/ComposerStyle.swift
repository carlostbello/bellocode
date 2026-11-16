import AppKit

/// The composer's look, injected by the shell (normally built from DesignSystem tokens). Defaults are system-semantic
/// colours and fonts, so the composer is correct in light, dark and increased contrast without any tokens.
public struct ComposerStyle {
    public var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    public var textColor: NSColor = .textColor
    public var placeholderColor: NSColor = .placeholderTextColor
    public var secondaryTextColor: NSColor = .secondaryLabelColor
    public var cardBackgroundColor: NSColor = .textBackgroundColor
    public var borderColor: NSColor = .separatorColor
    public var focusBorderColor: NSColor = .keyboardFocusIndicatorColor
    public var accentColor: NSColor = .controlAccentColor
    public var tokenTextColor: NSColor = .linkColor
    public var tokenBackgroundColor: NSColor = .controlAccentColor.withAlphaComponent(0.13)
    public var chipBackgroundColor: NSColor = .quaternarySystemFill
    public var errorColor: NSColor = .systemRed
    public var popoverBackgroundColor: NSColor = .controlBackgroundColor
    public var selectionRowColor: NSColor = .selectedContentBackgroundColor

    public var cornerRadius: CGFloat = 10
    /// Padding inside the card around the text and controls.
    public var contentInsets = NSEdgeInsets(top: 8, left: 10, bottom: 6, right: 6)
    /// Height of the text area when empty, in lines (1 docked, 3 for the "hero" composer).
    public var minimumLines = 1
    /// Cap on the text area height as a fraction of the window's content height; it scrolls beyond that.
    public var maximumHeightFraction: CGFloat = 0.4
    public var chipHeight: CGFloat = 26
    public var controlHeight: CGFloat = 24
    public var completionRowHeight: CGFloat = 24
    public var completionWidth: CGFloat = 380
    public var completionMaxVisibleRows = 8
    public var placeholder = "Ask anything. @ to mention files, / for commands"

    public init() {}

    /// Stronger borders when the user asked for increased contrast.
    var increasedContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    var borderWidth: CGFloat { increasedContrast ? 1.5 : 1 }
}

/// Behaviour settings.
public struct ComposerConfiguration {
    public enum SpellChecking: Hashable, Sendable {
        /// On for prose, off while the draft looks like code.
        case automatic
        case on
        case off
    }

    public var sendKey: SendKey = .returnKey
    /// `@` files, `/` commands, …
    public var completionProviders: [any CompletionProvider] = []
    public var completionDebounce: Duration = .milliseconds(40)
    public var attachmentLimits = AttachmentLimits()
    public var spellChecking: SpellChecking = .automatic
    public var draftSaveDelay: Duration = .milliseconds(150)
    /// Insert prompts longer than this as the user typed them; the host validates the limit (T3 Code: 120,000).
    public var maximumPromptLength = 120_000

    public init() {}
}
