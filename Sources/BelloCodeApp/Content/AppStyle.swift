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
        let base = DS.Typography.current.baseSize
        var style = ComposerStyle()
        style.font = DS.TextRole.composer.font(base: base)
        style.textColor = DS.Color.text
        style.placeholderColor = DS.Color.placeholder
        style.secondaryTextColor = DS.Color.text2
        style.cardBackgroundColor = DS.Color.raised
        style.borderColor = DS.Color.composerOutline
        style.focusBorderColor = DS.Color.borderStrong
        style.accentColor = DS.Color.accent
        style.chipBackgroundColor = DS.Color.fillHover
        style.errorColor = DS.Color.dangerText
        style.popoverBackgroundColor = DS.Color.raised
        style.cornerRadius = DS.Radius.xl
        style.contentInsets = NSEdgeInsets(top: DS.Space.s12, left: DS.Space.s14, bottom: DS.Space.s4, right: DS.Space.s8)
        style.minimumLines = hero ? 3 : 1
        style.controlHeight = DS.Size.composerControl
        style.completionRowHeight = DS.Size.menuRow
        style.placeholder = hero
            ? "Describe the task. @ mentions files or agents, / runs commands"
            : "Ask for follow-up changes. @ mentions files, / runs commands"
        return style
    }

    static var agentUI: AgentUIStyle {
        let base = DS.Typography.current.baseSize
        return AgentUIStyle(
            accent: Color(nsColor: DS.Color.accent),
            surface: Color(nsColor: DS.Color.raised),
            inset: Color(nsColor: DS.Color.codeFill),
            separator: Color(nsColor: DS.Color.border),
            primaryText: Color(nsColor: DS.Color.text),
            secondaryText: Color(nsColor: DS.Color.text2),
            attention: Color(nsColor: DS.Color.warningText),
            danger: Color(nsColor: DS.Color.dangerText),
            success: Color(nsColor: DS.Color.successText),
            bodyFont: DS.TextRole.body.swiftUIFont(base: base),
            smallFont: DS.TextRole.label.swiftUIFont(base: base),
            titleFont: DS.TextRole.title.swiftUIFont(base: base),
            monospacedFont: DS.TextRole.codeSmall.swiftUIFont(base: base),
            cornerRadius: DS.Radius.xl,
            spacing: DS.Space.s4,
            rowHeight: DS.Size.menuRow)
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
