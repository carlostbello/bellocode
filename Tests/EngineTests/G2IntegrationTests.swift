import BelloCore
import Darwin
import Foundation
import OpenCodeKit
import Testing

@testable import Engine

enum EngineRepo {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static var pinnedVersion: String? {
        try? String(contentsOf: root.appending(path: "Scripts/opencode-version"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var vendoredOpencode: URL? {
        guard let version = pinnedVersion else { return nil }
        let url = root.appending(path: "Vendor/opencode/\(version)/opencode")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Gate G2 is opt-in: it sends one real prompt (on a zero-cost model) and needs network.
    static var g2Enabled: Bool { ProcessInfo.processInfo.environment["BELLOCODE_G2"] == "1" && vendoredOpencode != nil }
}

/// Gate G2 (docs/PLAN.md section 5): kill the real server mid-stream; after the supervisor restarts it and the engine
/// resyncs, the cached transcript equals the list endpoints with no lost or duplicated messages.
///
/// Run with `BELLOCODE_G2=1 swift test --filter G2`. Uses the vendored binary with isolated XDG and HOME directories in
/// a temporary directory (never the user's opencode config or data), sends one short prompt to a free built-in model,
/// and stops every process it started.
@Suite("G2 real server", .serialized, .enabled(if: EngineRepo.g2Enabled, "set BELLOCODE_G2=1 and run Scripts/fetch-opencode.sh"))
@MainActor
struct G2IntegrationTests {
    @Test func killMidStreamThenResyncMatchesListEndpoints() async throws {
        let executable = try #require(EngineRepo.vendoredOpencode)
        let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-g2-\(UUID().uuidString)", directoryHint: .isDirectory)
        let project = root.appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "G2 test project\n".write(to: project.appending(path: "README.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let supervisor = ServerSupervisor(
            configuration: ServerConfiguration(
                executableURL: executable, dataRoot: root.appending(path: "server", directoryHint: .isDirectory),
                helpersDirectory: EngineRepo.root.appending(path: "Vendor/ripgrep", directoryHint: .isDirectory),
                expectedVersion: EngineRepo.pinnedVersion))
        var configuration = EngineConfiguration(server: .supervised(supervisor), store: .file(root.appending(path: "projection.sqlite")))
        configuration.defaultDirectory = project.path
        configuration.eventBackoff = BackoffPolicy(initial: .milliseconds(50), maximum: .seconds(1))
        let engine = try Engine(configuration: configuration)
        let clock = ContinuousClock()
        var killedPID: Int32?
        var pids: Set<Int32> = []

        do {
            await engine.start()
            try await waitUntil("live", timeout: .seconds(60)) { engine.root.connection == .live }
            if let pid = await supervisor.childPID { pids.insert(pid) }

            // A zero-cost built-in model only.
            await engine.refreshCatalog(directory: project.path)
            let catalog = try #require(engine.root.catalog.catalog(for: project.path))
            let free = catalog.models.filter { $0.isFree && $0.providerID == "opencode" && $0.enabled }
            let model = try #require(free.first { $0.modelID == catalog.defaultModel?.modelID } ?? free.first, "no free model")
            print("G2: model \(model.id) (free: \(model.isFree)), \(free.count) free models")

            let session = try await engine.createThread(in: project.path, title: "G2", agent: "build", model: model.selection)
            let thread = engine.openThread(session.id)
            try await waitUntil("thread ready") { thread.phase == .ready }
            let sendStart = clock.now
            let sent = await thread.send("Without using any tools, write three short paragraphs about the sea.")
            #expect(sent != nil, "send failed: \(String(describing: thread.lastError))")

            // Reject any tool permission (none expected), and kill the server as soon as text is streaming.
            var killedAt: Duration?
            var resyncsBeforeKill = 0
            while clock.now - sendStart < .seconds(120) {
                if case .permission(let request) = thread.pendingRequests.first(where: \.isPermission) {
                    await thread.reply(to: request.id, .reject)
                }
                let streaming = thread.messageIDs.compactMap { thread.message($0)?.message }.contains { message in
                    message.parts.contains { part in
                        if case .text(let text) = part.content { part.isStreaming && text.count > 20 } else { false }
                    }
                }
                if streaming, let pid = await supervisor.childPID {
                    resyncsBeforeKill = await engine.core.statistics.resyncs
                    kill(pid, SIGKILL)
                    killedPID = pid
                    killedAt = clock.now - sendStart
                    break
                }
                if thread.status?.status == .finishedUnread || thread.status?.status == .failed { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let killed = try #require(killedPID, "the turn ended before streaming was observed")
            print("G2: SIGKILL pid \(killed) at \(killedAt.map { "\($0)" } ?? "?") after send")

            // The supervisor restarts the server; the engine reconnects and resyncs.
            let restartStart = clock.now
            try await waitUntil("restarted", timeout: .seconds(60)) {
                engine.root.connection == .live
            }
            let restartDeadline = clock.now + .seconds(60)
            while clock.now < restartDeadline {
                if let pid = await supervisor.childPID, pid != killed, await supervisor.endpoint != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            if let pid = await supervisor.childPID { pids.insert(pid) }
            while clock.now < restartDeadline {
                let resyncs = await engine.core.statistics.resyncs
                if resyncs > resyncsBeforeKill, engine.root.connection == .live { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let resyncs = await engine.core.statistics.resyncs
            #expect(engine.root.connection == .live)
            print("G2: back to live \(clock.now - restartStart) after the kill; resyncs \(resyncs)")
            #expect(resyncs > resyncsBeforeKill)

            // Compare the cache and the open thread with the list endpoints.
            try await Task.sleep(for: .milliseconds(500))
            await engine.flush()
            let client = try await engine.core.currentClient()
            let after = try await client.session(session.id.rawValue)
            print("G2: server session after restart: busy \(after.time.busy as Any) idle \(after.time.idle as Any) outcome \(after.outcome as Any); shown status \(thread.status?.status.label ?? "-")")
            var listed: [Message] = []
            var cursor: String?
            repeat {
                let page = try await client.messages(
                    sessionID: session.id.rawValue, MessageListQuery(limit: 200, order: cursor == nil ? .ascending : nil, cursor: cursor))
                listed += page.data.map { Mapping.message($0, sessionID: session.id) }
                cursor = page.data.count < 200 ? nil : page.cursor.next
            } while cursor != nil
            let cached = try await engine.store.allMessages(sessionID: session.id)
            let shown = thread.messageIDs.compactMap { thread.message($0)?.message }
            print("G2: listed \(listed.map(\.kind.typeName)), cached \(cached.count), shown \(shown.count)")
            #expect(!listed.isEmpty)
            #expect(Set(cached.map(\.id)).count == cached.count, "no duplicated messages")
            #expect(cached.map(\.id) == listed.sorted { $0.sortKey < $1.sortKey }.map(\.id), "no lost or extra messages")
            #expect(normalized(cached) == normalized(listed))
            #expect(normalized(shown) == normalized(listed))
            #expect(listed.filter { $0.kind.typeName == "user" }.count == 1)
            // What the server does with the orphaned turn a little later (observation only).
            try await Task.sleep(for: .seconds(3))
            let later = try await client.session(session.id.rawValue)
            let laterMessages = try await client.messages(sessionID: session.id.rawValue, MessageListQuery(limit: 10, order: .ascending)).data
            let laterAssistant = laterMessages.compactMap { if case .assistant(let a) = $0 { a } else { nil } }.last
            print("G2: 3 s later: busy \(later.time.busy as Any) idle \(later.time.idle as Any) outcome \(later.outcome as Any); assistant finish \(laterAssistant?.finish as Any) error \(laterAssistant?.error?.type as Any) completed \(laterAssistant?.time.completed as Any); shown status \(thread.status?.status.label ?? "-")")
            thread.close()
        } catch {
            await engine.stop()
            throw error
        }
        await engine.stop()
        // Nothing left running.
        for pid in pids {
            let gone = kill(pid, 0) != 0 && errno == ESRCH
            #expect(gone, "process \(pid) still running")
        }
    }
}
