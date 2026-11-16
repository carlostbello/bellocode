// ComposerDemo: hosts the composer with a fake thread and runs scripted scenarios (docs/features/composer.md).
//
//   swift run ComposerDemo                 run every scenario, write snapshots, exit 0 when all checks pass
//   swift run ComposerDemo history growth  run the named scenarios
//   swift run ComposerDemo --interactive   leave the window open for manual testing
//
// Snapshots go to build/snapshots/composer-*.png (light and dark).

import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let interactive = arguments.contains("--interactive")
let requested = arguments.filter { !$0.hasPrefix("--") }

let app = NSApplication.shared
app.setActivationPolicy(interactive ? .regular : .accessory)
let harness = Harness(interactive: interactive)

Task { @MainActor in
    if interactive {
        harness.showInteractive()
        app.activate()
        return
    }
    let code = await harness.run(requested)
    exit(code)
}
app.run()
