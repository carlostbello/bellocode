// G5 spike entry point: `TerminalSpike <scenario> [options]`. One scenario per process; every child is stopped
// before exit. Reports go to build/spikes/G5/<scenario>.json, snapshots to build/snapshots/G5-*.png.

import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let scenario = arguments.first ?? "help"

let app = NSApplication.shared
let harness = Harness()
harness.show()

// Hard ceiling so a hung scenario cannot leave the server running.
let watchdog = Task { @MainActor in
    try? await Task.sleep(for: .seconds(600))
    harness.say("watchdog: scenario exceeded 600 s")
    await harness.stopServer()
    exit(3)
}

Task { @MainActor in
    let code = await Scenarios(harness, options: Array(arguments.dropFirst())).run(scenario)
    await harness.stopServer()
    watchdog.cancel()
    exit(code)
}
app.run()
