// The production bridge path offline: Engine (BrowserBridgeService) attached to MockOpenCode's scripted
// `experimental.browser` plugin, a BrowserWorkspace with a real WKWebView, and the mock playing the agent.

import AppKit
import BelloCore
import Engine
import Foundation
import MockOpenCode
import OpenCodeKit

@testable import BrowserKit

@MainActor
struct BridgeScenario {
    let origin: String
    let snapshots: URL
    let downloads: URL

    func run() async -> Bool {
        var results: [(String, Bool, String)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            results.append((name, ok, detail))
            print("\(ok ? "PASS" : "FAIL")  bridge: \(name)\(detail.isEmpty ? "" : "  — \(detail.prefix(300))")")
        }
        let server = MockOpenCodeServer(scenario: .empty(directory: "/tmp/mock-project"), options: MockServerOptions(clock: .realTime))
        guard let endpoint = try? await server.start() else { print("FAIL bridge: mock did not start"); return false }
        let connection = ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? ""))
        let store = FileManager.default.temporaryDirectory.appending(path: "bellocode-browser-bridge-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: store) }
        guard let engine = try? Engine(configuration: EngineConfiguration(server: .fixed(connection), store: .file(store))) else {
            print("FAIL bridge: engine")
            return false
        }
        await engine.start()
        for _ in 0..<200 where engine.root.connection != .live { try? await Task.sleep(for: .milliseconds(20)) }
        guard let session = try? await engine.createThread(in: "/tmp/mock-project", title: "Browser bridge") else {
            print("FAIL bridge: session")
            return false
        }
        let sid = session.id.rawValue
        let workspace = BrowserWorkspace(engine: engine, isolatedProfiles: true, downloadsFolder: downloads)
        let set = workspace.set(for: session.id, projectDirectory: "/tmp/mock-project")
        let harness = Harness(
            workspace: workspace, set: set,
            context: BrowserPaneContext(projectName: "mock-project", threadTitle: "Browser bridge", sessionID: session.id, projectDirectory: "/tmp/mock-project"),
            downloads: downloads)
        let model = engine.browser.model(for: session.id)
        for _ in 0..<200 where model.status != .attached { try? await Task.sleep(for: .milliseconds(20)) }
        check("thread browser attaches", model.status == .attached, model.status.label)
        var guidance: String?
        for _ in 0..<100 where guidance == nil {
            try? await Task.sleep(for: .milliseconds(20))
            guidance = await server.instructionEntries(for: sid)[BrowserBridgeService.guidanceKey]?.stringValue
        }
        check("model guidance entry written on attach", guidance?.contains("WebKit") == true && guidance?.contains("lighthouse") == true)

        // The agent opens the fixture form and completes it through the bridge.
        let opened = await server.issueBrowserCommand(sessionID: sid, action: ["type": "tabs.open", "url": .string(origin + "/form.html")])
        let tabID = opened.value?["id"]?.stringValue ?? ""
        check("tabs.open through the bridge", tabID.hasPrefix("tab_") && set.tab(tabID)?.owner == .agent, "\(opened)")
        let published = await server.browserAttachment(for: sid)?.state?["tabs"]?.arrayValue?.map { $0["id"]?.stringValue ?? "" } ?? []
        check("the new tab was published before the answer", published.contains(tabID))
        let snapshot = await server.issueBrowserCommand(sessionID: sid, action: ["type": "snapshot", "tabID": .string(tabID)])
        let content = snapshot.value?["content"]?.stringValue ?? ""
        func ref(_ role: String, _ name: String) -> String? {
            content.split(separator: "\n").first { $0.contains("[\(role)]") && $0.contains(name) }.flatMap { line in line.firstMatch(of: /@(e\d+)/).map { String($0.1) } }
        }
        if let name = ref("textbox", "Full name"), let email = ref("textbox", "Email"), let plan = ref("combobox", "Plan"), let terms = ref("checkbox", "terms"),
           let submit = ref("button", "Create account") {
            let form = await server.issueBrowserCommand(sessionID: sid, action: ["type": "fill_form", "tabID": .string(tabID), "fields": [
                ["ref": .string(name), "type": "text", "value": "Ada Lovelace"], ["ref": .string(email), "type": "text", "value": "ada@example.com"],
                ["ref": .string(plan), "type": "select", "values": ["pro"]], ["ref": .string(terms), "type": "check", "checked": true],
            ]])
            check("fill_form through the bridge", form.value != nil, "\(form)")
            _ = await server.issueBrowserCommand(sessionID: sid, action: ["type": "click", "tabID": .string(tabID), "ref": .string(submit)])
            let result = await server.issueBrowserCommand(sessionID: sid, action: ["type": "evaluate", "tabID": .string(tabID), "script": "document.getElementById('result').textContent"])
            check("form submitted by the agent", result.value?["value"]?.stringValue?.contains("Confirmation BC-87") == true, "\(result)")
        } else {
            check("form refs", false, content)
        }

        // Ownership through the bridge: a tab the person opens is not published and cannot be targeted.
        let user = set.newTab(url: URL(string: origin + "/spa.html"), select: false)
        try? await Task.sleep(for: .milliseconds(300))
        let state = await server.browserAttachment(for: sid)?.state?["tabs"]?.arrayValue?.map { $0["id"]?.stringValue ?? "" } ?? []
        check("person's tab is not published", !state.contains(user.id) && state.contains(tabID))
        let blocked = await server.issueBrowserCommand(sessionID: sid, action: ["type": "snapshot", "tabID": .string(user.id)])
        check("agent command on an unshared tab fails", blocked.failureCode == "not_shared", "\(blocked)")

        // Unsupported operations fail with an explanation.
        let trace = await server.issueBrowserCommand(sessionID: sid, action: ["type": "trace.start", "tabID": .string(tabID)])
        check("unsupported operation explains itself", trace.failureCode == "unsupported", "\(trace)")

        // The server's timeout cancels a running command; the tab's activity clears.
        let waited = await server.issueBrowserCommand(
            sessionID: sid, action: ["type": "wait", "tabID": .string(tabID), "condition": "text", "text": "never appears", "timeoutMs": 20_000],
            timeout: .milliseconds(800))
        try? await Task.sleep(for: .milliseconds(300))
        check("server cancel stops a running command", waited == .timedOut && set.tab(tabID)?.agentActivity == nil)

        // Stop from the pane cancels the agent's command and answers `cancelled`.
        async let stopped = server.issueBrowserCommand(
            sessionID: sid, action: ["type": "wait", "tabID": .string(tabID), "condition": "text", "text": "never", "timeoutMs": 20_000])
        for _ in 0..<100 where set.tab(tabID)?.agentActivity == nil { try? await Task.sleep(for: .milliseconds(10)) }
        await harness.idle(100)
        if let png = await harness.renderPNG() { try? png.write(to: snapshots.appending(path: "browser-bridge-agent.png")) }
        set.stopAgent()
        check("Stop answers the agent with cancelled", await stopped.failureCode == "cancelled")

        // Persistence: a new workspace restores the thread's tabs (same IDs) from the store.
        await workspace.flushSaves()
        let restoredWorkspace = BrowserWorkspace(engine: engine, isolatedProfiles: true, downloadsFolder: downloads)
        let restored = restoredWorkspace.set(for: session.id, projectDirectory: "/tmp/mock-project")
        for _ in 0..<100 where !restored.isLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        check("tabs and URLs restore per thread", restored.tabs.map(\.id) == set.tabs.map(\.id) && restored.tab(tabID)?.info.url.contains("form.html") == true,
              "\(restored.tabs.map(\.info.url))")
        await restoredWorkspace.close()

        // Turning control off detaches: the agent loses the tools.
        engine.browser.setControlEnabled(false, for: session.id)
        for _ in 0..<100 where await server.browserAttachment(for: sid) != nil { try? await Task.sleep(for: .milliseconds(10)) }
        check("control off detaches the agent", await server.browserAttachment(for: sid) == nil && model.status == .disabled)
        let refused = await server.issueBrowserCommand(sessionID: sid, action: ["type": "tabs.list"])
        check("no commands reach a disabled thread", refused == .notAttached)

        harness.window.close()
        await workspace.close()
        await engine.stop()
        await server.stop()
        let failed = results.filter { !$0.1 }
        print("Bridge scenario: \(results.count - failed.count)/\(results.count) passed")
        return failed.isEmpty
    }
}
