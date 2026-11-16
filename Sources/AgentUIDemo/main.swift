import AppKit
import Foundation

// AgentUIDemo: runs AgentUI views against MockOpenCodeServer scenarios, drives them programmatically, asserts the
// outcomes, writes light and dark PNG snapshots, and exits (0 when every scenario passed).
//
//   swift run AgentUIDemo --all [--out build/snapshots/agent-ui]
//   swift run AgentUIDemo --scenario requests

let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let names: [String] = arguments.contains("--all") ? Scenarios.all : (argument("--scenario").map { [$0] } ?? Scenarios.all)
let output = URL(filePath: argument("--out") ?? "build/snapshots/agent-ui", directoryHint: .isDirectory)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

Task { @MainActor in
    var failures = 0
    do {
        var snapshots = try Snapshotter(directory: output)
        for name in names {
            do {
                try await Scenarios.run(name, snapshots: &snapshots)
                print("✔ \(name)")
            } catch {
                failures += 1
                print("✘ \(name): \(error)")
            }
        }
        print("\(snapshots.written.count) snapshots in \(output.path)")
    } catch {
        failures += 1
        print("✘ \(error)")
    }
    exit(failures == 0 ? 0 : 1)
}
app.run()
