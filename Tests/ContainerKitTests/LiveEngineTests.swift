import Foundation
import Testing

@testable import ContainerKit

/// Opt-in checks against a real Rancher Desktop (dockerd): `BELLOCODE_CONTAINER_TESTS=1 swift test --filter Live`.
/// Uses the already-present `node:22-bookworm-slim` image (pulls it if missing) and removes what it creates.
@Suite("Live Engine API", .serialized, .timeLimit(.minutes(10)), .enabled(if: ProcessInfo.processInfo.environment["BELLOCODE_CONTAINER_TESTS"] == "1"))
struct LiveEngineTests {
    let client = EngineClient(socketPath: NSHomeDirectory() + "/.rd/docker.sock")

    @Test func discoveryIsReady() async {
        #expect(await RuntimeDiscovery().detect().isReady)
    }

    @Test func execRoundTripAndCancel() async throws {
        let image = "node:22-bookworm-slim"
        if try await client.inspectImage(image) == nil { try await client.pullImage(image) }
        var spec = ContainerCreate(image: image)
        spec.entrypoint = ["sleep"]
        spec.cmd = ["infinity"]
        spec.labels = ["app.bellocode.test": "1"]
        var host = HostConfig()
        host.init_ = true
        spec.hostConfig = host
        let id = try await client.createContainer(name: nil, spec)
        defer { Task { [client] in try? await client.removeContainer(id, force: true) } }
        try await client.startContainer(id)

        let result = try await ExecSession.run(client: client, container: id, argv: ["sh", "-c", "echo out; echo err >&2; exit 4"])
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err\n")
        #expect(result.exitCode == 4)

        // Closing stdin cancels: the wrapper kills the whole group.
        let session = try await ExecSession.start(client: client, container: id,
                                                  argv: ExecWrapper.nonInteractive(["sh", "-c", "sleep 50 & sleep 60"]),
                                                  workingDir: "/", environment: [:], tty: false)
        try await Task.sleep(for: .milliseconds(300))
        session.closeStdin()
        for try await _ in session.output() {}
        #expect(try await session.exitCode() == 143)
        try await Task.sleep(for: .milliseconds(2300))
        let ps = try await ExecSession.run(client: client, container: id, argv: ["sh", "-c", "ps -eo args | grep -c '^sleep [56]0' || true"], wrap: false)
        #expect(String(decoding: ps.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "0")
        try await client.removeContainer(id, force: true)
    }
}
