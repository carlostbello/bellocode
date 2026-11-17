import BelloCore
import Darwin
import Foundation
import OpenCodeKit
import Testing

@testable import Engine

/// M1-D contract checks against the pinned opencode binary. No model is prompted. Every server and CLI runs with HOME
/// and XDG directories under a fresh temporary directory (never the user's opencode config or data), and every
/// process started here is stopped before the test returns.
///
/// Run with `BELLOCODE_CONTRACT_REAL=1 swift test --filter AgentRealBinary` after `Scripts/fetch-opencode.sh`.
@Suite(
    "Agent UI real binary", .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["BELLOCODE_CONTRACT_REAL"] == "1" && EngineRepo.vendoredOpencode != nil,
        "set BELLOCODE_CONTRACT_REAL=1 and run Scripts/fetch-opencode.sh"),
    .timeLimit(.minutes(10)))
@MainActor
struct AgentRealBinaryTests {
    /// A supervised real server in its own sandbox.
    struct Sandbox {
        let root: URL
        let project: URL
        let supervisor: ServerSupervisor
        let client: OpenCodeClient

        static func start(_ name: String) async throws -> Sandbox {
            let executable = try #require(EngineRepo.vendoredOpencode)
            let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
            let project = root.appending(path: "project", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
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
            // A new location activates lazily; until then agents and integrations answer empty lists or 404.
            for _ in 0..<100 {
                let agents = (try? await client.agents(directory: project.path)) ?? []
                let integrations = (try? await client.integrations(directory: project.path)) ?? []
                if !agents.isEmpty, !integrations.isEmpty { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            return Sandbox(root: root, project: project, supervisor: supervisor, client: client)
        }

        /// The server's data root in the layout `CredentialImportSource.sandbox` expects.
        var dataRoot: URL { root.appending(path: "server", directoryHint: .isDirectory) }

        func stop() async {
            let pid = await supervisor.childPID
            await supervisor.stop()
            if let pid { #expect(kill(pid, 0) != 0, "server child \(pid) still running") }
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func integrationListAndFakeKeyConnect() async throws {
        let sandbox = try await Sandbox.start("auth")
        let client = sandbox.client
        let service = AuthService(
            client: { client }, directory: { sandbox.project.path }, openURL: { _ in }, pollInterval: .milliseconds(500),
            emptyListRetries: 20)
        await service.refresh()
        print("M1-D real: \(service.integrations.count) integrations")
        #expect(service.integrations.count > 100)
        let kinds = Set(service.integrations.flatMap { $0.methods.map { "\($0.kind)" } })
        print("M1-D real: method kinds \(kinds.sorted())")
        #expect(kinds.isSuperset(of: ["key", "oauth", "environment"]))
        #expect(service.integration("openai")?.methods.contains { $0.kind == .oauth } == true)

        // 2.3.0 stores any key without contacting the provider (recorded in docs/features/agent-ui.md).
        await service.connectKey(integrationID: "openrouter", key: "sk-bellocode-obviously-fake-0000")
        print("M1-D real: fake key connect -> \(String(describing: service.flow?.phase))")
        #expect(service.flow?.phase == .succeeded)
        #expect(service.credentials(for: "openrouter").first?.isActive == true)
        // A missing required form field is refused with the server's reason.
        await service.connectKey(integrationID: "azure", key: "sk-bellocode-obviously-fake-0000")
        #expect(service.flow?.phase == .failed(message: "Missing required form field: resourceName"))
        // Clean up the fake credential.
        for credential in service.credentials { await service.remove(credential.id) }
        #expect(service.credentials.isEmpty)
        await sandbox.stop()
    }

    @Test func permissionModesEvaluateAsMapped() async throws {
        let sandbox = try await Sandbox.start("modes")
        do {
            let client = sandbox.client
            let directory = sandbox.project.path
            let probes: [(String, String, String)] = [
                ("read", directory + "/a.swift", "read"), ("read", directory + "/.env", "env"), ("edit", directory + "/a.swift", "edit"),
                ("shell", "rm -rf build", "shell"), ("external_directory", "/etc/*", "outside"),
            ]
            let expected: [String: [String: PermissionEffect]] = [
                "ask/build": ["read": .allow, "env": .ask, "edit": .ask, "shell": .ask, "outside": .ask],
                "autoEdit/build": ["read": .allow, "env": .ask, "edit": .allow, "shell": .ask, "outside": .ask],
                "fullAccess/build": ["read": .allow, "env": .allow, "edit": .allow, "shell": .allow, "outside": .allow],
                "ask/plan": ["read": .allow, "env": .ask, "edit": .deny, "shell": .ask, "outside": .ask],
                "autoEdit/plan": ["read": .allow, "env": .ask, "edit": .deny, "shell": .ask, "outside": .ask],
                "fullAccess/plan": ["read": .allow, "env": .allow, "edit": .deny, "shell": .allow, "outside": .allow],
            ]
            for agent in ["build", "plan"] {
                let agentRules = try await client.agent(agent, directory: directory).permissions
                for mode in PermissionMode.allCases {
                    let rules = PermissionModeRules.rules(for: mode, agentRules: agentRules)
                    let session = try await client.createSession(SessionCreateRequest(directory: directory, agent: agent, permissions: rules))
                    var row: [String] = []
                    for (action, resource, name) in probes {
                        let result = try await client.evaluatePermission(
                            sessionID: session.id, PermissionCreateRequest(action: action, resources: [resource], agent: agent))
                        row.append("\(name)=\(result.effect.rawValue)")
                        #expect(result.effect == expected["\(mode)/\(agent)"]?[name], "\(mode)/\(agent) \(name)")
                        if result.effect == .ask {
                            try await client.replyPermission(sessionID: session.id, requestID: result.id, decision: .reject)
                        }
                    }
                    print("M1-D real: \(mode)/\(agent): \(row.joined(separator: " "))")
                    #expect(PermissionModeRules.mode(from: try await client.session(session.id).permissions ?? []) == mode)
                    try await client.deleteSession(session.id)
                }
            }
        } catch {
            await sandbox.stop()
            throw error
        }
        await sandbox.stop()
    }

    @Test func importCredentialsBetweenTwoSandboxes() async throws {
        let executable = try #require(EngineRepo.vendoredOpencode)
        let source = try await Sandbox.start("import-source")
        let target = try await Sandbox.start("import-target")
        do {
            try await source.client.connectKey(
                integrationID: "openrouter", key: "sk-bellocode-obviously-fake-1111", directory: source.project.path)
            try await source.client.connectKey(
                integrationID: "anthropic", key: "sk-bellocode-obviously-fake-2222", label: "Fake", directory: source.project.path)
            // The export reads the source data directory with --standalone; stop its server first so no two servers
            // share one database.
            await source.supervisor.stop()
            let importSource = CredentialImportSource.sandbox(root: source.dataRoot, executableURL: executable)
            let targetClient = target.client
            let service = AuthService(
                client: { targetClient }, directory: { target.project.path }, openURL: { _ in },
                importer: CredentialImporter(bundledExecutableURL: executable))
            let preview = try await service.previewImport(from: importSource)
            #expect(Set(preview.map(\.integrationID)) == ["openrouter", "anthropic"])
            let first = try await service.importCredentials(from: importSource)
            #expect(first == CredentialImportResult(imported: 2, skipped: 0))
            let again = try await service.importCredentials(from: importSource)
            #expect(again == CredentialImportResult(imported: 0, skipped: 2))
            let labels = Set(try await targetClient.credentials().map(\.label))
            #expect(labels == ["OpenRouter", "Fake"])
            print("M1-D real: import \(first), re-import \(again)")
        } catch {
            await source.stop()
            await target.stop()
            throw error
        }
        await source.stop()
        await target.stop()
    }
}
