// G6 harness: `swift run ContainerSpike <command>` from the repository root, with Rancher Desktop (dockerd) running.
//
//   status                 runtime discovery state
//   image                  build the spike workspace image through POST /build (no CLI)
//   up <dir> <config>      create/start the workspace container for <dir>; write the helper config to <config>
//   bench <dir>            measurements (writes docs/spikes/G6/measurements.json)
//   forward <dir> <port>   forward host loopback to an unpublished container port until killed
//   e2e [--no-prompts]     the end-to-end run with the pinned opencode (writes docs/spikes/G6/e2e.json)
//   cleanup                remove every container, volume, network and image labelled bellocode.spike=1

import ContainerKit
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "status":
        let state = await RuntimeDiscovery().detect()
        print(state.userMessage)
    case "image":
        try await Spike.ensureImage()
    case "up":
        guard args.count >= 3 else { throw EngineError.progress("usage: up <dir> <config> [extra-mount...]") }
        try await Spike.ensureImage()
        let spec = Spike.spec(project: args[1], extra: Array(args.dropFirst(3)))
        let start = ContinuousClock.now
        let id = try await WorkspaceManager(client: Spike.client).ensureRunning(spec)
        log("workspace \(spec.containerName) running (\(String(format: "%.0f", ms(start))) ms)")
        try Spike.writeHelperConfig(spec, container: id, to: args[2])
        print(id)
    case "bench":
        guard args.count >= 2 else { throw EngineError.progress("usage: bench <dir>") }
        try await Bench.run(project: args[1])
    case "forward":
        guard args.count >= 3, let port = Int(args[2]) else { throw EngineError.progress("usage: forward <dir> <port>") }
        let status = try await WorkspaceManager(client: Spike.client).status(Spike.spec(project: args[1]))
        let forwarder = try PortForwarder(client: Spike.client, container: status.containerID!, containerPort: port)
        print("http://127.0.0.1:\(forwarder.hostPort)")
        fflush(stdout)
        await forwarder.run()
    case "e2e":
        try await EndToEnd.run(repo: FileManager.default.currentDirectoryPath, prompts: !args.contains("--no-prompts"))
    case "cleanup":
        try await Cleanup.run(images: args.contains("--images"))
    default:
        log("commands: status | image | up <dir> <config> | bench <dir> | forward <dir> <port> | cleanup [--images]")
        exit(2)
    }
} catch {
    log("error: \(error)")
    exit(1)
}
