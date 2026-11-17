import AppKit
import DesignSystem

/// The composer's look. Behaviour fields (`minimumLines`, `maximumHeightFraction`, `placeholder`, completion sizing) are
/// the host's to set. Every colour, font and metric is taken from DesignSystem when the composer draws
/// (`resolvedWithDesignTokens()`, visual-language.md §6 "Composer"), so a host that still passes older values gets the
/// spec anyway; the visual fields stay for source compatibility and default to the same tokens.
public struct ComposerStyle {
    public var font: NSFont = .systemFont(ofSize: 14)
    public var textColor: NSColor = DS.Color.text
    public var placeholderColor: NSColor = DS.Color.placeholder
    public var secondaryTextColor: NSColor = DS.Color.text3
    public var cardBackgroundColor: NSColor = DS.Color.raised
    public var borderColor: NSColor = DS.Color.border
    public var focusBorderColor: NSColor = DS.Color.borderStrong
    public var accentColor: NSColor = DS.Color.accent
    public var tokenTextColor: NSColor = DS.Color.infoText
    public var tokenBackgroundColor: NSColor = DS.Color.infoSurface
    public var chipBackgroundColor: NSColor = DS.Color.fillHover
    public var errorColor: NSColor = DS.Color.dangerText
    public var popoverBackgroundColor: NSColor = DS.Color.raised
    public var selectionRowColor: NSColor = DS.Color.highlight

    /// `r.xl`.
    public var cornerRadius: CGFloat = DS.Radius.xl
    /// Prompt inset 12 / 14 / 4; the controls bar sits 8 from the sides and bottom.
    public var contentInsets = NSEdgeInsets(top: 12, left: 14, bottom: 8, right: 14)
    /// Height of the text area when empty, in lines (1 docked, 3 for the "hero" composer).
    public var minimumLines = 1
    /// Cap on the text area height as a fraction of the window's content height; it scrolls beyond that.
    public var maximumHeightFraction: CGFloat = 0.4
    public var chipHeight: CGFloat = DS.Size.control
    /// Composer controls are 26 high.
    public var controlHeight: CGFloat = DS.Size.composerControl
    public var completionRowHeight: CGFloat = DS.Size.menuRow
    public var completionWidth: CGFloat = 380
    public var completionMaxVisibleRows = 8
    public var placeholder = "Ask anything. @ to mention files, / for commands"
    /// Prompt line height (`composer` 14 / 21 at the default text size).
    public var lineHeight: CGFloat = 21
    /// Inset of the controls bar from the card's sides and bottom.
    public var controlsInset: CGFloat = DS.Space.s8

    public init() {}

    /// This style with every visual field taken from DesignSystem at the app's current text size; behaviour fields
    /// are kept.
    @MainActor public func resolvedWithDesignTokens() -> ComposerStyle {
        var style = self
        style.font = DS.TextRole.composer.font
        style.lineHeight = DS.TextRole.composer.lineHeight
        style.textColor = DS.Color.text
        style.placeholderColor = DS.Color.placeholder
        style.secondaryTextColor = DS.Color.text3
        style.cardBackgroundColor = DS.Color.raised
        style.borderColor = DS.Color.border
        style.focusBorderColor = DS.Color.borderStrong
        style.accentColor = DS.Color.accent
        style.tokenTextColor = DS.Color.infoText
        style.tokenBackgroundColor = DS.Color.infoSurface
        style.chipBackgroundColor = DS.Color.fillHover
        style.errorColor = DS.Color.dangerText
        style.popoverBackgroundColor = DS.Color.raised
        style.selectionRowColor = DS.Color.highlight
        style.cornerRadius = DS.Radius.xl
        style.contentInsets = NSEdgeInsets(top: 12, left: 14, bottom: 8, right: 14)
        style.chipHeight = DS.Size.control
        style.controlHeight = DS.Size.composerControl
        style.completionRowHeight = DS.Size.menuRow
        style.controlsInset = DS.Space.s8
        return style
    }

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
