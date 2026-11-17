import AppKit
import DesignSystem
import SwiftUI

// The settings layout (visual-language.md §6, docs/design/restyle-plan.md step 10): a sidebar of panes, then grouped
// rows on raised cards. Labels are sentence case, rows are dense (28–40), controls are DesignSystem ones (switches,
// segmented pickers, outline buttons, DS select menus). No stock form, pop-up button or radio group.

/// A titled group of settings rows on a `raised` card with `border` hairlines between rows.
struct SettingsGroup<Content: View>: View {
    let title: String?
    let footer: String?
    let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s6) {
            if let title {
                Text(title).font(.ds(.labelEmph)).foregroundStyle(Color.ds.text3).padding(.leading, DS.Space.s4)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(Color.ds.raised, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(Color.ds.border, lineWidth: 1))
            if let footer {
                SettingsNote(footer).padding(.horizontal, DS.Space.s4)
            }
        }
    }
}

/// One row: a title (`body text`) with an optional detail line (`meta text3`), and a trailing control. Rows after
/// the first draw a hairline above them (`divided`).
struct SettingsRow<Trailing: View>: View {
    let title: String
    let detail: String?
    let divided: Bool
    let trailing: Trailing

    init(_ title: String, detail: String? = nil, divided: Bool = true, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.divided = divided
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.s12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ds(.body)).foregroundStyle(Color.ds.text)
                if let detail {
                    Text(detail).font(.ds(.meta)).foregroundStyle(Color.ds.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, DS.Space.s12)
        .padding(.vertical, DS.Space.s8)
        .frame(minHeight: 40)
        .overlay(alignment: .top) {
            if divided { Rectangle().fill(Color.ds.border).frame(height: 1).padding(.leading, DS.Space.s12) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A switch row (the common case).
struct SettingsToggleRow: View {
    let title: String
    let detail: String?
    let divided: Bool
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, divided: Bool = true, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self.divided = divided
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, detail: detail, divided: divided) {
            // The row's title is the label (a custom toggle style ignores `labelsHidden`).
            Toggle(isOn: $isOn) { EmptyView() }.toggleStyle(DSToggleStyle(.switch)).accessibilityLabel(title)
        }
    }
}

/// Explanatory text under a group (`meta text3`, wraps).
struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.ds(.meta)).foregroundStyle(Color.ds.text3).fixedSize(horizontal: false, vertical: true)
    }
}

/// A select (replaces `Picker(.menu)`): the current value in an outline small button with a chevron, opening a
/// native menu of the choices (the checked one marked).
struct SettingsMenuPicker<ID: Hashable>: View {
    let label: String
    let options: [(id: ID, title: String)]
    @Binding var selection: ID

    var body: some View {
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
                Text(options.first { $0.id == selection }?.title ?? "").font(.ds(.labelEmph)).foregroundStyle(Color.ds.text)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.ds.text4)
            }
            .padding(.horizontal, DS.Space.s8)
            .frame(height: DS.Size.controlSmall)
            .background(Color.ds.raised, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous).strokeBorder(Color.ds.borderStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(label)
        .accessibilityValue(options.first { $0.id == selection }?.title ?? "")
    }
}

/// Radio rows (replaces `Picker(.radioGroup)`): each choice a 28 pt row with the DS radio mark.
struct SettingsRadioRows<ID: Hashable>: View {
    let options: [(id: ID, title: String)]
    @Binding var selection: ID

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button {
                    selection = option.id
                } label: {
                    HStack(spacing: DS.Space.s8) {
                        DSToggleMark(kind: .radio, isOn: option.id == selection)
                        Text(option.title).font(.ds(.body)).foregroundStyle(Color.ds.text)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.Space.s12)
                    .frame(height: DS.Size.control + 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) {
                    if index > 0 { Rectangle().fill(Color.ds.border).frame(height: 1).padding(.leading, DS.Space.s12) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(option.id == selection ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

/// A text-size style slider row: the system slider (no DesignSystem slider yet) with the value in `meta text2`.
struct SettingsSliderRow: View {
    let title: String
    let range: ClosedRange<Double>
    let accessibilityLabel: String
    @Binding var value: Double
    var divided = true

    var body: some View {
        SettingsRow(title, divided: divided) {
            HStack(spacing: DS.Space.s8) {
                Slider(value: $value, in: range, step: 1)
                    .controlSize(.small)
                    .frame(width: 160)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityValue("\(Int(value)) points")
                Text("\(Int(value)) pt").font(.ds(.meta)).monospacedDigit().foregroundStyle(Color.ds.text2).frame(width: 36, alignment: .trailing)
            }
        }
    }
}

/// The column every pane body sits in.
struct SettingsPaneBody<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s20) { content }
            .frame(width: 520, alignment: .topLeading)
            .padding(.bottom, DS.Space.s8)
    }
}
