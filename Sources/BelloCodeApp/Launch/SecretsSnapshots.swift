import AppKit
import BelloCore
import DesignSystem
import Engine
import MockOpenCode
import OpenCodeKit
import OrchestrationUI
import SecretKit
import SwiftUI

/// `--snapshot secrets` (docs/features/secrets.md): the request card with the mode choice, Settings ▸ Secrets with a
/// brokered, a placeholder and a visible secret (plus a command-only one and the built-in GitLab token), the selected
/// secret's bindings and audit, the "cannot see" popover's content and the Visible confirmation, light and dark, on
/// mock data (in-memory vault; the proxy shown as running).
extension SnapshotRunner {
    func runSecrets() async -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log("FAIL cannot create \(directory.path): \(error)")
            return false
        }
        DSGlassView.forcesSolidFallback = true
        let engine = runtime.engine
        guard let extras = engine.extras, let manager = engine.secretManager else { return false }
        let settings = AppSettings(defaults: nil)
        let services = AppServices(settings: settings, auth: runtime.auth)
        let workspace = WorkspaceController(engine: engine, stateStore: ShellStateStore(defaults: nil))
        let controller = MainWindowController(
            workspace: workspace,
            configuration: .init(surfaces: .builtIn(services: services), autosaveSuffix: nil, sourceLabel: runtime.sourceLabel))
        guard controller.window != nil else { return false }
        controller.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
        controller.showWindow(nil)
        let driver = ShellDriver(controller: controller)
        var written: [String] = []

        await engine.start()
        guard await waitUntil(timeout: .seconds(20), { engine.root.connection == .live && !engine.root.projects.isEmpty }) else {
            log("FAIL mock never became live")
            return false
        }
        _ = await waitUntil(timeout: .seconds(5)) {
            engine.root.projects.allSatisfy { workspace.projectModel($0).map { !$0.sessionIDs.isEmpty } ?? false }
        }
        guard let project = engine.root.projects.first, let threads = workspace.projectModel(project)?.sessionIDs, threads.count >= 2 else {
            log("FAIL the mock scenario has too few threads")
            return false
        }
        manager.showEgressRunningForSnapshots(port: 49_152, fingerprint: "7c1f0e9a4b2d6e8f31a5c0d9b7e4f2a6c8d1e3f5a7b9c0d2e4f6a8b0c2d4e6f8")

        // 1. The request card: the agent proposes a placeholder bound to the OpenAI API.
        let thread = threads[1]
        _ = await driver.select(.thread(thread))
        let model = workspace.threadModel(thread)
        _ = await waitUntil(timeout: .seconds(5)) { model.phase == .ready }
        await runtime.enqueueMockScript(
            TurnScript(name: "snapshot-secret-request") {
                TurnStep.text("The summariser calls the OpenAI API, so it needs a key. I asked for it in a private card; I will only ever see a placeholder.\n\n")
                TurnStep.tool(
                    "bellocode_app_request_secret",
                    input: ["label": "OpenAI API key", "mode": "placeholder", "destination": "https://api.openai.com", "header": "Authorization", "prefix": "Bearer "],
                    output: "Asked the user for “OpenAI API key” in a private card.", duration: 15)
            }, for: thread)
        driver.type("Add the summariser and test it against the real API.")
        driver.send()
        _ = await waitUntil(timeout: .seconds(15)) { model.messageIDs.count >= 2 && !(model.session?.isRunning ?? true) }
        _ = await engine.orchestration!.handleAppTool(ClientMCPCall(
            tool: ExtrasTools.requestSecret,
            arguments: .object(["label": "OpenAI API key", "reason": "The summariser's integration test calls the OpenAI API.", "mode": "placeholder",
                                "name": "OPENAI_API_KEY", "destination": "https://api.openai.com", "header": "Authorization", "prefix": "Bearer ",
                                "path": "/v1", "url": "https://platform.openai.com/api-keys"]),
            sessionID: thread.rawValue, directory: project.directory))
        _ = await waitUntil(timeout: .seconds(5)) { model.pendingRequests.contains { $0.isApp } }
        controller.split.setCollapsed(controller.split.panelItem, true)
        driver.settle(10)
        if only.isEmpty || only.contains("card") { written += await render(driver, state: "card") }

        // 2. Settings ▸ Secrets: the three modes, a command-only secret, the built-in GitLab token, the proxy running.
        _ = try? await manager.create(label: "Jira token", name: "JIRA_TOKEN", value: SecretValue("jira-mock-token-0001"), mode: .brokered,
                                      bindings: [SecretBinding(host: "jira.acme.internal", methods: ["GET", "POST"], pathPrefixes: ["/rest/api/3"],
                                                               locations: [.basicAuthPassword])])
        let openai = try? await manager.create(
            label: "OpenAI API key", name: "OPENAI_API_KEY", value: SecretValue("sk-mock-0000000000000000"), mode: .placeholder,
            scope: .project(project.directory),
            bindings: [SecretBinding(host: "api.openai.com", methods: ["POST"], pathPrefixes: ["/v1"], locations: [.header("Authorization", prefix: "Bearer ")])])
        _ = try? await manager.create(label: "Staging database password", name: "STAGING_DB_PASSWORD", value: SecretValue("mock-db-password"),
                                      mode: .visible, confirmVisible: true)
        // A secret saved for approved commands only (the legacy path), through its card.
        _ = await engine.orchestration!.handleAppTool(ClientMCPCall(
            tool: ExtrasTools.requestSecret, arguments: .object(["label": "npm publish token", "reason": "Publishing.", "mode": "command"]),
            sessionID: threads[0].rawValue, directory: project.directory))
        if let card = (await extras.pendingAppRequests()).first(where: { if case .secret(let prompt) = $0.kind { prompt.label == "npm publish token" } else { false } }) {
            try? await extras.respond(to: card.id, .saveSecret(SecretValue("npm-mock-token")))
        }
        await manager.reload()
        if let openai {
            let now = Date()
            let entries: [SecretAuditEntry] = [
                .init(account: openai.account, at: now.addingTimeInterval(-3_600), destination: "", outcome: .created, detail: "Placeholder"),
                .init(account: openai.account, at: now.addingTimeInterval(-1_800), destination: "https://api.openai.com/v1/chat/completions", method: "POST",
                      sessionID: thread.rawValue, outcome: .substituted, detail: "Placeholder replaced by the proxy", status: 200),
                .init(account: openai.account, at: now.addingTimeInterval(-1_200), destination: "https://httpbin.org/anything", method: "POST",
                      sessionID: thread.rawValue, outcome: .refused, detail: "unbound-destination"),
                .init(account: openai.account, at: now.addingTimeInterval(-600), destination: "https://api.openai.com/v1/files", method: "POST",
                      sessionID: thread.rawValue, outcome: .responseRedacted, detail: "The value in the response was replaced by the placeholder", status: 200),
                .init(account: openai.account, at: now.addingTimeInterval(-60), destination: "https://api.openai.com/v1/chat/completions", method: "POST",
                      sessionID: thread.rawValue, outcome: .substituted, detail: "Placeholder replaced by the proxy", status: 200),
            ]
            for entry in entries { await manager.recordForSnapshots(entry) }
        }
        _ = try? await extras.mergeRequests.saveInstance(baseURL: MockGitLab.instance.baseURL, token: SecretValue("glpat-mock"))
        try? await Task.sleep(for: .milliseconds(200))
        written += await renderHosted(SecretManagerSettingsView(manager: manager, visuals: extras.visuals, selected: nil), state: "settings")
        if let openai {
            written += await renderHosted(SecretManagerSettingsView(manager: manager, visuals: extras.visuals, selected: openai.account), state: "audit")
        }
        written += await renderHosted(SecretManagerSettingsView(manager: manager, visuals: extras.visuals, selected: nil, adding: true), state: "add")

        // 3. The popover's content (rendered on its own: the glass panel is a separate window) and the Visible claim.
        written += await renderHosted(
            SecretClaimDetail(kind: .hidden, headline: SecretClaims.hiddenHeadline, explanation: SecretClaims.hiddenGuarantee, limits: SecretClaims.hiddenLimits)
                .background(SwiftUI.Color.ds.raised), state: "popover")
        written += await renderHosted(
            VStack(alignment: .leading, spacing: DS.Space.s10) {
                SecretClaimBadge(kind: .hidden, headline: SecretClaims.hiddenHeadline, explanation: SecretClaims.hiddenGuarantee, limits: SecretClaims.hiddenLimits)
                SecretClaimBadge(kind: .visible, headline: SecretClaims.visibleHeadline, explanation: SecretClaims.visibleExplanation)
                SecretClaimBadge(kind: .command, headline: SecretClaims.commandHeadline, explanation: SecretClaims.commandExplanation)
            }
            .padding(16).background(SwiftUI.Color.ds.canvas), state: "claims")

        workspace.close()
        controller.close()
        for path in written { log("wrote \(path)") }
        log(written.isEmpty ? "FAIL nothing written" : "PASS \(written.count) images")
        return !written.isEmpty
    }

    /// Renders a SwiftUI view in its own window, light and dark.
    func renderHosted<V: View>(_ view: V, state: String, title: String = "Secrets") async -> [String] {
        guard only.isEmpty || only.contains(state) else { return [] }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled]
        window.title = title
        window.setFrameOrigin(NSPoint(x: 60, y: 60))
        window.orderFront(nil)
        try? await Task.sleep(for: .milliseconds(300))
        let paths = await renderWindow(window, state: state)
        window.close()
        return paths
    }
}
