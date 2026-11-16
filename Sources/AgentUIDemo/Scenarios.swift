import AgentUI
import AppKit
import BelloCore
import Engine
import Foundation
import MockOpenCode
import OpenCodeKit
import SwiftUI

/// Each scenario drives real AgentUI views against the mock through the Engine, asserts outcomes, and snapshots.
@MainActor
enum Scenarios {
    static let all = ["requests", "modes", "models", "onboarding", "accounts"]

    static func run(_ name: String, snapshots: inout Snapshotter) async throws {
        print("▶ \(name)")
        let harness = try await DemoHarness()
        do {
            switch name {
            case "requests": try await requests(harness, &snapshots)
            case "modes": try await modes(harness, &snapshots)
            case "models": try await models(harness, &snapshots)
            case "onboarding": try await onboarding(harness, &snapshots)
            case "accounts": try await accounts(harness, &snapshots)
            default: throw DemoFailure(description: "unknown scenario \(name)")
            }
        } catch {
            await harness.stop()
            throw error
        }
        await harness.stop()
    }

    // MARK: Requests

    static func requests(_ h: DemoHarness, _ snapshots: inout Snapshotter) async throws {
        let session = try await h.engine.createThread(in: h.directory, title: "Fix the flaky test", agent: "build")
        let thread = h.engine.openThread(session.id)
        try await waitFor("thread ready") { thread.phase == .ready && thread.session != nil }
        await thread.setPermissionMode(.ask)
        try check(thread.session?.permissionMode == .ask, "mode set to ask")
        let child = try await h.engine.createThread(in: h.directory, title: "Explore test helpers", agent: "general", parent: session.id)
        let client = h.client
        let sid = session.id.rawValue
        _ = try await client.evaluatePermission(
            sessionID: sid, PermissionCreateRequest(action: "shell", resources: ["npm test -- --runInBand"], save: ["npm test *"], agent: "build"))
        _ = try await client.evaluatePermission(
            sessionID: sid, PermissionCreateRequest(action: "edit", resources: ["\(h.directory)/Sources/Flaky.swift", "\(h.directory)/Tests/FlakyTests.swift"], agent: "build"))
        _ = try await client.evaluatePermission(
            sessionID: sid, PermissionCreateRequest(action: "read", resources: ["\(h.directory)/.env"], agent: "build"))
        _ = try await client.evaluatePermission(
            sessionID: child.id.rawValue, PermissionCreateRequest(action: "shell", resources: ["rm -rf .build"], save: ["rm *"], agent: "general"))
        let fields: JSONValue = [
            ["key": "runner", "type": "string", "title": "Which test runner should I use?", "required": true,
             "options": [["value": "swift test", "label": "swift test", "description": "SwiftPM"], ["value": "make test", "label": "make test"]],
             "custom": true],
            ["key": "targets", "type": "multiselect", "title": "Platforms to cover", "options": [["value": "macos", "label": "macOS"], ["value": "ios", "label": "iOS"]], "minItems": 1],
            ["key": "retries", "type": "integer", "title": "Retries", "minimum": 0, "maximum": 5, "default": 2],
            ["key": "parallel", "type": "boolean", "title": "Run in parallel", "default": true],
            ["key": "token", "type": "string", "title": "CI token (optional)"],
        ]
        try await h.request("POST", "/api/session/\(sid)/form", ["title": "How should I run the tests?", "fields": fields])
        try await waitFor("5 requests pending, including the child's") { thread.pendingRequests.count == 5 }
        try check(thread.pendingRequests.contains { $0.sessionID == child.id }, "child request bubbled to the parent")

        var announcements: [String] = []
        let model = PendingRequestStackModel(
            source: thread, context: AgentUIFactories.context(for: thread, engine: h.engine), announce: { announcements.append($0) })
        model.requestsChanged()
        model.requestsChanged()
        try check(announcements.count == 1, "VoiceOver announced the new requests once, not per update")

        try await snapshots.capture("requests-shell", width: 720) { PendingRequestStackView(model: model) }
        model.showNext()
        try await snapshots.capture("requests-edit", width: 720) { PendingRequestStackView(model: model) }
        model.showNext()
        model.expandedDetails.insert(model.current!.id)
        try await snapshots.capture("requests-env-details", width: 720) { PendingRequestStackView(model: model) }
        model.showNext()
        try await snapshots.capture("requests-child", width: 720) { PendingRequestStackView(model: model) }
        model.showNext()
        guard case .question(let question)? = model.current else { throw DemoFailure(description: "expected the question in front") }
        let empty = await model.submit(question)
        try check(!empty, "an incomplete form is not submitted")
        try await snapshots.capture("requests-question-errors", width: 720) { PendingRequestStackView(model: model) }
        let form = model.form(for: question)
        form.choice["runner"] = QuestionFormModel.other
        form.text["runner"] = "swift test --parallel"
        form.selections["targets"] = ["macos"]
        form.text["token"] = "ci-secret-123"
        try check(!String(describing: form).contains("ci-secret"), "form state never prints its values")
        try await snapshots.capture("requests-question", width: 720) { PendingRequestStackView(model: model) }
        let submitted = await model.submit(question)
        try check(submitted, "the completed form is submitted")
        try await waitFor("question removed after the server acknowledged") { thread.pendingRequests.count == 4 }
        let forms = await h.server.publishedEvents().filter { $0["type"]?.stringValue == "form.replied" }
        let answer = forms.last?["data"]?["answer"]
        try check(answer?["runner"]?.stringValue == "swift test --parallel", "custom answer reached the server")
        try check(answer?["retries"]?.doubleValue == 2 && answer?["parallel"] == .bool(true), "defaults were submitted")

        // Allow once, deny with a note, always.
        guard case .permission(let shell)? = thread.pendingRequests.first(where: { if case .permission(let p) = $0 { p.action == "shell" && p.sessionID == session.id } else { false } })
        else { throw DemoFailure(description: "shell request missing") }
        model.currentID = shell.id.rawValue
        await model.reply(.once, to: shell)
        try await waitFor("allow once acknowledged and removed") { thread.pendingRequests.count == 3 }
        guard case .permission(let env)? = thread.pendingRequests.first(where: { if case .permission(let p) = $0 { p.action == "read" } else { false } })
        else { throw DemoFailure(description: "read request missing") }
        model.noteOpen.insert(env.id.rawValue)
        model.notes[env.id.rawValue] = "Please don't read secrets; use .env.example"
        model.currentID = env.id.rawValue
        try await snapshots.capture("requests-deny-note", width: 720) { PendingRequestStackView(model: model) }
        await model.reply(.reject, to: env)
        try await waitFor("deny acknowledged and removed") { thread.pendingRequests.count == 2 }
        guard case .permission(let childShell)? = thread.pendingRequests.first(where: { $0.sessionID == child.id }) else {
            throw DemoFailure(description: "child request missing")
        }
        await model.reply(.always, to: childShell)
        try await waitFor("always acknowledged") { thread.pendingRequests.count == 1 }
        let saved = try await client.savedPermissions(projectID: session.projectID.rawValue)
        try check(saved.map(\.resource) == ["rm *"], "always saved the project rule the card described")

        // A failed reply keeps the card and shows the error.
        guard case .permission(let edit)? = thread.pendingRequests.first else { throw DemoFailure(description: "edit request missing") }
        await h.server.injectHTTPFault(.status(500, method: "POST", pathPrefix: "/api/session/\(sid)/permission/\(edit.id.rawValue)"))
        await model.reply(.once, to: edit)
        try check(thread.pendingRequests.count == 1 && model.replyError != nil, "a failed reply keeps the request and shows why")
        try await snapshots.capture("requests-reply-failed", width: 720) { PendingRequestStackView(model: model) }
        await model.reply(.once, to: edit)
        try await waitFor("retry succeeded") { thread.pendingRequests.isEmpty }
        thread.close()
    }

    // MARK: Modes

    static func modes(_ h: DemoHarness, _ snapshots: inout Snapshotter) async throws {
        let session = try await h.engine.createThread(in: h.directory, title: "Modes", agent: "build")
        let thread = h.engine.openThread(session.id)
        try await waitFor("thread ready") { thread.session != nil }
        let agents = h.engine.root.catalog.catalog(for: h.directory)?.primaryAgents ?? []
        for mode in PermissionMode.allCases {
            await thread.setPermissionMode(mode)
            let rules = try await h.client.session(session.id.rawValue).permissions ?? []
            try check(PermissionModeRules.mode(from: rules) == mode, "\(mode) applied as session rules")
        }
        await thread.setAgent("plan")
        let rules = try await h.client.session(session.id.rawValue).permissions ?? []
        try check(rules.last?.action == "edit" && rules.contains { $0.action == "edit" && $0.effect == .deny }, "plan keeps edit denied under full access")
        let edit = try await h.client.evaluatePermission(
            sessionID: session.id.rawValue, PermissionCreateRequest(action: "edit", resources: ["\(h.directory)/a.swift"], agent: "plan"))
        try check(edit.effect == .deny, "plan + full access: edits are denied (evaluated by the server)")
        var highlighted = PermissionMode.autoEdit
        let binding = Binding(get: { highlighted }, set: { highlighted = $0 })
        try await snapshots.capture("modes-popover", width: 340) {
            PermissionModePopover(current: .ask, agent: "build", agents: agents, highlighted: binding, choose: { _ in }, chooseAgent: { _ in })
        }
        try await snapshots.capture("modes-controls", width: 360) {
            HStack(spacing: 12) {
                PermissionModePicker(source: thread, agents: agents)
                PlanModeToggle(source: thread)
                Spacer()
            }
            .padding(8)
        }
        thread.close()
    }

    // MARK: Models

    static func models(_ h: DemoHarness, _ snapshots: inout Snapshotter) async throws {
        await h.auth.refresh()
        await h.auth.connectKey(integrationID: "anthropic", key: "sk-demo-not-a-real-key")
        try check(h.auth.flow?.phase == .succeeded, "Anthropic connected with a key")
        await h.engine.refreshCatalog(directory: h.directory)
        try await waitFor("Anthropic models in the catalog") {
            h.engine.root.catalog.catalog(for: h.directory)?.models.contains { $0.providerID == "anthropic" } == true
        }
        let session = try await h.engine.createThread(
            in: h.directory, title: "Models", agent: "build", model: ModelSelection(providerID: "opencode", modelID: "big-pickle"))
        let thread = h.engine.openThread(session.id)
        try await waitFor("thread ready") { thread.session != nil }
        var connectRequests: [String?] = []
        let model = AgentUIFactories.modelPickerModel(thread: thread, engine: h.engine, auth: h.auth) { connectRequests.append($0) }
        h.engine.modelPreferences.update {
            $0.toggleFavourite("opencode/big-pickle")
            $0.recordUse(ModelSelection(providerID: "anthropic", modelID: "claude-haiku-mock"))
        }
        model.prepareForOpen()
        try check(model.sections.first?.title == "Favourites", "favourites pinned at the top")
        try check(model.sections.contains { $0.title == "Not connected" }, "providers that are not connected are listed")
        try await snapshots.capture("models-picker", width: 420, height: 460) { ModelPickerView(model: model) {} }

        model.query = "sonet"
        try check(model.highlightedRow?.model?.modelID == "claude-sonnet-mock", "fuzzy “sonet” ranks Claude Sonnet first")
        model.cycleVariant(1)
        model.cycleVariant(1)
        try check(model.variant(for: model.highlightedRow!.model!) == "medium", "Tab cycles the effort variant")
        try await snapshots.capture("models-search", width: 420, height: 300) { ModelPickerView(model: model) {} }
        try check(model.chooseHighlighted(), "Return chooses the highlighted model")
        try check(model.pending?.modelID == "claude-sonnet-mock", "applied optimistically")
        await model.settle()
        let server = try await h.client.session(session.id.rawValue)
        try check(server.model?.id == "claude-sonnet-mock" && server.model?.variant == "medium", "server has the model and variant")
        try check(h.engine.modelPreferences.value.recents.first == "anthropic/claude-sonnet-mock", "recorded as recent")

        await h.server.injectHTTPFault(.status(500, method: "POST", pathPrefix: "/api/session/\(session.id.rawValue)/model"))
        model.select(ModelSelection(providerID: "opencode", modelID: "big-pickle"))
        await model.settle()
        try check(thread.session?.model?.modelID == "claude-sonnet-mock" && model.error != nil, "a failed switch rolls back with an error")
        model.query = "openai"
        try check(model.highlightedRow.map { if case .connect = $0.kind { true } else { false } } == true, "a not-connected provider offers Connect…")
        _ = model.chooseHighlighted()
        try check(connectRequests == ["openai"], "Connect… asks the host to open the connection UI")
        model.query = ""
        try await snapshots.capture("models-error", width: 420, height: 200) { ModelPickerView(model: model) {} }
        try await snapshots.capture("models-button", width: 300) {
            HStack { ModelPickerButton(model: model); Spacer() }.padding(8)
        }
        thread.close()
    }

    // MARK: Onboarding and connection flows

    static func onboarding(_ h: DemoHarness, _ snapshots: inout Snapshotter) async throws {
        await h.auth.refresh()
        let free = (h.engine.root.catalog.catalog(for: h.directory)?.models ?? []).filter(\.isFree).map(\.name)
        try check(!free.isEmpty, "free models available before any login")
        let source = CredentialImportSource(
            executableURL: URL(filePath: "/usr/local/bin/opencode"), environment: [:], displayName: "opencode (/usr/local/bin/opencode)")
        try await snapshots.capture("onboarding-welcome", width: 720, height: 560) {
            OnboardingView(auth: h.auth, freeModels: free, importSource: source) { _ in }
        }
        try await snapshots.capture("onboarding-import", width: 560, height: 200) {
            ImportCredentialsView(auth: h.auth, source: source).padding(20)
        }
        try await snapshots.capture("onboarding-import-none", width: 560, height: 160) {
            ImportCredentialsView(auth: h.auth, source: nil).padding(20)
        }

        // Key with a missing required field: the server's reason, inputs kept.
        try await snapshots.capture("connect-azure", width: 820, height: 520) { ProviderConnectView(auth: h.auth, initialIntegrationID: "azure") }
        await h.auth.connectKey(integrationID: "azure", key: "sk-demo")
        try check(h.auth.flow?.phase == .failed(message: "Missing required form field: resourceName"), "missing field reported by the server")
        try await snapshots.capture("connect-key-failed", width: 820, height: 520) { ProviderConnectView(auth: h.auth, initialIntegrationID: "azure") }

        // OAuth (browser): waits, opens the browser, completes by polling.
        await h.server.setOAuthBehaviour(.pending, integrationID: "openai", methodID: "chatgpt-browser")
        await h.auth.startOAuth(integrationID: "openai", methodID: "chatgpt-browser")
        try check(h.opened.count == 1, "the authorization page opened in the browser")
        try await snapshots.capture("connect-oauth-waiting", width: 820, height: 520) { ProviderConnectView(auth: h.auth, initialIntegrationID: "openai") }
        await h.auth.cancel()
        try check(h.auth.flow?.phase == .cancelled, "cancel ends the attempt")
        let open = await h.server.openAttemptCount()
        try check(open == 0, "the server attempt was cancelled")

        // OAuth (code): a wrong code keeps the attempt and says so.
        await h.server.setOAuthBehaviour(.code("GL-1234"), integrationID: "gitlab", methodID: "pkce")
        await h.auth.startOAuth(integrationID: "gitlab", methodID: "pkce", answers: ["instanceUrl": .text("https://gitlab.com")])
        await h.auth.submitCode("WRONG")
        try await snapshots.capture("connect-code-rejected", width: 820, height: 560) { ProviderConnectView(auth: h.auth, initialIntegrationID: "gitlab") }
        await h.auth.submitCode("GL-1234")
        try check(h.auth.flow?.phase == .succeeded, "the right code connects")
        try await snapshots.capture("connect-succeeded", width: 820, height: 520) {
            ProviderConnectView(auth: h.auth, initialIntegrationID: "gitlab", onDone: {})
        }

        // Expiry.
        await h.server.setOAuthBehaviour(.expire, integrationID: "openai", methodID: "chatgpt-browser")
        await h.auth.startOAuth(integrationID: "openai", methodID: "chatgpt-browser")
        try await waitFor("expired attempt reported") { h.auth.flow?.phase == .expired }

        // Conditional form fields (GitHub Copilot enterprise).
        try await snapshots.capture("connect-copilot", width: 820, height: 560) {
            ProviderConnectView(auth: h.auth, initialIntegrationID: "github-copilot")
        }
    }

    static func accounts(_ h: DemoHarness, _ snapshots: inout Snapshotter) async throws {
        try await snapshots.capture("accounts-empty", width: 680, height: 260) { AccountsSettingsView(auth: h.auth) }
        await h.auth.connectKey(integrationID: "anthropic", key: "sk-demo-1")
        await h.auth.connectKey(integrationID: "anthropic", key: "sk-demo-2", label: "Work")
        await h.auth.startCommand(integrationID: "fictional-labs", methodID: "cli")
        try await waitFor("command login completed") { h.auth.flow?.phase == .succeeded }
        h.auth.clearFlow()
        try check(h.auth.credentials(for: "anthropic").count == 2, "two Anthropic accounts")
        let personal = h.auth.credentials(for: "anthropic").first { $0.label == "Anthropic" }!
        await h.auth.activate(personal.id)
        try check(h.auth.credentials.first { $0.id == personal.id }?.isActive == true, "switched the active account")
        await h.auth.rename(personal.id, to: "Personal")
        try check(h.auth.credentials.contains { $0.label == "Personal" }, "renamed")
        try check(!String(describing: h.auth.credentials).contains("sk-demo"), "no secret in the credential list")
        try await snapshots.capture("accounts-list", width: 680, height: 360) { AccountsSettingsView(auth: h.auth) }
        await h.auth.remove(personal.id)
        try check(h.auth.credentials(for: "anthropic").map(\.label) == ["Work"], "removed one account")
    }
}
