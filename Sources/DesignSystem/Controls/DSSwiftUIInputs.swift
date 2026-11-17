import AppKit
import SwiftUI

// SwiftUI inputs the spec implies but AppKit hosts rarely need: a select (menu in an outline small button), a
// stepper, a slider and a determinate progress bar. Same tokens and states as the AppKit controls (visual-language.md
// §6 "Inputs, toggles"): `borderStrong` rings, `fillSubtle` tracks, `accent` for the value, disabled at 64 %, a 2 pt
// accent focus ring for keyboard focus, no implicit animation.

/// A select (replaces `Picker(.menu)` and `NSPopUpButton`): the current value in an outline small button with
/// `chevron.up.chevron.down`, opening a native menu of the choices (the current one checked; plain menus stay native).
public struct DSMenuSelect<ID: Hashable>: View {
    public var label: String
    public var options: [(id: ID, title: String)]
    @Binding public var selection: ID
    public var minWidth: CGFloat?

    public init(_ label: String, options: [(id: ID, title: String)], selection: Binding<ID>, minWidth: CGFloat? = nil) {
        self.label = label
        self.options = options
        _selection = selection
        self.minWidth = minWidth
    }

    public var body: some View {
        let current = options.first { $0.id == selection }?.title ?? ""
        Menu {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button {
                    selection = option.id
                } label: {
                    if option.id == selection { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
        } label: {
            HStack(spacing: DS.Space.s6) {
                Text(current).font(.ds(.labelEmph)).foregroundStyle(SwiftUI.Color.ds.text).lineLimit(1).truncationMode(.middle)
                if minWidth != nil { Spacer(minLength: 0) }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(SwiftUI.Color.ds.text4)
            }
            .padding(.horizontal, DS.Space.s8)
            .frame(minWidth: minWidth, minHeight: DS.Size.controlSmall, maxHeight: DS.Size.controlSmall)
            .background(SwiftUI.Color.ds.raised, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous).strokeBorder(SwiftUI.Color.ds.borderStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(label)
        .accessibilityValue(current)
    }
}

/// A stepper (replaces `Stepper`): the value as text, then − and + small ghost icon buttons in one outline group.
/// ↑/↓ step while focused; VoiceOver adjusts it.
public struct DSStepper: View {
    public var label: String
    @Binding public var value: Int
    public var range: ClosedRange<Int>
    public var step: Int
    public var format: (Int) -> String

    public init(_ label: String, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1, format: @escaping (Int) -> String = { "\($0)" }) {
        self.label = label
        _value = value
        self.range = range
        self.step = step
        self.format = format
    }

    private func change(_ delta: Int) { value = min(max(value + delta, range.lowerBound), range.upperBound) }

    public var body: some View {
        HStack(spacing: 0) {
            Text(format(value)).font(.ds(.label).monospacedDigit()).foregroundStyle(SwiftUI.Color.ds.text)
                .padding(.horizontal, DS.Space.s8)
                .frame(minWidth: 48, alignment: .leading)
            SwiftUI.Color.ds.border.frame(width: 1, height: DS.Size.controlSmall - 8)
            Button { change(-step) } label: { Image(systemName: "minus").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                .disabled(value <= range.lowerBound)
                .accessibilityLabel("Decrease")
            Button { change(step) } label: { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                .disabled(value >= range.upperBound)
                .accessibilityLabel("Increase")
        }
        .frame(height: DS.Size.controlSmall)
        .background(SwiftUI.Color.ds.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous).strokeBorder(SwiftUI.Color.ds.borderStrong, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: change(step)
            case .decrement: change(-step)
            @unknown default: break
            }
        }
        .transaction { $0.animation = nil }
    }
}

/// A slider (replaces `Slider`): 4 pt `fillSubtle` track with a `border` ring, the value part in `accent`, a 14 pt
/// white knob with a `borderStrong` ring and a small shadow. Drag or click to set; ←/→ step while focused (Full
/// Keyboard Access), VoiceOver adjusts it. Values snap to `step`.
public struct DSSlider: View {
    @Binding public var value: Double
    public var range: ClosedRange<Double>
    public var step: Double
    @FocusState private var focused: Bool

    public init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1) {
        _value = value
        self.range = range
        self.step = step
    }

    private var fraction: CGFloat {
        CGFloat((value - range.lowerBound) / max(range.upperBound - range.lowerBound, .ulpOfOne))
    }

    private func set(_ raw: Double) {
        let snapped = (raw / step).rounded() * step
        value = min(max(snapped, range.lowerBound), range.upperBound)
    }

    public var body: some View {
        GeometryReader { geometry in
            let knob: CGFloat = 14
            let width = max(geometry.size.width - knob, 1)
            let x = fraction * width
            ZStack(alignment: .leading) {
                Capsule().fill(SwiftUI.Color.ds.fillSubtle)
                    .overlay(Capsule().strokeBorder(SwiftUI.Color.ds.border, lineWidth: 1))
                    .frame(height: 4)
                    .padding(.horizontal, knob / 2)
                Capsule().fill(SwiftUI.Color.ds.accent)
                    .frame(width: x + 2, height: 4)
                    .padding(.leading, knob / 2)
                Circle().fill(.white)
                    .overlay(Circle().strokeBorder(SwiftUI.Color.ds.borderStrong, lineWidth: 1))
                    .overlay(Circle().strokeBorder(focused ? SwiftUI.Color.ds.focusRing : .clear, lineWidth: DS.Border.focusRing).padding(-3))
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let position = min(max((drag.location.x - knob / 2) / width, 0), 1)
                set(range.lowerBound + Double(position) * (range.upperBound - range.lowerBound))
            })
        }
        .frame(height: DS.Size.micro)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { set(value - step); return .handled }
        .onKeyPress(.rightArrow) { set(value + step); return .handled }
        .accessibilityElement()
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityValue("\(value.formatted())")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(value + step)
            case .decrement: set(value - step)
            @unknown default: break
            }
        }
        .transaction { $0.animation = nil }
    }
}

/// A determinate progress bar (replaces `ProgressView(value:)`): 4 pt `fillSubtle` track with a `border` ring and the
/// done part in `accent`. Indeterminate work uses `DSSpinner` / `StatusLabel(.running)` instead.
public struct DSProgressBar: View {
    public var value: Double

    public init(value: Double) { self.value = min(max(value, 0), 1) }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(SwiftUI.Color.ds.fillSubtle).overlay(Capsule().strokeBorder(SwiftUI.Color.ds.border, lineWidth: 1))
                Capsule().fill(SwiftUI.Color.ds.accent).frame(width: max(4, geometry.size.width * value))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityValue("\(Int(value * 100)) percent")
        .transaction { $0.animation = nil }
    }
}
