import AppKit
import BelloCore
import Engine
import SwiftUI
import DesignSystem

/// The composer's model button: a ghost select (sparkle glyph, model, effort, chevron) opening the model picker on the
/// popover glass (⇧⌘M).
public struct ModelPickerButton: View {
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
            HStack(spacing: DS.Space.s6) {
                if model.pending != nil {
                    StatusLabel(.running, showsText: false).accessibilityLabel("Switching model")
                } else if model.error != nil {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(SwiftUI.Color.ds.dangerText)
                } else {
                    Image(systemName: "sparkle").font(.system(size: DS.Size.iconPointRow)).foregroundStyle(SwiftUI.Color.ds.icon)
                }
                Text(model.selectedModel?.name ?? model.selection?.modelID ?? "Choose model").lineLimit(1)
                if let variant = model.selection?.variant {
                    Text(variant).foregroundStyle(SwiftUI.Color.ds.text3)
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(SwiftUI.Color.ds.text4)
            }
        }
        .buttonStyle(ComposerSelectStyle(isOpen: isOpen.value))
        .keyboardShortcut(.modelPicker)
        .onChange(of: model.openRequests) {
            if !isOpen.value { model.prepareForOpen() }
            isOpen.value = true
        }
        .help(model.error.map { "The model was not changed: \($0)" } ?? "Choose model (\(AgentShortcut.modelPicker.display))")
        .accessibilityLabel("Model")
        .accessibilityValue(
            [model.selectedModel?.name ?? model.selection?.modelID, model.selection?.variant].compactMap { $0 }.joined(separator: ", "))
        .glassPopover(isPresented: $isOpen.value, width: ModelPickerView.width) {
            ModelPickerView(model: model) { isOpen.value = false }
        }
    }
}

/// Picker content (model-picker-dark.png): search field (focused), provider sections with a status on the right, rows
/// with a check / favourite slot, name, context and price, Free in `successText`, providers to connect receding with a
/// `Connect…` link, and a footer of key caps.
public struct ModelPickerView: View {
    @Bindable var model: ModelPickerModel
    let close: () -> Void
    @FocusState private var searchFocused: Bool

    static let width: CGFloat = 360
    static let height: CGFloat = 420

    public init(model: ModelPickerModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            SwiftUI.Color.ds.border.frame(height: 1)
            list
            footer
        }
        .frame(width: Self.width, height: Self.height)
        .noImplicitAnimation()
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: DS.Space.s8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DS.Size.iconPoint))
                .foregroundStyle(SwiftUI.Color.ds.text3)
                .accessibilityHidden(true)
            TextField("Search models", text: $model.query)
                .textFieldStyle(.plain)
                .font(.ds(.body))
                .foregroundStyle(SwiftUI.Color.ds.text)
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
                if model.isRefreshing {
                    StatusLabel(.running, showsText: false)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: DS.Size.iconPointRow))
                }
            }
            .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
            .help("Refresh models")
            .accessibilityLabel("Refresh models")
            Button {
                model.showsHidden.toggle()
            } label: {
                Image(systemName: model.showsHidden ? "eye" : "eye.slash").font(.system(size: DS.Size.iconPointRow))
            }
            .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true, isSelected: model.showsHidden))
            .help(model.showsHidden ? "Hide hidden models" : "Show hidden models")
            .accessibilityLabel("Show hidden models")
            .accessibilityValue(model.showsHidden ? "on" : "off")
            DSKbdView(AgentShortcut.modelPicker.display)
        }
        .padding(.horizontal, DS.Space.s12)
        .frame(height: 44)
    }

    private var list: some View {
        let sections = model.sections
        let highlighted = model.highlightedRow?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    if sections.allSatisfy({ $0.id == "connect" }) && !model.query.isEmpty {
                        Text("No models match “\(model.query)”.")
                            .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3)
                            .padding(.horizontal, DS.Space.s12).padding(.vertical, DS.Space.s8)
                    }
                    ForEach(sections) { section in
                        if section.id == "connect" {
                            SwiftUI.Color.ds.border.frame(height: 1).padding(.horizontal, DS.Space.s8).padding(.vertical, DS.Space.s4)
                        }
                        HStack {
                            Text(section.title)
                            Spacer()
                            if let status = Self.status(of: section) { Text(status) }
                        }
                        .font(.ds(.metaEmph))
                        .foregroundStyle(SwiftUI.Color.ds.text3)
                        .padding(.horizontal, DS.Space.s12)
                        .frame(height: DS.Size.menuGroupHeader)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        ForEach(section.rows) { row in
                            ModelPickerRow(model: model, row: row, isHighlighted: row.id == highlighted) {
                                if model.choose(row) { close() }
                            }
                            .id(row.id)
                        }
                    }
                }
                .padding(.vertical, DS.Space.s4)
            }
            .scrollIndicators(.automatic)
            .onChange(of: highlighted) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .onAppear {
                if let highlighted { proxy.scrollTo(highlighted, anchor: .center) }
            }
        }
    }

    /// A provider section's status word on the right of its header.
    static func status(of section: ModelPickerModel.Section) -> String? {
        guard section.id.hasPrefix("provider-") else { return nil }
        let models = section.rows.compactMap(\.model)
        return !models.isEmpty && models.allSatisfy(\.isFree) ? "Free models" : "Connected"
    }

    private var footer: some View {
        HStack(spacing: DS.Space.s10) {
            if let error = model.error {
                HStack(spacing: DS.Space.s6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(SwiftUI.Color.ds.dangerText)
                    Text(error).foregroundStyle(SwiftUI.Color.ds.text).lineLimit(1)
                }
            } else {
                hint("↑↓", "select")
                    .padding(.leading, -2)
                hint("↩", "choose")
                hint("⇥", "effort")
                hint("⌘D", "favourite")
                Spacer(minLength: 0)
                DSKbdView("esc")
            }
        }
        .font(.ds(.meta))
        .foregroundStyle(SwiftUI.Color.ds.text3)
        .padding(.horizontal, DS.Space.s12)
        .frame(height: 38)
        .background(SwiftUI.Color.ds.fillSubtle)
        .overlay(alignment: .top) { SwiftUI.Color.ds.border.frame(height: 1) }
        .accessibilityHidden(model.error == nil)
    }

    private func hint(_ keys: String, _ text: String) -> some View {
        HStack(spacing: DS.Space.s4) {
            DSKbdView(keys)
            Text(text).lineLimit(1)
        }
        .fixedSize()
    }
}

/// The ghost select look of composer controls (visual-language.md §6 "Composer"): 26 high, `label` 12, `text2`,
/// hover / open = `fillHover` + `text`; keyboard focus draws the accent ring.
struct ComposerSelectStyle: ButtonStyle {
    var isOpen = false

    func makeBody(configuration: Configuration) -> some View {
        ComposerSelectBody(configuration: configuration, isOpen: isOpen)
    }
}

private struct ComposerSelectBody: View {
    let configuration: ButtonStyleConfiguration
    let isOpen: Bool
    @StateObject private var hover = ViewState(false)
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let active = hover.value || isOpen || configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
        configuration.label
            .font(.ds(.label))
            .foregroundStyle(active ? SwiftUI.Color.ds.text : SwiftUI.Color.ds.text2)
            .padding(.horizontal, DS.Space.s8)
            .frame(height: DS.Size.composerControl)
            .background(shape.fill(active ? SwiftUI.Color.ds.fillHover : .clear))
            .overlay(shape.strokeBorder(isFocused ? SwiftUI.Color.ds.focusRing : .clear, lineWidth: DS.Border.focusRing))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : DSControlState.disabledOpacity)
            .onHover { hover.value = $0 }
            .focusEffectDisabled()
            .transaction { $0.animation = nil }
    }
}

struct ModelPickerRow: View {
    let model: ModelPickerModel
    let row: ModelPickerModel.Row
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, DS.Space.s8)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
                .background(
                    isHighlighted ? SwiftUI.Color.ds.highlight : .clear,
                    in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                .padding(.horizontal, DS.Space.s4)
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
            HStack(spacing: DS.Space.s8) {
                SwiftUI.Color.clear.frame(width: 14, height: 14)
                Text(name).foregroundStyle(SwiftUI.Color.ds.text3)
                Spacer()
                Text("Connect…").font(.ds(.body)).foregroundStyle(SwiftUI.Color.ds.infoText)
            }
            .font(.ds(.body))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(name), not connected. Connect.")
        case .connectOther:
            HStack(spacing: DS.Space.s8) {
                Image(systemName: "plus").font(.system(size: DS.Size.iconPointMeta, weight: .semibold)).foregroundStyle(SwiftUI.Color.ds.text3).frame(width: 14)
                Text("Connect another provider…").foregroundStyle(SwiftUI.Color.ds.text2)
                Spacer()
            }
            .font(.ds(.body))
        }
    }

    private func modelContent(_ entry: ModelEntry, providerName: String) -> some View {
        let selection = model.selection
        let isSelected = selection?.providerID == entry.providerID && selection?.modelID == entry.modelID
        let isFavourite = model.preferences.value.isFavourite(entry.id)
        let isHidden = model.preferences.value.hidden.contains(entry.id)
        let variant = model.variant(for: entry)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.Space.s8) {
                ZStack {
                    SwiftUI.Color.clear
                    if isSelected {
                        Image(systemName: "checkmark").foregroundStyle(SwiftUI.Color.ds.accent)
                    } else if isFavourite {
                        Image(systemName: "star").foregroundStyle(SwiftUI.Color.ds.warningText)
                    }
                }
                .font(.system(size: DS.Size.iconPointMeta, weight: .semibold))
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
                Text(entry.name)
                    .foregroundStyle(row.isEnabled ? SwiftUI.Color.ds.text : SwiftUI.Color.ds.text3)
                    .lineLimit(1)
                    .layoutPriority(1)
                if model.query.isEmpty == false || isFavouriteSection {
                    Text(providerName).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).lineLimit(1)
                }
                if entry.status != "active" { Tag(text: entry.status).fixedSize() }
                if isHidden { Tag(text: "hidden").fixedSize() }
                if let variant, !isHighlighted { Tag(text: variant).fixedSize() }
                Spacer(minLength: DS.Space.s4)
                hints(entry).fixedSize()
            }
            // The effort choices of the highlighted model, on their own line (⇥ cycles them).
            if isHighlighted, !entry.variants.isEmpty {
                HStack(spacing: DS.Space.s8) {
                    SwiftUI.Color.clear.frame(width: 14, height: 1)
                    Text("Reasoning").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3)
                    Spacer(minLength: 0)
                    variantChips(entry, selected: variant)
                }
                .padding(.bottom, DS.Space.s6)
            }
        }
        .font(.ds(.body))
        .help(row.disabledReason ?? help(entry, providerName: providerName))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(entry, providerName: providerName, variant: variant, selected: isSelected))
    }

    private var isFavouriteSection: Bool { row.id.hasPrefix("favourites|") || row.id.hasPrefix("recent|") }

    /// The effort choices as a segmented control (`fillSubtle` track, `rowActive` thumb). Not buttons: a button
    /// inside the row's button breaks the row's layout on macOS.
    private func variantChips(_ entry: ModelEntry, selected: String?) -> some View {
        HStack(spacing: 0) {
            ForEach([nil] + entry.variants.map(Optional.some), id: \.self) { variant in
                let isOn = variant == selected
                Text((variant ?? "default").capitalized)
                    .font(.ds(.labelEmph))
                    .foregroundStyle(isOn ? SwiftUI.Color.ds.text : SwiftUI.Color.ds.text2)
                    .padding(.horizontal, DS.Space.s8)
                    .frame(height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .fill(isOn ? SwiftUI.Color.ds.rowActive : .clear)
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous).strokeBorder(isOn ? SwiftUI.Color.ds.rowRing : .clear)))
                    .contentShape(Rectangle())
                    .onTapGesture { model.setVariant(variant, for: entry) }
                    .help("Effort: \(variant ?? "model default")")
                    .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(SwiftUI.Color.ds.fillSubtle))
        .fixedSize()
    }

    private func hints(_ entry: ModelEntry) -> some View {
        HStack(spacing: DS.Space.s8) {
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
                    .foregroundStyle(entry.isFree ? SwiftUI.Color.ds.successText : SwiftUI.Color.ds.text3)
                    .help(entry.isFree ? "No cost" : "USD per million input / output tokens")
            }
        }
        .font(.ds(.meta).monospacedDigit())
        .foregroundStyle(SwiftUI.Color.ds.text3)
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

/// A small status / variant tag: a neutral `DSPillView`.
struct Tag: View {
    let text: String

    var body: some View { DSPillView(text) }
}
