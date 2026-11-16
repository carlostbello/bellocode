import AppKit

/// Process entry point. BelloCode uses the AppKit application lifecycle; SwiftUI is hosted inside AppKit panes.
@main
enum BelloCodeMain {
    @MainActor
    static func main() {
        let options: LaunchOptions
        do {
            options = try LaunchOptions.parse(CommandLine.arguments)
        } catch {
            FileHandle.standardError.write(Data("BelloCode: \(error)\n".utf8))
            exit(2)
        }
        if options.mode == .smokeTest { SmokeTest.runAndExit() }

        let application = NSApplication.shared
        let delegate = AppDelegate(options: options)
        application.delegate = delegate
        // A bundle with an Info.plist is a regular app already; this also covers running the bare executable.
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
