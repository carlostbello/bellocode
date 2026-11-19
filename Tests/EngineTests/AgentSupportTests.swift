import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import Engine

/// Engine support for M1-D: permission-mode rules per agent, child requests in the parent thread, model preferences.
@Suite("Agent UI support", .timeLimit(.minutes(3)))
@MainActor
struct AgentSupportTests {
    static let planRules = [
        PermissionRule(action: "*", resource: "*", effect: .allow),
        PermissionRule(action: "read", resource: "*.env", effect: .ask),
        PermissionRule(action: "question", resource: "*", effect: .allow),
        PermissionRule(action: "edit", resource: "*", effect: .deny),
        PermissionRule(action: "edit", resource: "/home/.opencode/plan/*", effect: .allow),
    ]

    @Test func modeRulesKeepTheAgentsRestrictions() {
        #expect(PermissionModeRules.restrictions(of: Self.planRules) == Array(Self.planRules.suffix(2)))
        #expect(PermissionModeRules.restrictions(of: [PermissionRule(action: "*", resource: "*", effect: .allow)]).isEmpty)
        // Runtime denials outside the governed actions (browser until one is attached) are not frozen into the session.
        #expect(PermissionModeRules.restrictions(of: [PermissionRule(action: "browser", resource: "*", effect: .deny)]).isEmpty)
        for mode in PermissionMode.allCases {
            let rules = PermissionModeRules.rules(for: mode, agentRules: Self.planRules)
            #expect(rules.suffix(2) == Self.planRules.suffix(2))
            #expect(PermissionModeRules.mode(from: rules) == mode)
            #expect(PermissionModeRules.mode(from: PermissionModeRules.rules(for: mode)) == mode)
        }
        #expect(PermissionModeRules.mode(from: []) == nil)
        #expect(PermissionModeRules.mode(from: [PermissionRule(action: "read", resource: "*", effect: .deny)]) == nil)
        // "ask" must name every action the build agent would otherwise allow silently.
        #expect(PermissionModeRules.rules(for: .ask).map(\.action) == ["edit", "shell", "external_directory"])
    }

    /// Evaluates the mapping on the mock, which applies agent, session and saved rules like the real server.
    @Test func modesEvaluateAsDocumentedForBuildAndPlan() async throws {
        let harness = try await MockHarness.start()
        let client = harness.client
        let table: [(PermissionMode, String, [String: PermissionEffect])] = [
            (.ask, "build", ["edit": .ask, "shell": .ask, "external_directory": .ask, "read": .allow, "env": .ask]),
            (.autoEdit, "build", ["edit": .allow, "shell": .ask, "external_directory": .ask, "read": .allow, "env": .ask]),
            (.fullAccess, "build", ["edit": .allow, "shell": .allow, "external_directory": .allow, "read": .allow, "env": .allow]),
            (.autoEdit, "plan", ["edit": .deny, "shell": .ask, "read": .allow]),
            (.fullAccess, "plan", ["edit": .deny, "shell": .allow, "env": .allow]),
        ]
        for (mode, agent, expected) in table {
            let agentRules = try await client.agent(agent, directory: "/tmp/mock-project").permissions
            let session = try await client.createSession(
                SessionCreateRequest(directory: "/tmp/mock-project", agent: agent, permissions: PermissionModeRules.rules(for: mode, agentRules: agentRules)))
            for (probe, effect) in expected {
                let (action, resource) =
                    switch probe {
                    case "env": ("read", "/tmp/mock-project/.env")
                    case "read": ("read", "/tmp/mock-project/a.swift")
                    case "edit": ("edit", "/tmp/mock-project/a.swift")
                    case "shell": ("shell", "rm -rf build")
                    default: (probe, "/etc/*")
                    }
                let result = try await client.evaluatePermission(
                    sessionID: session.id, PermissionCreateRequest(action: action, resources: [resource], agent: agent))
                #expect(result.effect == effect, "\(mode) \(agent) \(probe)")
            }
        }
        await harness.stop()
    }

    @Test func settingModeAndAgentWritesAgentAwareRules() async throws {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let session = try await engine.createThread(in: "/tmp/mock-project", title: "Modes", agent: "build")
        try await waitUntil("known") { engine.openThread(session.id).session != nil }
        try await engine.setPermissionMode(.autoEdit, for: session.id)
        var rules = try await harness.client.session(session.id.rawValue).permissions ?? []
        #expect(rules == PermissionModeRules.rules(for: .autoEdit))
        try await engine.setAgent("plan", for: session.id)
        rules = try await harness.client.session(session.id.rawValue).permissions ?? []
        #expect(rules.contains { $0.action == "edit" && $0.effect == .deny })
        #expect(PermissionModeRules.mode(from: rules) == .autoEdit)
        engine.openThread(session.id).close()
        await engine.stop()
        await harness.stop()
    }

    @Test func childRequestsAppearInTheParentThread() async throws {
        let harness = try await MockHarness.start()
        let engine = try makeEngine(harness)
        await engine.start()
        try await waitUntil("live") { engine.root.connection == .live }
        let parent = try await engine.createThread(in: "/tmp/mock-project", title: "Parent")
        let child = try await engine.createThread(in: "/tmp/mock-project", title: "Child", parent: parent.id)
        let thread = engine.openThread(parent.id)
        try await waitUntil("ready") { thread.phase == .ready }
        try await waitUntil("child known") { engine.openThread(child.id).session != nil }
        engine.openThread(child.id).close()
        // The mock's build agent allows shell; give the child an "ask" rule first.
        try await harness.client.updateSession(child.id.rawValue, SessionUpdateRequest(permissions: PermissionModeRules.rules(for: .ask)))
        let asked = try await harness.client.evaluatePermission(
            sessionID: child.id.rawValue, PermissionCreateRequest(action: "shell", resources: ["make"]))
        #expect(asked.effect == .ask)
        try await waitUntil("bubbled") { thread.pendingRequests.count == 1 }
        #expect(thread.pendingRequests.first?.sessionID == child.id)
        await thread.reply(to: PermissionRequestID(asked.id), .once)
        try await waitUntil("resolved") { thread.pendingRequests.isEmpty }
        thread.close()
        await engine.stop()
        await harness.stop()
    }

    @Test func modelPreferencesPersist() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "prefs-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        do {
            let store = try ProjectionStore(location: .file(url))
            let model = ModelPreferencesModel(store: store)
            await model.load()
            model.update { $0.toggleFavourite("opencode/big-pickle") }
            for index in 0..<10 { model.update { $0.recordUse(ModelSelection(providerID: "p", modelID: "m\(index)", variant: "high")) } }
            model.update { $0.setHidden("p/m0", true) }
            await model.flush()
        }
        let store = try ProjectionStore(location: .file(url))
        let model = ModelPreferencesModel(store: store)
        await model.load()
        #expect(model.value.favourites == ["opencode/big-pickle"])
        #expect(model.value.recents.count == ModelPreferences.recentLimit)
        #expect(model.value.recents.first == "p/m9")
        #expect(model.value.variants["p/m9"] == "high")
        #expect(model.value.hidden == ["p/m0"])
        #expect(try await store.appliedMigrations() == ["v1-initial", "v2-app-preferences", "v3-app-terminals", "v4-thread-organisation", "v5-orchestration-extras", "v6-container-environments", "v7-app-requests", "v8-app-outbox", "v9-gitlab", "v10-gitlab-review", "v11-auto-audit", "v12-secret-manager", "v13-shared-browser"].sorted())
    }

    @Test func catalogCarriesCostsAndIntegration() throws {
        let json = #"""
            {"id":"m","modelID":"m","providerID":"p","name":"M","capabilities":{"tools":true,"input":["text"],"output":["text"]},
             "variants":[{"id":"high"}],"time":{"released":1790000000000},
             "cost":[{"tier":{"type":"context","size":200000},"input":6,"output":30,"cache":{"read":0,"write":0}},
                     {"input":3,"output":15,"cache":{"read":0.3,"write":3.75}}],
             "status":"active","enabled":true,"limit":{"context":1000000,"output":64000}}
            """#
        let model = Mapping.model(try JSONDecoder().decode(ModelInfo.self, from: Data(json.utf8)))
        #expect(model.inputCost == 3)
        #expect(model.outputCost == 15)
        #expect(model.isFree == false)
        #expect(model.variants == ["high"])
    }
}
