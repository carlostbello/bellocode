import AppKit
import SwiftUI

/// Posts VoiceOver announcements. Callers announce a meaningful change once, never per streamed update.
public enum AccessibilityAnnouncer {
    @MainActor
    public static func post(_ text: String) {
        guard let window = NSApp?.keyWindow ?? NSApp?.mainWindow else { return }
        NSAccessibility.post(
            element: window, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// "just now", "2 min", "1 h": coarse age that changes rarely (re-rendered every 30 s at most).
struct AgeText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(Self.format(context.date.timeIntervalSince(date)))
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<45: "just now"
        case ..<3600: "\(max(1, Int((seconds / 60).rounded()))) min"
        case ..<86_400: "\(Int(seconds / 3600)) h"
        default: "\(Int(seconds / 86_400)) d"
        }
    }
}
