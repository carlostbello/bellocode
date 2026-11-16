import AppKit
import ComposerKit
import DesignSystem
import Observation

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
    /// Onboarding finished or skipped once; it is then offered from Settings ▸ Accounts only.
    var hasCompletedOnboarding: Bool { didSet { save(hasCompletedOnboarding, Keys.onboarding) } }

    @ObservationIgnored private let defaults: UserDefaults?

    private enum Keys {
        static let sendKey = "BelloCodeSendKey"
        static let baseFontSize = "BelloCodeBaseFontSize"
        static let appearance = "BelloCodeAppearance"
        static let onboarding = "BelloCodeOnboardingCompleted"
    }

    /// `defaults` nil keeps everything in memory (tests and snapshots).
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        sendKey = defaults?.string(forKey: Keys.sendKey).flatMap(SendKey.init(rawValue:)) ?? .returnKey
        let size = defaults?.object(forKey: Keys.baseFontSize) as? Double ?? Double(NSFont.systemFontSize)
        baseFontSize = min(max(size, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        appearance = defaults?.string(forKey: Keys.appearance).flatMap(Appearance.init(rawValue:)) ?? .system
        hasCompletedOnboarding = defaults?.bool(forKey: Keys.onboarding) ?? false
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

    private func save(_ value: Any, _ key: String) { defaults?.set(value, forKey: key) }
}
