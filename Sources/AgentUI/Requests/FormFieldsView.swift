import AppKit
import BelloCore
import SwiftUI

/// Renders a `QuestionFormModel`: every contract field type, compact desktop controls, inline validation.
struct FormFieldsView: View {
    @Environment(\.agentUIStyle) private var style
    @Bindable var model: QuestionFormModel
    var disabled = false
    /// Opens `external` field links.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    var body: some View {
        VStack(alignment: .leading, spacing: style.spacing * 3) {
            ForEach(model.visibleFields) { field in
                fieldView(field)
            }
        }
        .disabled(disabled)
        .noImplicitAnimation()
    }

    @ViewBuilder
    private func fieldView(_ field: QuestionField) -> some View {
        VStack(alignment: .leading, spacing: style.spacing) {
            if field.kind != .boolean, let title = field.title, !title.isEmpty {
                HStack(spacing: 2) {
                    Text(title).font(style.bodyFont.weight(.medium)).foregroundStyle(style.primaryText)
                    if field.required { Text("(required)").font(style.smallFont).foregroundStyle(style.secondaryText) }
                }
            }
            if let detail = field.detail, !detail.isEmpty, field.kind != .boolean {
                Text(detail).font(style.smallFont).foregroundStyle(style.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            control(field)
            if let error = model.visibleError(for: field) {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(style.smallFont)
                    .foregroundStyle(style.danger)
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
                    Text(field.title ?? key).font(style.bodyFont)
                    if let detail = field.detail { Text(detail).font(style.smallFont).foregroundStyle(style.secondaryText) }
                }
            }
            .toggleStyle(.checkbox)
        case .multiselect:
            VStack(alignment: .leading, spacing: style.spacing) {
                ForEach(field.options, id: \.value) { option in
                    Toggle(isOn: selectionBinding(key, option.value)) { optionLabel(option) }
                        .toggleStyle(.checkbox)
                }
                if field.allowsCustom {
                    HStack(spacing: style.spacing * 2) {
                        Toggle("Other:", isOn: selectionBinding(key, QuestionFormModel.other)).toggleStyle(.checkbox)
                        TextField("Your answer", text: textBinding(key))
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: model.text[key] ?? "") { _, value in
                                if !value.isEmpty { model.selections[key, default: []].insert(QuestionFormModel.other) }
                            }
                    }
                }
            }
        case .number, .integer:
            TextField(field.placeholder ?? (field.kind == .integer ? "Whole number" : "Number"), text: textBinding(key))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200, alignment: .leading)
                .accessibilityLabel(field.title ?? key)
        case .external:
            if let link = field.url, let url = URL(string: link) {
                Button {
                    openURL(url)
                } label: {
                    Label("Open \(url.host() ?? link)", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
                .help(link)
            }
        case .text where !field.options.isEmpty:
            VStack(alignment: .leading, spacing: style.spacing) {
                Picker(field.title ?? key, selection: choiceBinding(key)) {
                    ForEach(field.options, id: \.value) { option in
                        optionLabel(option).tag(Optional(option.value))
                    }
                    if field.allowsCustom { Text("Other…").tag(Optional(QuestionFormModel.other)) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if model.choice[key] == QuestionFormModel.other {
                    TextField(field.placeholder ?? "Your answer", text: textBinding(key))
                        .textFieldStyle(.roundedBorder)
                }
            }
        default:
            if QuestionFormModel.isSecret(field) {
                SecureField(field.placeholder ?? "", text: textBinding(key))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(field.title ?? key)
            } else {
                TextField(field.placeholder ?? "", text: textBinding(key))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(field.title ?? key)
            }
        }
    }

    private func optionLabel(_ option: QuestionField.Option) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: style.spacing * 2) {
            Text(option.label).font(style.bodyFont)
            if let detail = option.detail, !detail.isEmpty {
                Text(detail).font(style.smallFont).foregroundStyle(style.secondaryText)
            }
        }
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
