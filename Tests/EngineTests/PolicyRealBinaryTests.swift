import BelloCore
import Foundation
import OpenCodeKit
import Testing

@testable import Engine

/// S2/Q1 (docs/reviews/deep-review-1.md) on the real pinned opencode: what the server reports after each step of
/// creating a thread with a permission mode and switching its agent. No model prompt is sent. Opt-in
/// (`BELLOCODE_POLICY_REAL=1`), isolated XDG/HOME in a temporary directory, every process stopped.
@Suite(
    "Permission policy on the real server", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BELLOCODE_POLICY_REAL"] == "1" && EngineRepo.vendoredOpencode != nil,
             "set BELLOCODE_POLICY_REAL=1 and run Scripts/fetch-opencode.sh"),
    .timeLimit(.minutes(10)))
@MainActor
struct PolicyRealBinaryTests {
    @Test func createWithRulesSwitchAgentAndUpdateRulesAsReportedByTheServer() async throws {
        let executable = try #require(EngineRepo.vendoredOpencode)
        let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-policy-\(UUID().uuidString)", directoryHint: .isDirectory)
        let project = root.appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = ServerSupervisor(
            configuration: ServerConfiguration(
                executableURL: executable, dataRoot: root.appending(path: "server", directoryHint: .isDirectory),
                helpersDirectory: EngineRepo.root.appending(path: "Vendor/ripgrep", directoryHint: .isDirectory),
                expectedVersion: EngineRepo.pinnedVersion))
        var configuration = EngineConfiguration(server: .supervised(supervisor), store: .file(root.appending(path: "projection.sqlite")))
        configuration.defaultDirectory = project.path
        configuration.startsExtras = false
        configuration.secretVault = InMemorySecretVault()
        let engine = try Engine(configuration: configuration)
        await engine.start()
        defer { Task { await engine.stop() } }
        try await waitUntil("live", timeout: .seconds(60)) { engine.root.connection == .live }
        let client = try await engine.core.currentClient()
        func report(_ step: String, _ id: String) async throws -> SessionInfo {
            let info = try await client.session(id)
            let rules = (info.permissions ?? []).map { "\($0.action) \($0.resource) \($0.effect.rawValue)" }
            print("POLICY \(step): agent=\(info.agent ?? "nil") mode=\(info.permissions.flatMap(PermissionModeRules.mode(from:))?.rawValue ?? "nil") rules=\(rules)")
            return info
        }

        // 1. Created with a mode in one request: the server reports the rules at once.
        let session = try await engine.createThread(in: project.path, title: "policy", agent: "build", permissionMode: .ask)
        let created = try await report("created(build, ask)", session.id.rawValue)
        #expect(created.permissions.flatMap(PermissionModeRules.mode(from:)) == .ask)

        // 2. Agent switch with the mode: agent and rules both confirmed.
        try await engine.setAgent("plan", for: session.id)
        let switched = try await report("setAgent(plan)", session.id.rawValue)
        #expect(switched.agent == "plan")
        #expect(switched.permissions?.contains { $0.action == "edit" && $0.effect == .deny } == true, "plan's edit deny is kept after the mode's rules")

        // 3. Raw steps: switchAgent alone leaves the rules as they were (the two-stage window the engine closes).
        try await client.switchAgent(sessionID: session.id.rawValue, agent: "build")
        let raw = try await report("raw switchAgent(build)", session.id.rawValue)
        #expect(raw.agent == "build")
        #expect(raw.permissions == switched.permissions, "switching the agent does not touch session rules")

        // 4. Unknown agent: rejected, nothing changes.
        do {
            try await engine.setAgent("no-such-agent", for: session.id)
            Issue.record("an unknown agent was accepted")
        } catch {
            print("POLICY setAgent(no-such-agent) error: \(error)")
        }
        let after = try await report("after rejected switch", session.id.rawValue)
        #expect(after.agent == "build")

        // 5. Mode change confirmed by the server.
        try await engine.setPermissionMode(.fullAccess, for: session.id)
        let full = try await report("setPermissionMode(fullAccess)", session.id.rawValue)
        #expect(full.permissions.flatMap(PermissionModeRules.mode(from:)) == .fullAccess)

        // 6. A child created under an "ask" parent without rules of its own (what the plugin did before S2): the server
        // does not copy the parent's rules, so the plugin must pass them.
        try await engine.setPermissionMode(.ask, for: session.id)
        let child = try await client.createSession(SessionCreateRequest(directory: project.path, parentID: session.id.rawValue, agent: "general"))
        let childInfo = try await report("child without rules", child.id)
        print("POLICY child inherits parent rules: \(childInfo.permissions == (try await client.session(session.id.rawValue)).permissions)")
    }
}
