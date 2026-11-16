import AppKit

/// Process entry point. BelloCode uses the AppKit application lifecycle; SwiftUI is hosted inside AppKit panes.
@main
enum BelloCodeMain {
    @MainActor
    static func main() {
        // TEMPORARY (gate G4): headless check of the bundled opencode server. See SmokeTest.swift.
        if CommandLine.arguments.contains(SmokeTest.launchArgument) {
            SmokeTest.runAndExit()
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // A bundle with an Info.plist is a regular app already; this also covers running the bare executable.
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
