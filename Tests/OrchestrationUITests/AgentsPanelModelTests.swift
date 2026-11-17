import Foundation
import Testing

@testable import OrchestrationUI

@Suite("Agents panel text")
struct AgentsPanelTextTests {
    @Test func elapsedIsShortAndWordy() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(OrchestrationText.elapsed(from: start, to: start.addingTimeInterval(4)) == "4 s")
        #expect(OrchestrationText.elapsed(from: start, to: start.addingTimeInterval(150)) == "2 m")
        #expect(OrchestrationText.elapsed(from: start, to: start.addingTimeInterval(3600)) == "1 h")
        #expect(OrchestrationText.elapsed(from: start, to: start.addingTimeInterval(3900)) == "1 h 5 m")
        #expect(OrchestrationText.elapsed(from: start, to: start.addingTimeInterval(-5)) == "0 s")
    }
}
