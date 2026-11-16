import AppKit
import SwiftUI

/// Visual parameters for every AgentUI view, injected by the host (DesignSystem maps its tokens onto this). Defaults
/// are system-semantic, so the views follow light/dark, accent colour, increased contrast and Dynamic Type sizes.
public struct AgentUIStyle: Sendable {
    public var accent: Color
    /// Card and popover surfaces.
    public var surface: Color
    /// Insets inside cards: code blocks, field backgrounds.
    public var inset: Color
    public var separator: Color
    public var primaryText: Color
    public var secondaryText: Color
    /// Approvals and anything needing the user.
    public var attention: Color
    public var danger: Color
    public var success: Color

    public var bodyFont: Font
    public var smallFont: Font
    public var titleFont: Font
    public var monospacedFont: Font

    public var cornerRadius: CGFloat
    /// Base spacing unit (desktop density: 4 pt).
    public var spacing: CGFloat
    /// Height of a list row in pickers.
    public var rowHeight: CGFloat

    public init(
        accent: Color = .accentColor,
        surface: Color = Color(nsColor: .controlBackgroundColor),
        inset: Color = Color(nsColor: .textBackgroundColor),
        separator: Color = Color(nsColor: .separatorColor),
        primaryText: Color = Color(nsColor: .labelColor),
        secondaryText: Color = Color(nsColor: .secondaryLabelColor),
        attention: Color = Color(nsColor: .systemOrange),
        danger: Color = Color(nsColor: .systemRed),
        success: Color = Color(nsColor: .systemGreen),
        bodyFont: Font = .system(size: NSFont.systemFontSize),
        smallFont: Font = .system(size: NSFont.smallSystemFontSize),
        titleFont: Font = .system(size: NSFont.systemFontSize, weight: .semibold),
        monospacedFont: Font = .system(size: NSFont.smallSystemFontSize + 0.5, design: .monospaced),
        cornerRadius: CGFloat = 8,
        spacing: CGFloat = 4,
        rowHeight: CGFloat = 24
    ) {
        self.accent = accent
        self.surface = surface
        self.inset = inset
        self.separator = separator
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.attention = attention
        self.danger = danger
        self.success = success
        self.bodyFont = bodyFont
        self.smallFont = smallFont
        self.titleFont = titleFont
        self.monospacedFont = monospacedFont
        self.cornerRadius = cornerRadius
        self.spacing = spacing
        self.rowHeight = rowHeight
    }

    public static let standard = AgentUIStyle()
}

private struct AgentUIStyleKey: EnvironmentKey {
    static let defaultValue = AgentUIStyle.standard
}

extension EnvironmentValues {
    /// The style AgentUI views draw with.
    public var agentUIStyle: AgentUIStyle {
        get { self[AgentUIStyleKey.self] }
        set { self[AgentUIStyleKey.self] = newValue }
    }
}

/// A keyboard shortcut shown on a control and offered to the host for its menus.
public struct AgentShortcut: Hashable, Sendable {
    public var key: String
    public var modifiers: NSEvent.ModifierFlags.RawValue

    public init(_ key: String, _ modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers.rawValue
    }

    public var keyEquivalent: KeyEquivalent {
        switch key {
        case "↩": .return
        case "⎋": .escape
        default: KeyEquivalent(Character(key))
        }
    }

    public var eventModifiers: EventModifiers {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var result: EventModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }

    /// As shown in menus: ⌃⌥⇧⌘ order.
    public var display: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key.uppercased()
    }

    /// The menu item key equivalent string for `NSMenuItem`.
    public var menuKeyEquivalent: String { key == "↩" ? "\r" : key }
    public var menuModifierMask: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    // Approvals: none of these is in the proposed map (docs/research/03-ux-patterns.md section D), none is a bare key,
    // and Escape never approves.
    public static let allowOnce = AgentShortcut("y", [.command, .option])
    public static let allowAlways = AgentShortcut("y", [.command, .option, .shift])
    public static let deny = AgentShortcut("n", [.command, .option])
    public static let submitAnswer = AgentShortcut("↩", [.command, .option])
    public static let previousRequest = AgentShortcut("[", [.command, .option])
    public static let nextRequest = AgentShortcut("]", [.command, .option])
    public static let modelPicker = AgentShortcut("m", [.command, .shift])
    public static let permissionMode = AgentShortcut("a", [.command, .shift])
    public static let togglePlan = AgentShortcut("p", [.command, .option])
}

extension View {
    func keyboardShortcut(_ shortcut: AgentShortcut?) -> some View {
        modifier(OptionalShortcut(shortcut: shortcut))
    }
}

private struct OptionalShortcut: ViewModifier {
    let shortcut: AgentShortcut?

    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.eventModifiers)
        } else {
            content
        }
    }
}

/// A small key-cap label showing a shortcut next to a button title.
struct KeyCap: View {
    @Environment(\.agentUIStyle) private var style
    let shortcut: AgentShortcut

    var body: some View {
        Text(shortcut.display)
            .font(.system(size: NSFont.smallSystemFontSize - 1, weight: .medium, design: .rounded))
            .foregroundStyle(style.secondaryText)
            .accessibilityHidden(true)
    }
}

/// Removes implicit animation from streaming and layout updates (engineering rule 17).
extension View {
    func noImplicitAnimation() -> some View { transaction { $0.animation = nil } }
}

/// View-local state. Command Line Tools ship no SwiftUI macro plugin, so `@State` (a macro in this SDK) cannot be
/// compiled here; `@StateObject private var x = ViewState(value)` with `x.value` / `$x.value` replaces it.
@MainActor
final class ViewState<Value>: ObservableObject {
    @Published var value: Value

    init(_ value: Value) { self.value = value }
}
