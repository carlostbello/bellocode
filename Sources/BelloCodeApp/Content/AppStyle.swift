import AgentUI
import AppKit
import ComposerKit
import DesignSystem
import Engine
import SwiftUI

/// The few host choices ComposerKit and AgentUI still take from the app. Their colours, radii and metrics come from
/// DesignSystem directly (`ComposerStyle.resolvedWithDesignTokens`, AgentUI's `DS` reads), so only behaviour (hero
/// height, placeholder) and the fonts that follow Settings ▸ text size are passed here.
@MainActor
enum AppStyle {
    static func composer(hero: Bool = false) -> ComposerStyle {
        var style = ComposerStyle()
        // Compared on settings changes to re-apply the text size; ComposerKit resolves the rest from tokens.
        style.font = DS.TextRole.composer.font(base: DS.Typography.current.baseSize)
        style.minimumLines = hero ? 3 : 1
        style.placeholder = hero
            ? "Describe the task. @ mentions files or agents, / runs commands"
            : "Ask for follow-up changes. @ mentions files, / runs commands"
        return style
    }

    /// AgentUI's defaults (DesignSystem tokens) with fonts at the current text size (the Accounts panes read them).
    static var agentUI: AgentUIStyle {
        let base = DS.Typography.current.baseSize
        var style = AgentUIStyle.standard
        style.bodyFont = DS.TextRole.body.swiftUIFont(base: base)
        style.smallFont = DS.TextRole.label.swiftUIFont(base: base)
        style.titleFont = DS.TextRole.title.swiftUIFont(base: base)
        style.monospacedFont = DS.TextRole.codeSmall.swiftUIFont(base: base)
        return style
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
    /// Keeps drafts' staged attachments and pills across relaunches (R28); nil in tests and snapshots.
    let draftArchive: ComposerDraftArchive?
    /// Opens Settings ▸ Accounts (or the connect sheet) for an integration, or for any provider when nil.
    var connectProvider: @MainActor (String?) -> Void

    init(
        settings: AppSettings = AppSettings(defaults: nil), auth: AuthService? = nil,
        attachmentStore: AttachmentFileStore = .applicationDefault, draftArchive: ComposerDraftArchive? = nil,
        connectProvider: @escaping @MainActor (String?) -> Void = { _ in }
    ) {
        self.settings = settings
        self.auth = auth
        self.attachmentStore = attachmentStore
        self.draftArchive = draftArchive
        self.connectProvider = connectProvider
    }
}
