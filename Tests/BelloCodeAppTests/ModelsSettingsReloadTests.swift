import AppKit
import BelloCore
import Engine
import Foundation
import Testing
@testable import BelloCodeApp

/// A23: "Reload opencode Now" after Save Only asks first when approvals or questions are pending at dispatch time.
@Suite("Models pane reload")
@MainActor
struct ModelsSettingsReloadTests {
    @Test func reloadNowAsksWithTheCountsAtDispatch() async {
        var asked: [String] = []
        let model = ModelsSettingsModel(engine: TestWindows.engine, auth: nil, confirm: { title, _, button, other in
            asked.append("\(title)|\(button)|\(other)")
            return false
        })
        var counts = AttentionCounts()
        model.attentionCounts = { counts }
        var reloads = 0
        // Nothing was pending at Save Only; an approval arrives before Reload Now.
        counts = AttentionCounts(approvals: 1)
        #expect(await model.reloadConfirmed { reloads += 1; return nil } == false)
        #expect(reloads == 0)
        #expect(asked == ["Reload opencode now?|Reload|Cancel"])
        // Nothing pending: no question, reload at once.
        counts = AttentionCounts()
        #expect(await model.reloadConfirmed { reloads += 1; return nil })
        #expect(reloads == 1)
        #expect(asked.count == 1)
    }
}
