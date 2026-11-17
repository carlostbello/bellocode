import AppKit
import SwiftUI
import DesignSystem

/// Visual parameters for AgentUI views, injected by the host. Defaults are the DesignSystem tokens
/// (visual-language.md); the request cards, pickers and composer controls read DesignSystem directly, so they match
/// the spec whatever a host passes here.
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
        accent: Color = Color(nsColor: DS.Color.accent),
        surface: Color = Color(nsColor: DS.Color.raised),
        inset: Color = Color(nsColor: DS.Color.codeFill),
        separator: Color = Color(nsColor: DS.Color.border),
        primaryText: Color = Color(nsColor: DS.Color.text),
        secondaryText: Color = Color(nsColor: DS.Color.text2),
        attention: Color = Color(nsColor: DS.Color.warningText),
        danger: Color = Color(nsColor: DS.Color.dangerText),
        success: Color = Color(nsColor: DS.Color.successText),
        bodyFont: Font = DS.TextRole.body.swiftUIFont(base: DS.TextRole.defaultBase),
        smallFont: Font = DS.TextRole.label.swiftUIFont(base: DS.TextRole.defaultBase),
        titleFont: Font = DS.TextRole.title.swiftUIFont(base: DS.TextRole.defaultBase),
        monospacedFont: Font = .system(size: 12, design: .monospaced),
        cornerRadius: CGFloat = DS.Radius.md,
        spacing: CGFloat = DS.Space.s4,
        rowHeight: CGFloat = DS.Size.menuRow
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

private struct AgentUIAttachedOverlapKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// How far the host overlaps the composer onto the request card (T3's attached look, visual-language.md §6); the
    /// card adds this much room under its content. 0 when the card stands alone above the composer.
    public var agentUIAttachedOverlap: CGFloat {
        get { self[AgentUIAttachedOverlapKey.self] }
        set { self[AgentUIAttachedOverlapKey.self] = newValue }
    }

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
    let shortcut: AgentShortcut

    var body: some View { DSKbdView(shortcut.display) }
}

/// A 1 pt `border` divider (replaces SwiftUI's `Divider`, which draws the system separator colour).
struct DSHairline: View {
    var body: some View {
        SwiftUI.Color.ds.border.frame(height: 1).frame(maxWidth: .infinity).accessibilityHidden(true)
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

/// Lets a host open a control's popover from a menu item (for example "Permission Mode…" in the Thread menu):
/// each `fire()` toggles the popover open once.
@MainActor
public final class PopoverTrigger: ObservableObject {
    @Published public private(set) var count = 0

    public init() {}

    public func fire() { count += 1 }
}
