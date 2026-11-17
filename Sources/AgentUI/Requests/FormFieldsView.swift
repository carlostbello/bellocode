import AppKit
import BelloCore
import SwiftUI
import DesignSystem

/// Renders a `QuestionFormModel`: every contract field type, compact desktop controls, inline validation.
struct FormFieldsView: View {
    @Environment(\.agentUIStyle) private var style
    @Bindable var model: QuestionFormModel
    var disabled = false
    /// Opens `external` field links.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s12) {
            ForEach(model.visibleFields) { field in
                fieldView(field)
            }
        }
        .disabled(disabled)
        .noImplicitAnimation()
    }

    @ViewBuilder
    private func fieldView(_ field: QuestionField) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            if field.kind != .boolean, let title = field.title, !title.isEmpty {
                HStack(spacing: DS.Space.s4) {
                    Text(title).font(.ds(.bodyEmph)).foregroundStyle(SwiftUI.Color.ds.text)
                    if field.required { Text("required").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3) }
                }
            }
            if let detail = field.detail, !detail.isEmpty, field.kind != .boolean {
                Text(detail).font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2).fixedSize(horizontal: false, vertical: true)
            }
            control(field)
            if let error = model.visibleError(for: field) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s6) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: DS.Size.iconPointMeta)).foregroundStyle(SwiftUI.Color.ds.dangerText)
                    Text(error).font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.dangerText)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Error: \(error)")
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func control(_ field: QuestionField) -> some View {
        let key = field.key
        switch field.kind {
        case .boolean:
            Toggle(isOn: Binding(get: { model.flags[key] ?? false }, set: { model.flags[key] = $0 })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(field.title ?? key).font(.ds(.body))
                    if let detail = field.detail { Text(detail).font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2) }
                }
            }
            .toggleStyle(DSToggleStyle(.checkbox))
        case .multiselect:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(field.options, id: \.value) { option in
                    Toggle(isOn: selectionBinding(key, option.value)) { optionLabel(option) }
                        .toggleStyle(DSToggleStyle(.checkbox))
                        .frame(minHeight: DS.Size.menuRow)
                }
                if field.allowsCustom {
                    HStack(spacing: DS.Space.s8) {
                        Toggle("Other:", isOn: selectionBinding(key, QuestionFormModel.other)).toggleStyle(DSToggleStyle(.checkbox))
                        TextField("Your answer", text: textBinding(key))
                            .textFieldStyle(DSTextFieldStyle())
                            .onChange(of: model.text[key] ?? "") { _, value in
                                if !value.isEmpty { model.selections[key, default: []].insert(QuestionFormModel.other) }
                            }
                    }
                }
            }
        case .number, .integer:
            TextField(field.placeholder ?? (field.kind == .integer ? "Whole number" : "Number"), text: textBinding(key))
                .textFieldStyle(DSTextFieldStyle())
                .frame(maxWidth: 200, alignment: .leading)
                .accessibilityLabel(field.title ?? key)
        case .external:
            if let link = field.url, let url = URL(string: link) {
                Button {
                    openURL(url)
                } label: {
                    HStack(spacing: DS.Space.s4) {
                        Image(systemName: "arrow.up.right.square").font(.system(size: DS.Size.iconPointRow))
                        Text("Open \(url.host() ?? link)")
                    }
                }
                .buttonStyle(DSButtonStyle(.outline, size: .small))
                .help(link)
            }
        case .text where !field.options.isEmpty:
            // Custom radios: 28 pt rows, a 14 pt mark (ring `borderStrong`, selected `accent` with a white dot).
            VStack(alignment: .leading, spacing: 0) {
                ForEach(field.options, id: \.value) { option in
                    radio(key, value: option.value) { optionLabel(option) }
                }
                if field.allowsCustom {
                    radio(key, value: QuestionFormModel.other) { Text("Other…").font(.ds(.body)) }
                }
                if model.choice[key] == QuestionFormModel.other {
                    TextField(field.placeholder ?? "Your answer", text: textBinding(key))
                        .textFieldStyle(DSTextFieldStyle())
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(field.title ?? key)
        default:
            if QuestionFormModel.isSecret(field) {
                SecureField(field.placeholder ?? "", text: textBinding(key))
                    .textFieldStyle(DSTextFieldStyle())
                    .accessibilityLabel(field.title ?? key)
            } else {
                TextField(field.placeholder ?? "", text: textBinding(key))
                    .textFieldStyle(DSTextFieldStyle())
                    .accessibilityLabel(field.title ?? key)
            }
        }
    }

    private func optionLabel(_ option: QuestionField.Option) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s8) {
            Text(option.label).font(.ds(.body)).foregroundStyle(SwiftUI.Color.ds.text)
            if let detail = option.detail, !detail.isEmpty {
                Text(detail).font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3)
            }
        }
    }

    /// One radio row (single choice).
    private func radio<Label: View>(_ key: String, value: String, @ViewBuilder label: () -> Label) -> some View {
        let selected = model.choice[key] == value
        return Button {
            model.choice[key] = value
        } label: {
            HStack(spacing: DS.Space.s8) {
                DSToggleMark(kind: .radio, isOn: selected)
                label()
            }
            .frame(minHeight: DS.Size.menuRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
        .accessibilityValue(selected ? "selected" : "")
    }

    private func textBinding(_ key: String) -> Binding<String> {
        Binding(get: { model.text[key] ?? "" }, set: { model.text[key] = $0 })
    }

    private func choiceBinding(_ key: String) -> Binding<String?> {
        Binding(get: { model.choice[key] }, set: { model.choice[key] = $0 })
    }

    private func selectionBinding(_ key: String, _ value: String) -> Binding<Bool> {
        Binding(
            get: { model.selections[key]?.contains(value) ?? false },
            set: { on in
                if on { model.selections[key, default: []].insert(value) } else { model.selections[key]?.remove(value) }
            })
    }
}
