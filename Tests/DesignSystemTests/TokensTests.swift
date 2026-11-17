import BelloCore
@testable import DesignSystem
import Foundation
import Testing

@Suite struct DesignTokenTests {
    @Test func everyStatusHasASymbolAndATextLabel() {
        let symbols = SessionStatus.allCases.map { StatusGlyph($0).symbolName }
        #expect(Set(symbols).count == SessionStatus.allCases.count, "status shape must differ per status (not colour-only)")
        for status in SessionStatus.allCases {
            #expect(!StatusGlyph(status).label.isEmpty)
        }
        #expect(StatusGlyph(.idle).isQuiet)
        #expect(StatusGlyph(.awaitingApproval).needsUser)
    }

    @Test func typographyScalesFromOneBaseAndClamps() {
        let large = DS.Typography(baseSize: 17)
        #expect(large.font(.body).pointSize == 17)
        #expect(large.font(.meta).pointSize == 15)
        #expect(large.font(.title).pointSize == 17)  // title role: 13 at base 13 (visual-language.md §2)
        #expect(DS.Typography(baseSize: 2).baseSize == 9)
        #expect(DS.Typography(baseSize: 90).baseSize == 32)
    }

    @Test func relativeTimes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(RelativeTime.short(now.addingTimeInterval(-10), now: now, calendar: calendar) == "now")
        #expect(RelativeTime.short(now.addingTimeInterval(-300), now: now, calendar: calendar) == "5m")
        #expect(RelativeTime.short(now.addingTimeInterval(-7_200), now: now, calendar: calendar) == "2h")
        #expect(RelativeTime.short(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar) == "3d")
        #expect(RelativeTime.short(now.addingTimeInterval(-14 * 86_400), now: now, calendar: calendar) == "2w")
        #expect(RelativeTime.short(now.addingTimeInterval(-60 * 86_400), now: now, calendar: calendar) == "Jul 23")
        #expect(RelativeTime.short(now.addingTimeInterval(-400 * 86_400), now: now, calendar: calendar).hasSuffix("2025"))
        #expect(RelativeTime.short(now.addingTimeInterval(60), now: now, calendar: calendar) == "now")
    }

    @MainActor @Test func reduceMotionForcesInstantPanels() {
        DS.Motion.panelDuration = 0.2
        defer { DS.Motion.panelDuration = 0 }
        #expect(DS.Motion.effectivePanelDuration == (DS.Motion.reduceMotion ? 0 : 0.2))
    }
}
