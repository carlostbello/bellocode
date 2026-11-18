import Combine
import Foundation
import SwiftUI

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

/// A `TimelineView(.periodic)` replacement for relative and elapsed times: re-renders `content` with the current date
/// every `interval`, on `ContinuousClock`. SwiftUI's periodic schedule runs on run-loop timers, which were seen not to
/// fire while the process is otherwise idle on macOS 27 (BelloCore `ContinuousTicker` has the details). The refresh
/// task is owned by the view and ends when it leaves the hierarchy.
public struct ContinuousTimeline<Content: View>: View {
    private let interval: Duration
    private let content: (Date) -> Content
    // `@StateObject`, not `@State`: Command Line Tools have no SwiftUI macro plugin (see DSSwiftUI.swift).
    @StateObject private var clock = TimelineClock()

    public init(every interval: Duration, @ViewBuilder content: @escaping (Date) -> Content) {
        self.interval = interval
        self.content = content
    }

    public var body: some View {
        content(clock.now)
            .task(id: interval) {
                clock.now = Date()
                while true {
                    do { try await Task.sleep(for: interval, clock: .continuous) } catch { return }
                    clock.now = Date()
                }
            }
    }
}

@MainActor
final class TimelineClock: ObservableObject {
    @Published var now = Date()
}
