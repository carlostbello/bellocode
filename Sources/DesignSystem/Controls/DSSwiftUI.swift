import AppKit
import Combine
import SwiftUI

// SwiftUI mirrors of the AppKit controls, for hosted views (AgentUI cards and pickers, Orchestration panel, settings
// panes). Same recipes, same tokens. Command Line Tools have no SwiftUI macro plugin, so view-local state uses
// `@StateObject` over a tiny `ObservableObject` instead of `@State`.

@MainActor
final class DSHoverState: ObservableObject {
    @Published var isHovered = false
}

/// `Button("Allow once") {}.buttonStyle(DSButtonStyle(.primary, hint: "⌥⌘Y"))`.
public struct DSButtonStyle: ButtonStyle {
    public var variant: DSButton.Variant
    public var size: DSButton.Size
    public var hint: String?
    public var isMuted: Bool
    public var isSelected: Bool

    public init(_ variant: DSButton.Variant = .outline, size: DSButton.Size = .regular, hint: String? = nil, isMuted: Bool = false, isSelected: Bool = false) {
        self.variant = variant
        self.size = size
        self.hint = hint
        self.isMuted = isMuted
        self.isSelected = isSelected
    }

    public func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, style: self)
    }
}

private struct DSButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: DSButtonStyle

    private var title: some View {
        configuration.label
            .font(.ds(style.size == .regular ? .bodyEmph : .labelEmph))
            .lineLimit(1)
    }
    @StateObject private var hover = DSHoverState()
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = DSControlState(
            isEnabled: isEnabled, isHovered: hover.isHovered, isPressed: configuration.isPressed, isSelected: style.isSelected,
            isFocused: isFocused)
        let recipe = DSButtonRecipe(variant: style.variant, state: state, muted: style.isMuted)
        let radius = style.size == .regular ? DS.Radius.md : DS.Radius.sm
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // The hint is dropped before the title truncates (visual-language.md §6 "Buttons").
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                title.fixedSize()
                if let hint = style.hint {
                    Text(hint)
                        .font(.ds(.metaEmph))
                        .kerning(0.5)
                        .opacity(0.62)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
            }
            title
        }
        .foregroundStyle(SwiftUI.Color(nsColor: recipe.text))
        .padding(.horizontal, style.size == .regular ? DS.Space.s10 : DS.Space.s8)
        .frame(height: style.size == .regular ? DS.Size.control : DS.Size.controlSmall)
        .background(shape.fill(recipe.fill.map { SwiftUI.Color(nsColor: $0) } ?? .clear))
        .overlay(alignment: .top) {
            if recipe.topHighlight {
                shape.inset(by: 0).fill(LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.06)))
                    .allowsHitTesting(false)
            }
        }
        .overlay(shape.strokeBorder(recipe.ring.map { SwiftUI.Color(nsColor: $0) } ?? .clear, lineWidth: 1))
        .overlay(shape.strokeBorder(isFocused ? SwiftUI.Color.ds.focusRing : .clear, lineWidth: DS.Border.focusRing))
        .shadow(color: recipe.shadow && !configuration.isPressed ? SwiftUI.Color.ds.accent.opacity(0.24) : .clear, radius: 1, y: 1)
        .contentShape(shape)
        .scaleEffect(configuration.isPressed && !reduceMotion ? DS.Motion.pressScale : 1)
        .opacity(isEnabled ? 1 : DSControlState.disabledOpacity)
        .onHover { hover.isHovered = $0 }
        .focusEffectDisabled()
        .accessibilityHint(style.hint.map { "Shortcut \($0)" } ?? "")
        .transaction { $0.animation = nil }
    }
}

/// A text field without the stock bezel, for SwiftUI `TextField` and `SecureField` (the AppKit `DSTextField` recipe):
/// 28 high, `r.md`, `canvas` fill, `borderStrong` ring; focused = 1 pt accent ring + 3 pt `focusHalo`.
/// `.textFieldStyle(DSTextFieldStyle())`.
public struct DSTextFieldStyle: TextFieldStyle {
    public init() {}

    // swiftlint:disable:next identifier_name
    public func _body(configuration: TextField<_Label>) -> some View {
        configuration.modifier(DSTextFieldChrome())
    }
}

private struct DSTextFieldChrome: ViewModifier {
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
        return content
            .textFieldStyle(.plain)
            .font(.ds(.body))
            .foregroundStyle(SwiftUI.Color.ds.text)
            .focused($focused)
            .padding(.horizontal, DS.Space.s8)
            .frame(height: DS.Size.control)
            .background(shape.fill(SwiftUI.Color.ds.canvas))
            .overlay(shape.strokeBorder(focused ? SwiftUI.Color.ds.focusRing : SwiftUI.Color.ds.borderStrong, lineWidth: DS.Border.fieldFocusRing))
            .background(shape.inset(by: -DS.Border.fieldFocusHalo).fill(focused ? SwiftUI.Color.ds.focusHalo : .clear))
            .opacity(isEnabled ? 1 : DSControlState.disabledOpacity)
            .transaction { $0.animation = nil }
    }
}

/// A menu or picker row: 28 pt, `r.sm`, `fillHover` highlight on hover or when `isHighlighted`, never accent.
public struct DSMenuRowStyle: ButtonStyle {
    public var isHighlighted: Bool

    public init(isHighlighted: Bool = false) { self.isHighlighted = isHighlighted }

    public func makeBody(configuration: Configuration) -> some View {
        DSMenuRowBody(configuration: configuration, isHighlighted: isHighlighted)
    }
}

private struct DSMenuRowBody: View {
    let configuration: ButtonStyleConfiguration
    let isHighlighted: Bool
    @StateObject private var hover = DSHoverState()
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.ds(.body))
            .foregroundStyle(isEnabled ? SwiftUI.Color.ds.text : SwiftUI.Color.ds.text4)
            .padding(.horizontal, DS.Space.s8)
            .frame(minHeight: DS.Size.menuRow)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(isHighlighted || hover.isHovered || configuration.isPressed ? SwiftUI.Color.ds.fillHover : .clear))
            .contentShape(Rectangle())
            .onHover { hover.isHovered = $0 }
            .transaction { $0.animation = nil }
    }
}

/// Checkbox and switch looks for SwiftUI `Toggle` (`.toggleStyle(DSToggleStyle(.switch))`).
public struct DSToggleStyle: ToggleStyle {
    public var kind: DSToggle.Kind

    public init(_ kind: DSToggle.Kind = .checkbox) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: DS.Space.s8) {
                DSToggleMark(kind: kind, isOn: configuration.isOn)
                configuration.label.font(.ds(.body)).foregroundStyle(SwiftUI.Color.ds.text)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "on" : "off")
    }
}

/// The drawn mark of a checkbox, radio or switch.
public struct DSToggleMark: View {
    public var kind: DSToggle.Kind
    public var isOn: Bool

    public init(kind: DSToggle.Kind, isOn: Bool) {
        self.kind = kind
        self.isOn = isOn
    }

    public var body: some View {
        switch kind {
        case .checkbox:
            RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                .fill(isOn ? SwiftUI.Color.ds.accent : SwiftUI.Color.ds.canvas)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous).strokeBorder(isOn ? .clear : SwiftUI.Color.ds.borderStrong))
                .overlay { if isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(SwiftUI.Color.ds.onAccent) } }
                .frame(width: DS.Size.checkbox, height: DS.Size.checkbox)
        case .radio:
            Circle()
                .fill(isOn ? SwiftUI.Color.ds.accent : SwiftUI.Color.ds.canvas)
                .overlay(Circle().strokeBorder(isOn ? .clear : SwiftUI.Color.ds.borderStrong))
                .overlay { if isOn { Circle().fill(SwiftUI.Color.ds.onAccent).frame(width: 5, height: 5) } }
                .frame(width: DS.Size.checkbox, height: DS.Size.checkbox)
        case .switch:
            Capsule()
                .fill(isOn ? SwiftUI.Color.ds.accent : SwiftUI.Color.ds.borderStrong)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 12, height: 12).padding(2).shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
                }
                .frame(width: DS.Size.switchSize.width, height: DS.Size.switchSize.height)
        }
    }
}

/// A status, count or tag pill.
public struct DSPillView: View {
    public var title: String
    public var tone: DS.Tone
    public var symbolName: String?

    public init(_ title: String, tone: DS.Tone = .neutral, symbolName: String? = nil) {
        self.title = title
        self.tone = tone
        self.symbolName = symbolName
    }

    public var body: some View {
        let colors = DS.Color.tone(tone)
        HStack(spacing: 4) {
            if let symbolName { Image(systemName: symbolName).font(.system(size: DS.Size.iconPointMeta, weight: .semibold)) }
            Text(title).font(.ds(.metaEmph)).kerning(DS.TextRole.meta.spec.tracking)
        }
        .foregroundStyle(SwiftUI.Color(nsColor: tone == .neutral ? DS.Color.text2 : colors.text))
        .padding(.horizontal, DS.Space.s6)
        .frame(height: DS.Size.pill)
        .background(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous).fill(SwiftUI.Color(nsColor: colors.surface)))
        .accessibilityElement(children: .combine)
    }
}

/// A key cap.
public struct DSKbdView: View {
    public var keys: String

    public init(_ keys: String) { self.keys = keys }

    public var body: some View {
        Text(keys)
            .font(.ds(.metaEmph))
            .kerning(0.5)
            .foregroundStyle(SwiftUI.Color.ds.text2)
            .padding(.horizontal, 5)
            .frame(minWidth: DS.Size.kbd, minHeight: DS.Size.kbd)
            .background(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous).fill(SwiftUI.Color.ds.kbdFill))
            .accessibilityHidden(true)
    }
}

/// A segmented control (reasoning effort, layout toggles) on the `fillSubtle` track with `rowActive` thumbs.
public struct DSSegmentedPicker<ID: Hashable>: View {
    public var options: [(id: ID, title: String)]
    @Binding public var selection: ID

    public init(options: [(id: ID, title: String)], selection: Binding<ID>) {
        self.options = options
        _selection = selection
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.id) { option in
                let selected = option.id == selection
                Button { selection = option.id } label: {
                    Text(option.title)
                        .font(.ds(.labelEmph))
                        .foregroundStyle(selected ? SwiftUI.Color.ds.text : SwiftUI.Color.ds.text2)
                        .padding(.horizontal, DS.Space.s8)
                        .frame(height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                .fill(selected ? SwiftUI.Color.ds.rowActive : .clear)
                                .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous).strokeBorder(selected ? SwiftUI.Color.ds.rowRing : .clear)))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(SwiftUI.Color.ds.fillSubtle))
        .transaction { $0.animation = nil }
    }
}

extension View {
    /// The list-row background recipe (hover / selected / active, never accent).
    public func dsRowBackground(_ style: DSRowStyle, radius: CGFloat = DS.Radius.sm) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(style.fill.map { SwiftUI.Color(nsColor: $0) } ?? .clear)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(style.hasRing ? SwiftUI.Color.ds.rowRing : .clear)))
    }
}
