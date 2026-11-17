import AppKit
import ComposerKit
import DesignSystem
import Observation
import TerminalKit

/// App preferences (Settings ▸ General) plus first-run state. Persisted in `UserDefaults` (no secrets here).
///
/// Threading: `@MainActor`, `@Observable`; surfaces observe the values they use (the composer's send key and font).
@MainActor
@Observable
final class AppSettings {
    enum Appearance: String, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "Match System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    static let fontSizeRange: ClosedRange<Double> = 11...18

    var sendKey: SendKey { didSet { save(sendKey.rawValue, Keys.sendKey) } }
    var baseFontSize: Double {
        didSet {
            let clamped = min(max(baseFontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
            if clamped != baseFontSize { baseFontSize = clamped }
            save(baseFontSize, Keys.baseFontSize)
            applyTypography()
        }
    }
    var appearance: Appearance {
        didSet {
            save(appearance.rawValue, Keys.appearance)
            applyAppearance()
        }
    }
    /// Settings ▸ Terminal: font size, scrollback, OSC 52 clipboard writes, Option as Meta, paste confirmation.
    var terminalPreferences: TerminalPreferences {
        didSet {
            guard terminalPreferences != oldValue else { return }
            save(Double(terminalPreferences.fontSize), Keys.terminalFontSize)
            save(terminalPreferences.scrollback, Keys.terminalScrollback)
            save(terminalPreferences.allowsClipboardWrites, Keys.terminalClipboardWrites)
            save(terminalPreferences.optionAsMeta, Keys.terminalOptionAsMeta)
            save(terminalPreferences.confirmsMultilinePaste, Keys.terminalConfirmPaste)
        }
    }
    /// Settings ▸ Browser: terminal links open in the built-in browser (⇧-click opens the other one).
    var terminalLinksOpenInBuiltInBrowser: Bool { didSet { save(terminalLinksOpenInBuiltInBrowser, Keys.terminalLinksBuiltIn) } }
    /// Settings ▸ Browser: offer dev-server URLs seen in terminal or agent output.
    var offersDevServers: Bool { didSet { save(offersDevServers, Keys.offersDevServers) } }
    /// Onboarding finished or skipped once; it is then offered from Settings ▸ Accounts only.
    var hasCompletedOnboarding: Bool { didSet { save(hasCompletedOnboarding, Keys.onboarding) } }

    @ObservationIgnored private let defaults: UserDefaults?

    private enum Keys {
        static let sendKey = "BelloCodeSendKey"
        static let baseFontSize = "BelloCodeBaseFontSize"
        static let appearance = "BelloCodeAppearance"
        static let onboarding = "BelloCodeOnboardingCompleted"
        static let terminalFontSize = "BelloCodeTerminalFontSize"
        static let terminalScrollback = "BelloCodeTerminalScrollback"
        static let terminalClipboardWrites = "BelloCodeTerminalAllowsClipboardWrites"
        static let terminalOptionAsMeta = "BelloCodeTerminalOptionAsMeta"
        static let terminalConfirmPaste = "BelloCodeTerminalConfirmsMultilinePaste"
        static let terminalLinksBuiltIn = "BelloCodeTerminalLinksOpenInBuiltInBrowser"
        static let offersDevServers = "BelloCodeBrowserOffersDevServers"
    }

    /// `defaults` nil keeps everything in memory (tests and snapshots).
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        sendKey = defaults?.string(forKey: Keys.sendKey).flatMap(SendKey.init(rawValue:)) ?? .returnKey
        let size = defaults?.object(forKey: Keys.baseFontSize) as? Double ?? Double(NSFont.systemFontSize)
        baseFontSize = min(max(size, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        appearance = defaults?.string(forKey: Keys.appearance).flatMap(Appearance.init(rawValue:)) ?? .system
        hasCompletedOnboarding = defaults?.bool(forKey: Keys.onboarding) ?? false
        terminalLinksOpenInBuiltInBrowser = defaults?.object(forKey: Keys.terminalLinksBuiltIn) as? Bool ?? true
        offersDevServers = defaults?.object(forKey: Keys.offersDevServers) as? Bool ?? true
        let defaultTerminal = TerminalPreferences()
        terminalPreferences = TerminalPreferences(
            fontSize: CGFloat(defaults?.object(forKey: Keys.terminalFontSize) as? Double ?? Double(defaultTerminal.fontSize)),
            scrollback: defaults?.object(forKey: Keys.terminalScrollback) as? Int ?? defaultTerminal.scrollback,
            allowsClipboardWrites: defaults?.object(forKey: Keys.terminalClipboardWrites) as? Bool ?? defaultTerminal.allowsClipboardWrites,
            optionAsMeta: defaults?.object(forKey: Keys.terminalOptionAsMeta) as? Bool ?? defaultTerminal.optionAsMeta,
            confirmsMultilinePaste: defaults?.object(forKey: Keys.terminalConfirmPaste) as? Bool ?? defaultTerminal.confirmsMultilinePaste)
    }

    /// Applies typography and appearance process-wide (launch and after a change).
    func apply() {
        applyTypography()
        applyAppearance()
    }

    private func applyTypography() {
        let typography = DS.Typography(baseSize: baseFontSize)
        if DS.Typography.current != typography { DS.Typography.current = typography }
    }

    private func applyAppearance() {
        guard NSApp != nil else { return }
        NSApp.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Settings kept in memory only (tests and snapshots): they also get ephemeral browser profiles.
    var isEphemeral: Bool { defaults == nil }

    private func save(_ value: Any, _ key: String) { defaults?.set(value, forKey: key) }
}
