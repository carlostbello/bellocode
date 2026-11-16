import Foundation

/// Compact relative times for dense rows: "now", "4m", "3h", "2d", "5w", then a short date ("Mar 4", or "Mar 4, 2025"
/// in another year). Deterministic for tests: pass `now` and a calendar.
public enum RelativeTime {
    public static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
        case ..<(5 * 7 * 86_400): return "\(Int(seconds / (7 * 86_400)))w"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: calendar.locale ?? .current, calendar: calendar,
                                         timeZone: calendar.timeZone)
            style = style.month(.abbreviated).day()
            if !sameYear { style = style.year() }
            return date.formatted(style)
        }
    }

    /// The spoken form for VoiceOver ("4 minutes ago").
    public static func spoken(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
