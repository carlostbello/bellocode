import BelloCore
import DesignSystem
import Engine
import SwiftUI

/// A Settings ▸ Models row control (docs/features/models.md): a DS select showing the choice in effect — a choice
/// ("Same as thread · Anthropic · Claude Sonnet 5") or a model ("Anthropic · Claude Sonnet 5") with a Free / price
/// badge, or "Unavailable" when the provider is gone or disabled — opening the same model picker as the composer
/// (search, providers, Connect…, effort) on the popover glass. No shortcut of its own: ↩ or Space opens it.
public struct ModelSettingButton: View {
    @Bindable var model: ModelPickerModel
    let label: String
    /// Shown when the saved model is not usable now ("Provider disabled in opencode", "Not connected").
    let problem: String?
    @StateObject private var isOpen = ViewState(false)

    public init(model: ModelPickerModel, label: String, problem: String? = nil) {
        self.model = model
        self.label = label
        self.problem = problem
    }

    public var body: some View {
        Button {
            if !isOpen.value { model.prepareForOpen() }
            isOpen.value.toggle()
        } label: {
            HStack(spacing: DS.Space.s6) {
                if model.pending != nil || model.pendingChoice != nil {
                    StatusLabel(.running, showsText: false).accessibilityLabel("Saving")
                } else if model.error != nil || problem != nil {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(SwiftUI.Color.ds.warningText)
                }
                Text(title).font(.ds(.labelEmph)).foregroundStyle(SwiftUI.Color.ds.text).lineLimit(1).truncationMode(.middle)
                if let badge { DSPillView(badge.text, tone: badge.tone).fixedSize() }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(SwiftUI.Color.ds.text4)
            }
            .padding(.horizontal, DS.Space.s8)
            .frame(minHeight: DS.Size.controlSmall, maxHeight: DS.Size.controlSmall)
            .background(SwiftUI.Color.ds.raised, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .strokeBorder(isOpen.value ? SwiftUI.Color.ds.accent : SwiftUI.Color.ds.borderStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 300, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
        .help(model.error ?? problem ?? "Choose the model for \(label.lowercased())")
        .accessibilityLabel(label)
        .accessibilityValue([title, badge?.text, model.error ?? problem].compactMap { $0 }.joined(separator: ", "))
        .agentGlassPopover(isPresented: $isOpen.value, width: ModelPickerView.width) {
            ModelPickerView(model: model) { isOpen.value = false }
        }
    }

    /// The choice's title, or "Provider · Model".
    var title: String {
        let chosen = model.pendingChoice ?? model.currentChoice()
        if let chosen, let item = model.choices().first(where: { $0.id == chosen }) { return item.title }
        guard let selection = model.selection else { return "Choose…" }
        // Not in the catalog (provider disconnected): the model's ID alone; the provider is in the tooltip.
        guard let entry = model.selectedModel else { return selection.modelID }
        let name = entry.name
        let provider = model.providerName(selection.providerID)
        return "\(provider) · \(name)" + (selection.variant.map { " · \($0)" } ?? "")
    }

    var badge: (text: String, tone: DS.Tone)? {
        if problem != nil { return ("Unavailable", .warning) }
        if (model.pendingChoice ?? model.currentChoice()) != nil { return nil }
        guard let entry = model.selectedModel else { return nil }
        if entry.isFree { return ("Free", .success) }
        return ("Paid", .neutral)
    }
}

extension ModelPickerModel {
    /// The provider's display name in the picker's catalog.
    public func providerName(_ id: String) -> String {
        catalogNow?.providers.first { $0.id == id }?.name ?? id
    }
}
