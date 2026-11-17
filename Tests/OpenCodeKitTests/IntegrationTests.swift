import Darwin
import Foundation
import Synchronization
import Testing
@testable import OpenCodeKit

/// Records every message a subscription delivers, with arrival times, for assertions from the test body.
final class MessageRecorder: Sendable {
    struct Entry: Sendable {
        let at: ContinuousClock.Instant
        let message: EventHubMessage
    }

    private let entries = Mutex<[Entry]>([])

    var all: [Entry] { entries.withLock { $0 } }

    func record(_ message: EventHubMessage) {
        entries.withLock { $0.append(Entry(at: .now, message: message)) }
    }

    func first(where predicate: (EventHubMessage) -> Bool) -> Entry? {
        entries.withLock { $0.first { predicate($0.message) } }
    }

    func waitFor(
        _ what: String, timeout: Duration = .seconds(15), _ predicate: @escaping @Sendable (EventHubMessage) -> Bool
    ) async throws -> Entry {
        do {
            try await eventually(timeout: timeout) { self.first(where: predicate) != nil }
        } catch {
            Issue.record("timed out waiting for \(what)")
            throw error
        }
        return first(where: predicate)!
    }
}

private func processExists(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno != ESRCH
}

/// Child pids of `pid`, via pgrep.
private func childPIDs(of pid: Int32) throws -> [Int32] {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-P", String(pid)]
    let output = Pipe()
    pgrep.standardOutput = output
    try pgrep.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    pgrep.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
}

private func ms(_ duration: Duration) -> Int64 { duration.milliseconds }

/// Integration tests against the pinned opencode binary in Vendor/. Skipped when it has not been fetched.
/// Every server runs with isolated XDG and HOME directories in a fresh temporary directory, no model prompt is sent,
/// and every child is stopped (and checked gone) before the test returns.
@Suite("opencode integration", .serialized, .enabled(if: Repo.vendoredOpencode != nil, "run Scripts/fetch-opencode.sh"), .timeLimit(.minutes(3)))
struct OpencodeIntegrationTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "bellocode-it-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func makeSupervisor() throws -> ServerSupervisor {
        let executable = try #require(Repo.vendoredOpencode)
        let configuration = ServerConfiguration(
            executableURL: executable,
            dataRoot: root.appending(path: "server", directoryHint: .isDirectory),
            helpersDirectory: Repo.root.appending(path: "Vendor/ripgrep", directoryHint: .isDirectory),
            expectedVersion: Repo.pinnedVersion
        )
        return ServerSupervisor(configuration: configuration)
    }

    /// Runs `body` with a started supervisor and always stops it and removes the temporary directory.
    private func withServer(_ body: (ServerSupervisor) async throws -> Void) async throws {
        let supervisor = try makeSupervisor()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try await body(supervisor)
        } catch {
            await supervisor.stop()
            throw error
        }
        await supervisor.stop()
    }

    @Test func lifecycleSessionsEventsCrashRestartAndStop() async throws {
        try await withServer { supervisor in
            let clock = ContinuousClock()

            // Start and verify identity.
            let launched = clock.now
            await supervisor.start()
            let endpoint = try await within(.seconds(30)) { try await supervisor.awaitReady() }
            let readyTime = clock.now - launched
            #expect(endpoint.baseURL.host() == "127.0.0.1")
            let firstPID = try #require(await supervisor.childPID)
            #expect(endpoint.pid == Int(firstPID))

            let client = OpenCodeClient(endpoint: endpoint)
            let info = try await client.info()
            #expect(info.pid == endpoint.pid)
            #expect(info.version == Repo.pinnedVersion)

            // The per-launch password is required.
            let wrong = OpenCodeClient(
                connection: ServerConnection(baseURL: endpoint.baseURL, credentials: ServerCredentials(password: "wrong"))
            )
            do {
                _ = try await wrong.info()
                Issue.record("unauthenticated request succeeded")
            } catch let error as OpenCodeError {
                #expect(error.status == 401)
                #expect(error.tag == .unauthorized)
            }

            // The isolated data directory is in use; the user's own is not touched (we never pass it).
            let dataRoot = supervisor.configuration.dataRoot
            try await eventually(timeout: .seconds(5)) {
                FileManager.default.fileExists(atPath: dataRoot.appending(path: "data/opencode").path)
            }

            // Subscribe before issuing work.
            let hub = EventHub(connector: URLSessionEventStreamConnector(supervisor: supervisor))
            let recorder = MessageRecorder()
            let subscription = await hub.subscribe()
            let consumer = Task {
                for await message in subscription { recorder.record(message) }
            }
            defer { consumer.cancel() }
            await hub.start()
            _ = try await recorder.waitFor("first resync") {
                if case .resync(.connected(1)) = $0 { true } else { false }
            }

            // A session in a temporary project directory.
            let project = root.appending(path: "project", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try Data("# test\n".utf8).write(to: project.appending(path: "README.md"))
            let createStarted = clock.now
            let session = try await client.createSession(SessionCreateRequest(directory: project.path, title: "integration"))
            let createReturned = clock.now
            #expect(session.title == "integration")
            #expect(session.id.hasPrefix("ses_"))
            let created = try await recorder.waitFor("session.created") {
                if case .event(let envelope) = $0, case .sessionCreated(let payload) = envelope.event {
                    payload.sessionID == session.id
                } else {
                    false
                }
            }
            let directory = session.location.directory

            // Reads and update.
            #expect(try await client.session(session.id).id == session.id)
            let page = try await client.sessions(SessionListQuery(directory: directory, parent: .root, limit: 10))
            #expect(page.data.contains { $0.id == session.id })
            try await client.updateSession(session.id, SessionUpdateRequest(title: "renamed"))
            _ = try await recorder.waitFor("session.renamed") {
                if case .event(let envelope) = $0, case .sessionRenamed(let payload) = envelope.event {
                    payload.sessionID == session.id && payload.title == "renamed"
                } else {
                    false
                }
            }
            #expect(try await client.session(session.id).title == "renamed")
            let messages = try await client.messages(sessionID: session.id, MessageListQuery(limit: 20))
            #expect(messages.data.isEmpty)
            #expect(try await client.pendingPermissions(directory: directory).isEmpty)
            #expect(try await client.permissions(sessionID: session.id).isEmpty)
            #expect(try await client.pendingForms(directory: directory).isEmpty)
            #expect(try await client.forms(sessionID: session.id).isEmpty)
            #expect(try await client.interrupt(sessionID: session.id) == false)
            let projects = try await client.projects()
            #expect(projects.contains { $0.id == session.projectID })

            // Catalogs for the location.
            let agents = try await client.agents(directory: directory)
            #expect(agents.contains { $0.id == "build" })
            let providers = try await client.providers(directory: directory)
            let models = try await client.models(directory: directory)
            let defaultModel = try await client.defaultModel(directory: directory)
            print("G2: catalog agents=\(agents.count) providers=\(providers.count) models=\(models.count) default=\(defaultModel?.ref.id ?? "none")")

            // Kill the child; the supervisor restarts it with a new pid, port and password.
            let killed = clock.now
            #expect(kill(firstPID, SIGKILL) == 0)
            let restarted = try await within(.seconds(30)) {
                for await state in await supervisor.states() {
                    if let endpoint = state.endpoint, endpoint.generation == 2 { return endpoint }
                }
                throw CancellationError()
            }
            let restartTime = clock.now - killed
            #expect(restarted.pid != endpoint.pid)
            #expect(restarted.connection.credentials != endpoint.connection.credentials)
            #expect(!processExists(firstPID))

            // The hub notices, reconnects to the new endpoint and asks for a resync.
            _ = try await recorder.waitFor("disconnect after kill") {
                if case .disconnected = $0 { true } else { false }
            }
            let resync = try await recorder.waitFor("second resync") {
                if case .resync(.connected(2)) = $0 { true } else { false }
            }

            // Data survived (same isolated data directory); the old credentials no longer work anywhere.
            let client2 = OpenCodeClient(endpoint: restarted)
            #expect(try await client2.session(session.id).title == "renamed")
            try await client2.deleteSession(session.id)
            _ = try await recorder.waitFor("session.deleted") {
                if case .event(let envelope) = $0, case .sessionDeleted(let payload) = envelope.event {
                    payload.sessionID == session.id
                } else {
                    false
                }
            }

            // Stop: the hub first, then the server; nothing may be left running.
            let secondPID = try #require(await supervisor.childPID)
            let helpers = try childPIDs(of: secondPID)
            await hub.stop()
            let stopping = clock.now
            await supervisor.stop()
            let stopTime = clock.now - stopping
            #expect(await supervisor.state == .stopped)
            #expect(!processExists(secondPID))
            try await eventually(timeout: .seconds(5)) { helpers.allSatisfy { !processExists($0) } }

            let entries = recorder.all
            let types = entries.compactMap { entry -> String? in
                switch entry.message {
                case .event(let envelope): envelope.type
                case .resync(.connected(let n)): "<resync \(n)>"
                case .resync(.overflow): "<overflow>"
                case .disconnected: "<disconnected>"
                }
            }
            print("G2: ready \(ms(readyTime)) ms; restart after SIGKILL \(ms(restartTime)) ms; stop \(ms(stopTime)) ms")
            print("G2: create returned after \(ms(createReturned - createStarted)) ms; session.created arrived \(ms(created.at - createReturned)) ms after the response")
            print("G2: hub resync \(ms(resync.at - killed)) ms after the kill")
            print("G2: helpers under server: \(helpers.count)")
            print("G2: event order: \(types.joined(separator: " "))")
            #expect(await hub.statistics.unknownFrames == 0)
        }
    }

    @Test func stopDuringStartupLeavesNoChild() async throws {
        try await withServer { supervisor in
            await supervisor.start()
            // Stop as soon as a child exists, before or during readiness.
            try await eventually(timeout: .seconds(10)) { await supervisor.childPID != nil }
            let pid = try #require(await supervisor.childPID)
            await supervisor.stop()
            #expect(await supervisor.state == .stopped)
            #expect(!processExists(pid))
        }
    }
}
