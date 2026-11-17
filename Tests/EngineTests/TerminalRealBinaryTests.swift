import BelloCore
import Darwin
import Foundation
import OpenCodeKit
import Testing

@testable import Engine

/// M2-A terminal checks against the pinned opencode binary: the persistent-PTY contract as `TerminalService` uses it.
/// Skipped when `Vendor/` has no binary (run `Scripts/fetch-opencode.sh`). The server runs with HOME and XDG
/// directories under a fresh temporary directory (never the user's opencode config or data); shells start with
/// `zsh -f` and a sandbox HOME so no user rc file runs; every process is stopped before the test returns.
@MainActor
@Suite("Terminal real binary", .serialized, .enabled(if: EngineRepo.vendoredOpencode != nil, "run Scripts/fetch-opencode.sh"))
struct TerminalRealBinaryTests {
    @MainActor
    struct Sandbox {
        let root: URL
        let project: URL
        let supervisor: ServerSupervisor
        let client: OpenCodeClient
        let sessionID: SessionID
        let launch: TerminalLaunch

        static func start() async throws -> Sandbox {
            let executable = try #require(EngineRepo.vendoredOpencode)
            let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-term-\(UUID().uuidString)", directoryHint: .isDirectory)
            let project = root.appending(path: "project", directoryHint: .isDirectory)
            let home = root.appending(path: "home", directoryHint: .isDirectory)
            for url in [project, home] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            let supervisor = ServerSupervisor(
                configuration: ServerConfiguration(
                    executableURL: executable, dataRoot: root.appending(path: "server", directoryHint: .isDirectory),
                    expectedVersion: EngineRepo.pinnedVersion))
            await supervisor.start()
            let deadline = ContinuousClock.now + .seconds(30)
            var ready = await supervisor.endpoint
            while ready == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
                ready = await supervisor.endpoint
            }
            let endpoint = try #require(ready, "server did not become ready")
            let client = OpenCodeClient(endpoint: endpoint)
            let session = try await client.createSession(SessionCreateRequest(directory: project.path, title: "terminal"))
            let launch = TerminalLaunch(
                command: "/bin/zsh", args: ["-f"],
                environment: [
                    "HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
                    "PS1": "%~ %# ",
                ])
            return Sandbox(root: root, project: project, supervisor: supervisor, client: client, sessionID: SessionID(session.id), launch: launch)
        }

        func service(store: ProjectionStore) -> TerminalService {
            let client = self.client
            return TerminalService(store: store, client: { client }, launch: launch)
        }

        func stop() async {
            let pid = await supervisor.childPID
            await supervisor.stop()
            if let pid { #expect(kill(pid, 0) != 0, "server child \(pid) still running") }
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func createRunResizeReconnectRelaunchAndExit() async throws {
        let sandbox = try await Sandbox.start()
        let storeURL = sandbox.root.appending(path: "projection.sqlite")
        var store: ProjectionStore? = try ProjectionStore(location: .file(storeURL))
        var service: TerminalService? = sandbox.service(store: store!)
        let terminals = service!.terminals(for: sandbox.sessionID)

        // Create in the thread's directory and run a command.
        let record = try #require(await terminals.create(directory: sandbox.project.path, size: PTYSize(cols: 100, rows: 30)))
        #expect(record.id.hasPrefix("pty"))
        let sink = RecordingSink()
        let stream = service!.makeStream(record.id, in: terminals, sink: sink)
        stream.resize(to: PTYSize(cols: 100, rows: 30))
        stream.activate()
        try await waitFor("live", timeout: .seconds(15)) { stream.status == .live }
        stream.send(Array("echo marker-$((6*7)); pwd\r".utf8))
        try await waitFor("command output", timeout: .seconds(15)) { sink.text.contains("marker-42") }
        try await waitFor("pwd", timeout: .seconds(15)) { sink.text.contains(sandbox.project.lastPathComponent) }

        // The agent's view reads the same terminal.
        let read = try await sandbox.client.readTerminal(sessionID: sandbox.sessionID.rawValue)
        #expect(read?.ptyID == record.id)
        #expect(read?.screen.text.contains("marker-42") == true)

        // Resize: the shell sees the new grid (debounced, final size only).
        stream.resize(to: PTYSize(cols: 91, rows: 27))
        try await waitFor("resized", timeout: .seconds(5)) { (try? await sandbox.client.terminal(record.id).size) == PTYSize(cols: 91, rows: 27) }
        stream.send(Array("stty size\r".utf8))
        try await waitFor("stty", timeout: .seconds(10)) { sink.text.contains("27 91") }

        // Reconnect after closing the socket: output written meanwhile arrives once, nothing is repeated.
        stream.deactivate()
        try await Task.sleep(for: .milliseconds(200))
        let detachedCount = sink.output.count
        stream.activate()
        try await waitFor("re-attached", timeout: .seconds(10)) { stream.status == .live }
        stream.send(Array("echo after-$((1+1))\r".utf8))
        try await waitFor("after reconnect", timeout: .seconds(10)) { sink.text.contains("after-2") }
        #expect(sink.resets.count == 1, "re-attach continued from the cursor")
        #expect(!String(decoding: sink.output.dropFirst(detachedCount), as: UTF8.self).contains("marker-42"))
        stream.send(Array("export KEEP=kept-across-relaunch\r".utf8))
        try await Task.sleep(for: .milliseconds(300))

        // App restart: a new store and service (same server) restore the record and re-attach to the same shell.
        stream.deactivate()
        await terminals.save()
        await service!.shutdown()
        service = nil
        store = nil
        let store2 = try ProjectionStore(location: .file(storeURL))
        let service2 = sandbox.service(store: store2)
        let restored = service2.terminals(for: sandbox.sessionID)
        await restored.waitUntilLoaded()
        await restored.refresh()
        #expect(restored.record(record.id)?.state == .running)
        let sink2 = RecordingSink()
        let stream2 = service2.makeStream(record.id, in: restored, sink: sink2)
        stream2.resize(to: PTYSize(cols: 91, rows: 27))
        stream2.activate()
        try await waitFor("relaunch attach", timeout: .seconds(15)) { stream2.status == .live }
        try await waitFor("scrollback replayed", timeout: .seconds(10)) { sink2.text.contains("marker-42") }
        stream2.send(Array("echo $KEEP\r".utf8))
        try await waitFor("same shell", timeout: .seconds(10)) { sink2.text.contains("kept-across-relaunch\r\n") }

        // Exit code capture: the server forgets the PTY, the record keeps the code.
        stream2.send(Array("exit 5\r".utf8))
        try await waitFor("exited", timeout: .seconds(15)) { restored.record(record.id)?.state == .exited(code: 5) }
        #expect(stream2.status == .ended)
        #expect(try await sandbox.client.terminals(sessionID: sandbox.sessionID.rawValue).isEmpty)
        await restored.save()
        #expect(try await store2.terminalSet(sandbox.sessionID)?.record(record.id)?.state == .exited(code: 5))

        // Restart creates a new PTY in the same tab; close deletes it on the server.
        let restarted = try #require(await restored.restart(record.id))
        #expect(try await sandbox.client.terminals(sessionID: sandbox.sessionID.rawValue).map(\.id) == [restarted.id])
        await restored.close(restarted.id)
        #expect(try await sandbox.client.terminals(sessionID: sandbox.sessionID.rawValue).isEmpty)
        await service2.shutdown()
        await sandbox.stop()
    }
}
