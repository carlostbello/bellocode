import AppKit

@MainActor
final class ScenarioRunner {
    let window: NSWindow
    let arguments: [String]
    init(window: NSWindow, arguments: [String]) {
        self.window = window
        self.arguments = arguments
    }
    func run(_ name: String) async -> Bool { false }
}
