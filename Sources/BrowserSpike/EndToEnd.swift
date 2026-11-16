// SPIKE (gate G3). End-to-end: a real opencode 2.3.0 server (isolated XDG dirs), a session on a zero-cost model, our
// WKWebView bridge attached to it, and one prompt that makes the agent drive the browser.

import AppKit
import BrowserKit
import Foundation

@MainActor
struct EndToEnd {
    let host: BrowserHost
    let fixtures: String
    let binary: URL
    let snapshots: URL
    let prompt: String?

    func run() async -> Bool {
        let server: SpikeServer
        do { server = try await SpikeServer.launch(binary: binary) } catch {
            print("launch failed: \(error)")
            return false
        }
        defer { server.shutdown() }
        do {
            return try await drive(server)
        } catch {
            print("e2e failed: \(error)\nserver stderr tail:\n\(server.stderrText.suffix(1_500))")
            return false
        }
    }

    private func drive(_ server: SpikeServer) async throws -> Bool {
        let location = server.locationQuery
        // 1. A zero-cost model from the built-in catalog.
        let (models, _) = try await server.send("GET", "api/model", query: location)
        let all = models["data"]?.array ?? []
        let free = all.filter { model in
            let costs = model["cost"]?.array ?? []
            return !costs.isEmpty && costs.allSatisfy { cost in (cost.object ?? [:]).values.allSatisfy { ($0.double ?? 0) == 0 || $0.object != nil } }
                && model["enabled"]?.bool != false
        }
        print("catalog: \(all.count) chat models; zero-cost: " + free.map { "\($0["providerID"]?.string ?? "?")/\($0["id"]?.string ?? "?")" }.joined(separator: ", "))
        let preferred = ProcessInfo.processInfo.environment["G3_MODEL"]
        guard let model = free.first(where: { preferred == nil || $0["id"]?.string == preferred }) ?? free.first,
              let modelID = model["id"]?.string, let providerID = model["providerID"]?.string else {
            print("no zero-cost model in the catalog")
            return false
        }
        print("model: \(providerID)/\(modelID) cost=\(model["cost"]?.compactText ?? "")")

        // 2. A session at the server's work directory.
        let (created, status) = try await server.send("POST", "api/session", query: location, body: [
            "title": "G3 browser bridge", "location": ["directory": .string(server.directory.path)],
            "model": ["id": .string(modelID), "providerID": .string(providerID)],
        ])
        guard status == 200, let sessionID = created["data"]?["id"]?.string else { throw SpikeServer.LaunchError("session create \(status): \(created.compactText.prefix(400))") }
        let before = try await server.send("GET", "api/session/\(sessionID)", query: location).0["data"]?["permissions"]
        print("session \(sessionID); permissions before attach: \(before?.compactText ?? "null")")

        // 3. Attach the WKWebView browser.
        let connection = BridgeConnection(server: server, host: host, sessionID: sessionID)
        defer { connection.stop() }
        try await connection.start()
        try await Task.sleep(for: .milliseconds(500))
        let after = try await server.send("GET", "api/session/\(sessionID)", query: location).0["data"]?["permissions"]
        let granted = after?.array?.contains { $0["action"]?.string == "browser" && $0["effect"]?.string == "allow" } == true
        print("attached=\(connection.isAttached); permissions after attach: \(after?.compactText ?? "null")")
        print("browser tools allowed for the session: \(granted)")

        // 4. One prompt.
        let text = prompt ?? """
        Use the browser tools. Open \(fixtures)/form.html in a browser tab, take a snapshot, fill the sign-up form \
        (Full name: Ada Lovelace, Email: ada@example.com, Plan: pro, accept the terms), click "Create account", \
        then read the page and reply with the exact confirmation text shown under the form.
        """
        let (sent, sentStatus) = try await server.send("POST", "api/session/\(sessionID)/prompt", query: location, body: ["text": .string(text)])
        print("prompt sent: \(sentStatus) \(sent["data"]?["id"]?.string ?? sent.compactText.prefix(200).description)")
        let started = Date()
        _ = try? await withDeadline(.seconds(420)) {
            _ = try await server.send("POST", "api/experimental/session/\(sessionID)/wait", query: location)
        }
        print("turn finished after \(Int(Date().timeIntervalSince(started))) s")

        // 5. Evidence.
        let (messages, _) = try await server.send("GET", "api/session/\(sessionID)/message", query: location + [URLQueryItem(name: "limit", value: "50")])
        try? messages.encoded().write(to: snapshots.appending(path: "g3-e2e-messages.json"))
        let page = Optional(await host.perform(BrowserCommand(action: ["type": "evaluate", "tabID": .string(host.focusedTabID ?? ""), "script": "document.getElementById('result')?.textContent ?? ''"])))
        var confirmation = ""
        if case .success(let result)? = page { confirmation = result.value["value"]?.string ?? "" }
        if let tabID = host.focusedTabID, case .success = await host.perform(BrowserCommand(action: ["type": "screenshot", "tabID": .string(tabID), "format": "png"])), let data = host.lastScreenshot {
            try? data.write(to: snapshots.appending(path: "g3-e2e-final.png"))
        }
        let reply = Self.lastAssistantText(messages)
        let tools = (messages["data"]?.array ?? []).flatMap { ($0["content"]?.array ?? []).compactMap { part -> String? in
            guard let name = part["name"]?.string, part["state"] != nil else { return nil }
            return "\(name): \(part["input"]?["code"]?.string ?? part["state"]?["input"]?["code"]?.string ?? part["state"]?["input"]?.compactText ?? "")".prefix(300).description
        } }.reversed()
        print("\nAgent tool calls (oldest first):\n  " + tools.joined(separator: "\n  "))
        print("\nBridge commands issued by the agent (\(host.commandLog.count)):\n  " + host.commandLog.joined(separator: "\n  "))
        print("\nDelivery:\n  " + host.deliveryLog.joined(separator: "\n  "))
        print("\nProtocol trace:\n  " + connection.trace.joined(separator: "\n  "))
        print("\nPage confirmation: \(confirmation)")
        print("Agent reply: \(reply.prefix(1_500))")
        let ok = confirmation.contains("Confirmation BC-87") && reply.contains("BC-87")
        print("\nEND-TO-END: \(ok ? "SUCCESS" : "INCOMPLETE")")
        let report = ["model \(providerID)/\(modelID)", "granted \(granted)", "commands:"] + host.commandLog + ["delivery:"] + host.deliveryLog + ["trace:"] + connection.trace + ["page: \(confirmation)", "reply: \(reply)", "result: \(ok)"]
        try? report.joined(separator: "\n").write(to: snapshots.appending(path: "g3-e2e.txt"), atomically: true, encoding: .utf8)
        return ok
    }

    /// The newest assistant message's own text parts (the list is newest first; tool output is not reply text).
    static func lastAssistantText(_ messages: JSONValue) -> String {
        let items = messages["data"]?.array ?? messages["data"]?["items"]?.array ?? []
        for item in items where item["type"]?.string == "assistant" {
            let texts = (item["content"]?.array ?? []).filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return ""
    }
}
