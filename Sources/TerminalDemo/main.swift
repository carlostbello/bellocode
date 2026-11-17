// TerminalDemo: the M2-A terminal harness (docs/features/terminal.md).
//
//   swift run TerminalDemo snapshots   render the drawer against MockOpenCode's fake shell to build/snapshots/terminal-*.png
//   swift run -c release TerminalDemo perf      throughput, main-thread latency and CPU on the production path
//   swift run -c release TerminalDemo latency   keystroke to buffer through the production path
//
// perf and latency need the pinned opencode in Vendor/ (Scripts/fetch-opencode.sh). They run it with HOME and XDG
// directories in a temporary folder (never the user's opencode config or data) and stop it before exiting. Reports go
// to build/terminal/*.json.

import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "snapshots"

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Task { @MainActor in
    let code: Int32
    switch command {
    case "snapshots": code = await SnapshotScenarios().run()
    case "perf": code = await PerfScenarios().perf()
    case "latency": code = await PerfScenarios().latency()
    default:
        print("usage: TerminalDemo snapshots|perf|latency")
        code = 2
    }
    exit(code)
}
app.run()
