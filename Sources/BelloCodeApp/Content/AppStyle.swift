import AgentUI
import AppKit
import ComposerKit
import DesignSystem
import Engine
import SwiftUI

/// Maps DesignSystem tokens onto the ComposerKit and AgentUI style structs, so the composer, the request cards, the
/// pickers and the shell share one visual language (fonts from `DS.Typography.current`, one card radius and surface,
/// semantic colours that follow appearance, accent and Increase Contrast).
@MainActor
enum AppStyle {
    static func composer(hero: Bool = false) -> ComposerStyle {
        let typography = DS.Typography.current
        var style = ComposerStyle()
        style.font = typography.body
        style.textColor = DS.Palette.text
        style.placeholderColor = DS.Palette.tertiaryText
        style.secondaryTextColor = DS.Palette.secondaryText
        style.cardBackgroundColor = DS.Palette.cardBackground
        style.borderColor = DS.Palette.cardBorder
        style.focusBorderColor = DS.Palette.accent.withAlphaComponent(0.55)
        style.accentColor = DS.Palette.accent
        style.chipBackgroundColor = DS.Palette.groupFill
        style.errorColor = DS.Palette.failure
        style.popoverBackgroundColor = DS.Palette.cardBackground
        style.cornerRadius = DS.Radius.card
        style.contentInsets = NSEdgeInsets(top: DS.Spacing.m + 2, left: DS.Spacing.l, bottom: DS.Spacing.s, right: DS.Spacing.s)
        style.minimumLines = hero ? 3 : 1
        style.controlHeight = DS.Spacing.sidebarRowHeight
        style.completionRowHeight = DS.Spacing.sidebarRowHeight
        style.placeholder = hero
            ? "Describe the task. @ mentions files or agents, / runs commands"
            : "Ask for follow-up changes. @ mentions files, / runs commands"
        return style
    }

    static var agentUI: AgentUIStyle {
        let typography = DS.Typography.current
        return AgentUIStyle(
            accent: Color(nsColor: DS.Palette.accent),
            surface: Color(nsColor: DS.Palette.cardBackground),
            inset: Color(nsColor: DS.Palette.groupFill),
            separator: Color(nsColor: DS.Palette.cardBorder),
            primaryText: Color(nsColor: DS.Palette.text),
            secondaryText: Color(nsColor: DS.Palette.secondaryText),
            attention: Color(nsColor: DS.Palette.attention),
            danger: Color(nsColor: DS.Palette.failure),
            success: Color(nsColor: DS.Palette.success),
            bodyFont: .system(size: typography.baseSize),
            smallFont: .system(size: typography.baseSize - 1),
            titleFont: .system(size: typography.baseSize, weight: .semibold),
            monospacedFont: .system(size: typography.baseSize - 1, design: .monospaced),
            cornerRadius: DS.Radius.card,
            spacing: DS.Spacing.xs,
            rowHeight: DS.Spacing.sidebarRowHeight)
    }

    /// Hosts a SwiftUI control with the app's AgentUI style (intrinsic size, Auto Layout).
    static func host<V: View>(_ view: V) -> NSView {
        let hosting = NSHostingView(rootView: view.environment(\.agentUIStyle, agentUI))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.translatesAutoresizingMaskIntoConstraints = false
        return hosting
    }
}

/// App-wide services the surfaces use: settings, the one `AuthService`, and "open the provider connection UI".
@MainActor
final class AppServices {
    let settings: AppSettings
    /// nil when no server sign-in is available (tests without a server).
    let auth: AuthService?
    let attachmentStore: AttachmentFileStore
    /// Opens Settings ▸ Accounts (or the connect sheet) for an integration, or for any provider when nil.
    var connectProvider: @MainActor (String?) -> Void

    init(
        settings: AppSettings = AppSettings(defaults: nil), auth: AuthService? = nil,
        attachmentStore: AttachmentFileStore = .applicationDefault, connectProvider: @escaping @MainActor (String?) -> Void = { _ in }
    ) {
        self.settings = settings
        self.auth = auth
        self.attachmentStore = attachmentStore
        self.connectProvider = connectProvider
    }
}
