import BelloCore
import Darwin
import Foundation
import OpenCodeKit
import Testing

@testable import Engine

/// M4 (docs/reviews/M1-review.md): what the pinned opencode does with a prompt re-sent under the same ID, the basis of
/// the engine's "retry a lost answer with the same ID" and "reconcile by ID" rules.
///
/// Opt-in: `BELLOCODE_PROMPT_ID=1 swift test --filter PromptRetryRealBinary`. Uses the vendored binary with isolated
/// XDG/HOME directories in a temporary directory (never the user's opencode config or data), sends the same short
/// prompt twice under one ID to a free built-in model, and stops every process it started.
@Suite(
    "Prompt retry against the real server", .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["BELLOCODE_PROMPT_ID"] == "1" && EngineRepo.vendoredOpencode != nil,
        "set BELLOCODE_PROMPT_ID=1 and run Scripts/fetch-opencode.sh"),
    .timeLimit(.minutes(10)))
@MainActor
struct PromptRetryRealBinaryTests {
    @Test func samePromptIDIsAdmittedOnce() async throws {
        let executable = try #require(EngineRepo.vendoredOpencode)
        let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-m4-\(UUID().uuidString)", directoryHint: .isDirectory)
        let project = root.appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "M4 test project\n".write(to: project.appending(path: "README.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = ServerSupervisor(
            configuration: ServerConfiguration(
                executableURL: executable, dataRoot: root.appending(path: "server", directoryHint: .isDirectory),
                helpersDirectory: EngineRepo.root.appending(path: "Vendor/ripgrep", directoryHint: .isDirectory),
                expectedVersion: EngineRepo.pinnedVersion))
        var configuration = EngineConfiguration(server: .supervised(supervisor), store: .inMemory)
        configuration.defaultDirectory = project.path
        let engine = try Engine(configuration: configuration)
        var pids: Set<Int32> = []
        do {
            await engine.start()
            try await waitUntil("live", timeout: .seconds(60)) { engine.root.connection == .live }
            if let pid = await supervisor.childPID { pids.insert(pid) }
            await engine.refreshCatalog(directory: project.path)
            let catalog = try #require(engine.root.catalog.catalog(for: project.path))
            let free = catalog.models.filter { $0.isFree && $0.providerID == "opencode" && $0.enabled }
            let model = try #require(free.first { $0.modelID == catalog.defaultModel?.modelID } ?? free.first, "no free model")
            print("M4: model \(model.id) (free: \(model.isFree))")
            let session = try await engine.createThread(in: project.path, title: "M4", agent: "build", model: model.selection)
            let client = try await engine.core.currentClient()
            var ids = IdentifierFactory()
            let id = ids.messageID(now: .now).rawValue
            let request = PromptRequest(text: "Reply with the single word: ok. Do not use tools.", id: id)

            // Before admission the ID is unknown to both lookups the engine reconciles with.
            do {
                _ = try await client.message(sessionID: session.id.rawValue, messageID: id)
                print("M4: message lookup before send: found (unexpected)")
            } catch let error as OpenCodeError {
                print("M4: message lookup before send: HTTP \(error.status.map(String.init) ?? "-") tag \(error.tag.map { "\($0)" } ?? "-")")
            }

            let first = try await client.prompt(sessionID: session.id.rawValue, request)
            print("M4: first send: id \(first.id == id ? "same" : "different") delivery \(first.delivery)")
            var secondOutcome = "accepted"
            do {
                let second = try await client.prompt(sessionID: session.id.rawValue, request)
                secondOutcome = "200, id \(second.id == id ? "same" : "different"), delivery \(second.delivery)"
            } catch let error as OpenCodeError {
                secondOutcome = "HTTP \(error.status.map(String.init) ?? "-") tag \(error.tag.map { "\($0)" } ?? "-")"
            }
            print("M4: second send with the same ID: \(secondOutcome)")

            // Wait for the turn to finish, then count user messages with that ID.
            let clock = ContinuousClock()
            let start = clock.now
            var listed: [SessionMessage] = []
            while clock.now - start < .seconds(90) {
                let info = try await client.session(session.id.rawValue)
                listed = try await client.messages(sessionID: session.id.rawValue, MessageListQuery(limit: 50, order: .ascending)).data
                let busy = info.time.busy.map { busy in info.time.idle.map { busy > $0 } ?? true } ?? false
                if !busy, listed.contains(where: { if case .assistant = $0 { true } else { false } }) { break }
                try await Task.sleep(for: .milliseconds(250))
            }
            let users = listed.filter { if case .user = $0 { true } else { false } }
            let sameID = users.filter { $0.id == id }
            print("M4: after the turn: \(users.count) user message(s), \(sameID.count) with the prompt ID; inbox \(try await client.inbox(sessionID: session.id.rawValue).count)")
            let found = try? await client.message(sessionID: session.id.rawValue, messageID: id)
            print("M4: message lookup after delivery: \(found == nil ? "not found" : "found")")
            #expect(sameID.count == 1, "the same ID must be admitted at most once")
            #expect(users.count == 1)
            #expect(found != nil)
        } catch {
            await engine.stop()
            throw error
        }
        await engine.stop()
        for pid in pids {
            let gone = kill(pid, 0) != 0 && errno == ESRCH
            #expect(gone, "process \(pid) still running")
        }
    }
}
