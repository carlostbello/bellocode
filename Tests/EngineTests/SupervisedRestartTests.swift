import BelloCore
import Darwin
import Foundation
import MockOpenCode
import OpenCodeKit
import Synchronization
import Testing

@testable import Engine

/// A supervised "child" that is really the mock server: each launch reports the mock's URL and exits when its stdin
/// lease is released, so the supervisor runs its real state machine (new credentials and generation per start).
private final class MockBackedLauncher: ServerProcessLauncher {
    final class Child: ServerProcess {
        let pid: Int32
        private let url: URL
        private let gate: OneShot<Void>?
        private let exit = OneShot<ProcessExit>()

        init(pid: Int32, url: URL, gate: OneShot<Void>?) {
            self.pid = pid
            self.url = url
            self.gate = gate
        }

        func readyLine() async throws -> String? {
            try await gate?.value()
            return #"{"url":"\#(url.absoluteString)"}"#
        }
        func waitForExit() async throws -> ProcessExit { try await exit.value() }
        var exitStatus: ProcessExit? { exit.current }
        func closeStdin() { exit.fulfill(ProcessExit(reason: .exited, status: 0)) }
        func signal(_ signal: Int32) { exit.fulfill(ProcessExit(reason: .signaled, status: signal)) }
    }

    private let url: URL
    private let launched = Mutex<[Child]>([])
    /// Every launch after the first reports ready only once this opens.
    let restartGate = OneShot<Void>()

    init(url: URL) { self.url = url }

    var count: Int { launched.withLock { $0.count } }
    var latestPID: Int32? { launched.withLock { $0.last?.pid } }

    func launch(_ spec: LaunchSpec) async throws -> any ServerProcess {
        launched.withLock { children in
            let child = Child(pid: 4_000 + Int32(children.count), url: url, gate: children.isEmpty ? nil : restartGate)
            children.append(child)
            return child
        }
    }
}

/// The identity check passes for the child launched last.
private struct LatestChildProbe: ServerInfoProbe {
    let launcher: MockBackedLauncher

    func info(for connection: ServerConnection) async throws -> ServerInfo {
        guard let pid = launcher.latestPID else { throw URLError(.cannotConnectToHost) }
        return ServerInfo(version: "2.3.2", pid: Int(pid))
    }
}

private final class ReadLog: Sendable {
    private let entries = Mutex<[ServerConnection?]>([])
    func append(_ connection: ServerConnection?) { entries.withLock { $0.append(connection) } }
    var last: ServerConnection?? { entries.withLock { $0.last } }
    var count: Int { entries.withLock { $0.count } }
}

@MainActor
@Suite("Supervised restart from Settings", .serialized, .timeLimit(.minutes(3)))
struct SupervisedRestartTests {
    /// NF06: Restart Server (and a repository-config policy switch) refreshes the inventory from the restarted server,
    /// instead of reading while it is still down and showing an offline error.
    @Test func restartRefreshesFromTheNewServer() async throws {
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Auth off: the supervisor makes a fresh random password per launch, as with the real binary.
        let harness = try await MockHarness.start(options: MockServerOptions(password: nil, clock: .virtual, heartbeatInterval: nil))
        let launcher = MockBackedLauncher(url: harness.endpoint.url)
        let supervisor = ServerSupervisor(
            configuration: ServerConfiguration(executableURL: URL(fileURLWithPath: "/usr/bin/true"), dataRoot: root),
            launcher: launcher, probe: LatestChildProbe(launcher: launcher))
        var configuration = EngineConfiguration(server: .supervised(supervisor), store: .inMemory)
        configuration.eventBackoff = BackoffPolicy(initial: .milliseconds(20), maximum: .milliseconds(200))
        let engine = try Engine(configuration: configuration)
        await engine.start()
        do { try await waitUntil("live") { engine.root.connection == .live } } catch {
            Issue.record("supervisor: \(await supervisor.state), connection: \(engine.root.connection)")
            throw error
        }
        // The engine's own service, with its client reads recorded (the mock has no config routes to list).
        let core = engine.core
        let reads = ReadLog()
        let config = OpenCodeConfigService(
            store: try ProjectionStore(location: .inMemory), directories: supervisor.configuration.directories,
            runningPolicy: .bellocode,
            client: {
                do {
                    let client = try await core.currentClient()
                    reads.append(client.connection)
                    return client
                } catch {
                    reads.append(nil)
                    throw error
                }
            },
            restartServer: { await core.restartServer() })

        let restart = Task { await config.restart(policy: .bellocode, directory: nil) }
        // The new child is launched but not ready. Give a refresh that does not wait for it every chance to read now
        // (it would read within milliseconds); a correct restart reads nothing until the child is ready.
        try await waitUntil("new child launched") { launcher.count == 2 }
        let clock = ContinuousClock()
        let window = clock.now + .milliseconds(300)
        while reads.count == 0, clock.now < window { try await Task.sleep(for: .milliseconds(5)) }
        launcher.restartGate.fulfill(())
        #expect(await restart.value == nil)
        let restarted = try #require(await supervisor.endpoint)
        #expect(restarted.generation == 2)
        #expect(reads.last == .some(restarted.connection), "the refresh read from the restarted server, not while it was down")
        await engine.stop()
        await harness.stop()
    }
}
