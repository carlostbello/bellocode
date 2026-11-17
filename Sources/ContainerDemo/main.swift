// ContainerDemo: a small harness for the container runtime (docs/features/containers.md). From the repository root,
// with Rancher Desktop (dockerd) running:
//
//   status                     runtime state, as the app shows it
//   bench <image> [--repo DIR] production-path measurements (writes docs/features/containers-bench/measurements.json)
//   cleanup                    remove every container and volume labelled app.bellocode.test=1
//   plugin-test [DIR]          the opencode plugin's `bun test` in a throwaway container (make plugin-test)
//
// It never uses a container CLI and never reads Rancher Desktop's own configuration beyond what RuntimeDiscovery does.

import ContainerKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "status":
        let state = await RuntimeDiscovery().detect()
        print("\(state.shortLabel): \(state.userMessage)")
        if case .ready(let ready) = state { for note in ready.notes { print("note: \(note)") } }
    case "bench":
        guard arguments.count >= 2 else { throw DemoError("usage: bench <image> [--repo DIR]") }
        let repo = arguments.firstIndex(of: "--repo").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        try await Bench.run(image: arguments[1], repo: repo)
    case "cleanup":
        try await Demo.cleanup()
    case "plugin-test":
        exit(try await PluginTest.run(pluginDirectory: arguments.count > 1 ? arguments[1] : "Plugin"))
    default:
        log("commands: status | bench <image> [--repo DIR] | cleanup | plugin-test [DIR]")
        exit(2)
    }
} catch {
    log("error: \(error)")
    exit(1)
}
