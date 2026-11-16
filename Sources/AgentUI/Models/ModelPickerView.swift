import AppKit
import BelloCore
import Engine
import SwiftUI

/// The composer's model button: current model and effort, opening the picker popover (⇧⌘M).
public struct ModelPickerButton: View {
    @Environment(\.agentUIStyle) private var style
    @Bindable var model: ModelPickerModel
    @StateObject private var isOpen = ViewState(false)

    public init(model: ModelPickerModel) {
        self.model = model
    }

    public var body: some View {
        Button {
            if !isOpen.value { model.prepareForOpen() }
            isOpen.value.toggle()
        } label: {
            HStack(spacing: 4) {
                if model.pending != nil {
                    ProgressView().controlSize(.mini).accessibilityLabel("Switching model")
                } else if model.error != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(style.danger)
                }
                Text(model.selectedModel?.name ?? model.selection?.modelID ?? "Choose model").lineLimit(1)
                if let variant = model.selection?.variant {
                    Text(variant).foregroundStyle(style.secondaryText)
                }
                Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(style.secondaryText)
            }
            .font(style.smallFont)
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.modelPicker)
        .help(model.error.map { "The model was not changed: \($0)" } ?? "Choose model (\(AgentShortcut.modelPicker.display))")
        .accessibilityLabel("Model")
        .accessibilityValue(
            [model.selectedModel?.name ?? model.selection?.modelID, model.selection?.variant].compactMap { $0 }.joined(separator: ", "))
        .popover(isPresented: $isOpen.value, arrowEdge: .top) {
            ModelPickerView(model: model) { isOpen.value = false }
        }
    }
}

/// Picker content: search field (focused), grouped list, keyboard hints.
public struct ModelPickerView: View {
    @Environment(\.agentUIStyle) private var style
    @Bindable var model: ModelPickerModel
    let close: () -> Void
    @FocusState private var searchFocused: Bool

    public init(model: ModelPickerModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 420)
        .frame(minHeight: 200, maxHeight: 460)
        .noImplicitAnimation()
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: style.spacing * 2) {
            Image(systemName: "magnifyingglass").foregroundStyle(style.secondaryText).accessibilityHidden(true)
            TextField("Search models", text: $model.query)
                .textFieldStyle(.plain)
                .font(style.bodyFont)
                .focused($searchFocused)
                .onKeyPress(.downArrow) { model.moveHighlight(1); return .handled }
                .onKeyPress(.upArrow) { model.moveHighlight(-1); return .handled }
                .onKeyPress(keys: [.tab], phases: .down) { press in
                    model.cycleVariant(press.modifiers.contains(.shift) ? -1 : 1)
                    return .handled
                }
                .onKeyPress(.return) {
                    if model.chooseHighlighted() { close() }
                    return .handled
                }
                .onKeyPress(.escape) { close(); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "d"), phases: .down) { press in
                    guard press.modifiers == .command, let row = model.highlightedRow?.model else { return .ignored }
                    model.toggleFavourite(row)
                    return .handled
                }
                .accessibilityLabel("Search models")
            Button {
                Task { await model.refresh() }
            } label: {
                if model.isRefreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)
            .help("Refresh models")
            .accessibilityLabel("Refresh models")
            Toggle(isOn: $model.showsHidden) { Image(systemName: "eye") }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help(model.showsHidden ? "Hide hidden models" : "Show hidden models")
                .accessibilityLabel("Show hidden models")
        }
        .padding(.horizontal, style.spacing * 3)
        .padding(.vertical, style.spacing * 2)
    }

    private var list: some View {
        let sections = model.sections
        let highlighted = model.highlightedRow?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    if sections.allSatisfy({ $0.id == "connect" }) && !model.query.isEmpty {
                        Text("No models match “\(model.query)”.")
                            .font(style.smallFont).foregroundStyle(style.secondaryText)
                            .padding(.horizontal, style.spacing * 3).padding(.vertical, style.spacing * 2)
                    }
                    ForEach(sections) { section in
                        Text(section.title)
                            .font(style.smallFont.weight(.semibold))
                            .foregroundStyle(style.secondaryText)
                            .padding(.horizontal, style.spacing * 3)
                            .padding(.top, style.spacing * 2.5)
                            .padding(.bottom, style.spacing)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.rows) { row in
                            ModelPickerRow(model: model, row: row, isHighlighted: row.id == highlighted) {
                                if model.choose(row) { close() }
                            }
                            .id(row.id)
                        }
                    }
                }
                .padding(.bottom, style.spacing * 2)
            }
            .onChange(of: highlighted) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .onAppear {
                if let highlighted { proxy.scrollTo(highlighted, anchor: .center) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: style.spacing * 3) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(style.danger).lineLimit(1)
            } else {
                Text("↑↓ select").accessibilityHidden(true)
                Text("⇥ effort").accessibilityHidden(true)
                Text("⌘D favourite").accessibilityHidden(true)
                Text("↩ choose").accessibilityHidden(true)
                Spacer()
                Text("esc close").accessibilityHidden(true)
            }
        }
        .font(style.smallFont)
        .foregroundStyle(style.secondaryText)
        .padding(.horizontal, style.spacing * 3)
        .padding(.vertical, style.spacing * 1.5)
    }
}

struct ModelPickerRow: View {
    @Environment(\.agentUIStyle) private var style
    let model: ModelPickerModel
    let row: ModelPickerModel.Row
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, style.spacing * 2)
                .frame(minHeight: style.rowHeight)
                .contentShape(Rectangle())
                .background(
                    isHighlighted ? style.accent.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, style.spacing)
        }
        .buttonStyle(.plain)
        .disabled(!row.isEnabled)
        .onHover { if $0, row.isEnabled { model.highlightedID = row.id } }
        .contextMenu { contextMenu }
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    @ViewBuilder
    private var content: some View {
        switch row.kind {
        case .model(let entry, let providerName):
            modelContent(entry, providerName: providerName)
        case .connect(_, let name):
            HStack(spacing: style.spacing * 2) {
                Image(systemName: "bolt.horizontal.circle").foregroundStyle(style.secondaryText).frame(width: 14)
                Text(name).foregroundStyle(style.secondaryText)
                Text("not connected").font(style.smallFont).foregroundStyle(style.secondaryText.opacity(0.8))
                Spacer()
                Text("Connect…").font(style.smallFont.weight(.medium)).foregroundStyle(style.accent)
            }
            .font(style.bodyFont)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(name), not connected. Connect.")
        case .connectOther:
            HStack(spacing: style.spacing * 2) {
                Image(systemName: "plus.circle").foregroundStyle(style.accent).frame(width: 14)
                Text("Connect another provider…").foregroundStyle(style.accent)
                Spacer()
            }
            .font(style.bodyFont)
        }
    }

    private func modelContent(_ entry: ModelEntry, providerName: String) -> some View {
        let selection = model.selection
        let isSelected = selection?.providerID == entry.providerID && selection?.modelID == entry.modelID
        let isFavourite = model.preferences.value.isFavourite(entry.id)
        let isHidden = model.preferences.value.hidden.contains(entry.id)
        let variant = model.variant(for: entry)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: style.spacing * 2) {
                ZStack {
                    Color.clear
                    if isSelected {
                        Image(systemName: "checkmark").foregroundStyle(style.accent)
                    } else if isFavourite {
                        Image(systemName: "star.fill").foregroundStyle(style.attention)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
                Text(entry.name)
                    .foregroundStyle(row.isEnabled ? style.primaryText : style.secondaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
                if model.query.isEmpty == false || isFavouriteSection {
                    Text(providerName).font(style.smallFont).foregroundStyle(style.secondaryText).lineLimit(1)
                }
                if entry.status != "active" { Tag(text: entry.status).fixedSize() }
                if isHidden { Tag(text: "hidden").fixedSize() }
                if let variant, !isHighlighted { Tag(text: variant).fixedSize() }
                Spacer(minLength: style.spacing)
                hints(entry).fixedSize()
            }
            // The effort choices of the highlighted model, on their own line (⇥ cycles them).
            if isHighlighted, !entry.variants.isEmpty {
                HStack(spacing: style.spacing * 2) {
                    Color.clear.frame(width: 14, height: 1)
                    Text("Effort").font(style.smallFont).foregroundStyle(style.secondaryText)
                    variantChips(entry, selected: variant)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 3)
            }
        }
        .font(style.bodyFont)
        .help(row.disabledReason ?? help(entry, providerName: providerName))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(entry, providerName: providerName, variant: variant, selected: isSelected))
    }

    private var isFavouriteSection: Bool { row.id.hasPrefix("favourites|") || row.id.hasPrefix("recent|") }

    private func variantChips(_ entry: ModelEntry, selected: String?) -> some View {
        HStack(spacing: 2) {
            // Not buttons: a button inside the row's button breaks the row's layout on macOS.
            ForEach([nil] + entry.variants.map(Optional.some), id: \.self) { variant in
                Text(variant ?? "default")
                    .font(.system(size: NSFont.smallSystemFontSize - 1))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        variant == selected ? style.accent.opacity(0.25) : style.separator.opacity(0.25),
                        in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(variant == selected ? style.primaryText : style.secondaryText)
                    .contentShape(Rectangle())
                    .onTapGesture { model.setVariant(variant, for: entry) }
                    .help("Effort: \(variant ?? "model default")")
            }
        }
        .fixedSize()
    }

    private func hints(_ entry: ModelEntry) -> some View {
        HStack(spacing: style.spacing * 1.5) {
            if entry.inputModalities.contains("image") {
                Image(systemName: "photo").help("Accepts images").accessibilityHidden(true)
            }
            if !entry.supportsTools {
                Image(systemName: "wrench.and.screwdriver").symbolVariant(.slash).help("No tool use").accessibilityHidden(true)
            }
            if let context = ModelPickerModel.contextLabel(entry.contextLimit) {
                Text(context).help("\(entry.contextLimit.formatted()) token context")
            }
            if let cost = ModelPickerModel.costLabel(entry) {
                Text(cost)
                    .foregroundStyle(entry.isFree ? style.success : style.secondaryText)
                    .help(entry.isFree ? "No cost" : "USD per million input / output tokens")
            }
        }
        .font(style.smallFont.monospacedDigit())
        .foregroundStyle(style.secondaryText)
    }

    private func help(_ entry: ModelEntry, providerName: String) -> String {
        var parts = ["\(providerName) · \(entry.modelID)"]
        if let context = ModelPickerModel.contextLabel(entry.contextLimit) { parts.append("\(context) context") }
        if let cost = ModelPickerModel.costLabel(entry) { parts.append(entry.isFree ? "free" : "\(cost) per M tokens") }
        return parts.joined(separator: " · ")
    }

    private func accessibilityLabel(_ entry: ModelEntry, providerName: String, variant: String?, selected: Bool) -> String {
        var parts = [entry.name, providerName]
        if let variant { parts.append("effort \(variant)") }
        if let cost = ModelPickerModel.costLabel(entry) { parts.append(entry.isFree ? "free" : cost) }
        if selected { parts.append("current") }
        if let reason = row.disabledReason { parts.append(reason) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let entry = row.model {
            let prefs = model.preferences.value
            Button(prefs.isFavourite(entry.id) ? "Remove from Favourites" : "Add to Favourites") { model.toggleFavourite(entry) }
            Button(prefs.hidden.contains(entry.id) ? "Show Model" : "Hide Model") {
                model.setHidden(entry, !prefs.hidden.contains(entry.id))
            }
        }
    }
}

struct Tag: View {
    @Environment(\.agentUIStyle) private var style
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: NSFont.smallSystemFontSize - 1, weight: .medium))
            .foregroundStyle(style.secondaryText)
            .padding(.horizontal, 4)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(style.separator, lineWidth: 0.5))
    }
}
