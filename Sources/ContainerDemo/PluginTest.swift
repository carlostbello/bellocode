import ContainerKit
import Darwin
import Foundation

/// `make plugin-test`: the bundled opencode plugin's `bun test`, run in a throwaway container (bun is never installed
/// or run on the Mac). The plugin folder is mounted read-only, the network is off, the container runs as the user with
/// no capabilities and is removed afterwards. Image: `BELLOCODE_BUN_IMAGE` (default `oven/bun:1.2`; point it at the
/// internal registry in an enterprise setup).
enum PluginTest {
    static func run(pluginDirectory: String) async throws -> Int32 {
        let image = ProcessInfo.processInfo.environment["BELLOCODE_BUN_IMAGE"] ?? "oven/bun:1.2"
        let state = await RuntimeDiscovery().detect()
        guard case .ready(let ready) = state else { throw DemoError("plugin-test needs the container runtime: \(state.userMessage)") }
        let client = EngineClient(socketPath: ready.socketPath)
        if try await client.inspectImage(image) == nil {
            log("pulling \(image)")
            try await client.pullImage(image)
        }
        let directory = URL(filePath: pluginDirectory).standardizedFileURL.path
        var spec = ContainerCreate(image: image)
        spec.cmd = ["bun", "test"]
        spec.workingDir = "/plugin"
        spec.env = ["HOME=/tmp", "BUN_INSTALL_CACHE_DIR=/tmp/bun-cache", "NO_COLOR=1"]
        spec.user = "\(getuid()):\(getgid())"
        spec.labels = ["app.bellocode.test": "1", "app.bellocode.plugin-test": "1"]
        var host = HostConfig()
        host.mounts = [Mount(type: .bind, source: directory, target: "/plugin", readOnly: true)]
        host.networkMode = "none"
        host.capDrop = ["ALL"]
        host.securityOpt = ["no-new-privileges"]
        spec.hostConfig = host
        let id = try await client.createContainer(name: nil, spec)
        do {
            let started = ContinuousClock.now
            try await client.startContainer(id)
            let code = try await client.waitContainer(id)
            var output = Data()
            for try await chunk in try await client.logs(id, follow: false, tail: "all") {
                output.append(chunk.bytes)
                if output.count > 1 << 20 { break }
            }
            FileHandle.standardOutput.write(output)
            log("bun test exited \(code) in \(Int(ms(started))) ms (\(image), in a container)")
            try? await client.removeContainer(id, force: true)
            return Int32(truncatingIfNeeded: code)
        } catch {
            try? await client.removeContainer(id, force: true)
            throw error
        }
    }
}
