// Real-agent end-to-end run through the production path: the vendored opencode under ServerSupervisor (isolated data
// in a temporary directory, never the person's own config), Engine's BrowserBridgeService, a BrowserWorkspace and the
// pane in a window. Two prompts on a zero-cost model: complete the fixture form; then, without tools, name the browser
// operations that are unavailable (verifies the `bellocode.browser` guidance entry reaches the model). Also checks
// that the real server rejects another contract version on `attach` (how a version bump shows).

import AppKit
import BelloCore
import Engine
import Foundation
@testable import OpenCodeKit

@testable import BrowserKit

@MainActor
struct EndToEnd {
    let fixtures: String
    let binary: URL
    let snapshots: URL
    let downloads: URL

    func run() async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            print("e2e: no opencode at \(binary.path); run Scripts/fetch-opencode.sh")
            return false
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-browser-e2e-\(UUID().uuidString)")
        let work = root.appending(path: "work")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = ServerSupervisor(configuration: ServerConfiguration(executableURL: binary, dataRoot: root.appending(path: "opencode")))
        guard let engine = try? Engine(configuration: EngineConfiguration(server: .supervised(supervisor), store: .inMemory)) else { return false }
        await engine.start()
        for _ in 0..<600 where engine.root.connection != .live { try? await Task.sleep(for: .milliseconds(50)) }
        guard let endpoint = await supervisor.endpoint, let pid = await supervisor.childPID else {
            print("e2e: server not live (\(engine.root.connection.label))")
            await engine.stop()
            return false
        }
        let api = RawAPI(connection: endpoint.connection, directory: work.path)
        var ok = false
        do {
            ok = try await drive(engine: engine, api: api, work: work)
        } catch {
            print("e2e: failed: \(error)")
        }
        await engine.stop()
        try? await Task.sleep(for: .milliseconds(300))
        let gone = kill(pid, 0) != 0
        print("e2e: server process \(gone ? "exited" : "STILL RUNNING")")
        return ok && gone
    }

    private func drive(engine: Engine, api: RawAPI, work: URL) async throws -> Bool {
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ value: Bool, _ detail: String = "") {
            checks.append((name, value))
            print("\(value ? "PASS" : "FAIL")  e2e: \(name)\(detail.isEmpty ? "" : "  — \(detail.prefix(400))")")
        }
        // 1. A zero-cost model.
        let models = try await api.send("GET", "api/model")["data"]?.arrayValue ?? []
        let free = models.filter { model in
            let costs = model["cost"]?.arrayValue ?? []
            return !costs.isEmpty && model["enabled"]?.boolValue != false
                && costs.allSatisfy { cost in (cost.objectValue ?? [:]).values.allSatisfy { ($0.numberValue ?? 0) == 0 || $0.objectValue != nil } }
        }
        let preferred = ProcessInfo.processInfo.environment["E2E_MODEL"] ?? "big-pickle"
        guard let model = free.first(where: { $0["id"]?.stringValue == preferred }) ?? free.first,
              let modelID = model["id"]?.stringValue, let providerID = model["providerID"]?.stringValue else {
            print("e2e: no zero-cost model")
            return false
        }
        print("e2e: model \(providerID)/\(modelID)")

        // 2. The contract version check against the real server (no session needed to see the schema rejection).
        let mismatch = try await api.raw("POST", "api/rpc/experimental.browser/attach", body: [
            "input": ["sessionID": "ses_none", "connectionID": "c", "version": 5],
        ])
        print("e2e: version 5 attach answered \(mismatch.status) \(mismatch.body.compactText.prefix(600))")
        let error: BrowserRPCError = mismatch.body["_tag"]?.stringValue == "RpcError"
            ? .rpc(type: mismatch.body["type"]?.stringValue ?? "", message: mismatch.body["message"]?.stringValue ?? "")
            : .rejected(status: mismatch.status, tag: mismatch.body["_tag"]?.stringValue ?? "", message: mismatch.body["message"]?.stringValue ?? "")
        check("real server rejects another contract version on attach", mismatch.status == 400, "\(mismatch.status)")
        let mapped = BrowserAttachment.endReason(for: error)
        if case .incompatible = mapped { check("…which BelloCode reports as incompatible", true) } else { check("…which BelloCode reports as incompatible", false) }

        if ProcessInfo.processInfo.environment["E2E_CONTRACT_ONLY"] != nil { return !checks.contains { !$0.1 } }

        // 3. A thread on that model, its browser set in the pane, attached through the production path.
        let created = try await api.send("POST", "api/session", body: [
            "title": "Browser e2e", "location": ["directory": .string(work.path)], "model": ["id": .string(modelID), "providerID": .string(providerID)],
        ])
        guard let sid = created["data"]?["id"]?.stringValue else { print("e2e: no session"); return false }
        let sessionID = SessionID(sid)
        let workspace = BrowserWorkspace(engine: engine, isolatedProfiles: true, downloadsFolder: downloads)
        let set = workspace.set(for: sessionID, projectDirectory: work.path)
        let harness = Harness(
            workspace: workspace, set: set,
            context: BrowserPaneContext(projectName: work.lastPathComponent, threadTitle: "Browser e2e", sessionID: sessionID, projectDirectory: work.path),
            downloads: downloads)
        defer { harness.window.close() }
        let model_ = engine.browser.model(for: sessionID)
        for _ in 0..<400 where model_.status != .attached { try? await Task.sleep(for: .milliseconds(50)) }
        check("thread browser attached", model_.status == .attached, model_.status.label)
        let session = try await api.send("GET", "api/session/\(sid)")
        let permissions = session["data"]?["permissions"]?.arrayValue ?? []
        check("server granted the browser tools", permissions.contains { $0["action"]?.stringValue == "browser" && $0["effect"]?.stringValue == "allow" })
        var entries: [JSONValue] = []
        for _ in 0..<60 where entries.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
            entries = try await api.send("GET", "api/experimental/session/\(sid)/instructions/entries")["data"]?.arrayValue ?? []
        }
        check("guidance instruction entry stored on the session", entries.contains { $0["key"]?.stringValue == BrowserBridgeService.guidanceKey })

        // 4. Prompt 1: the fixture form.
        let task = """
            Use the browser tools. Open \(fixtures)/form.html in a browser tab, take a snapshot, fill the sign-up form \
            (Full name: Ada Lovelace, Email: ada@example.com, Plan: pro, accept the terms), click "Create account", \
            then read the page and reply with the exact confirmation text shown under the form.
            """
        let first = try await api.prompt(sid, task)
        let page = set.tabs.first { $0.owner == .agent }
        var confirmation = ""
        if let page {
            let outcome = await set.perform(BrowserCommand(action: ["type": "evaluate", "tabID": .string(page.id), "script": "document.getElementById('result')?.textContent ?? ''"]))
            confirmation = outcome.value?["value"]?.stringValue ?? ""
            set.select(page.id)
        }
        await harness.idle(300)
        if let png = await harness.renderPNG() { try? png.write(to: snapshots.appending(path: "browser-e2e-final.png")) }
        print("e2e: agent commands: \(set.commandLog.joined(separator: ", "))")
        print("e2e: delivery: \(set.deliveryLog.suffix(12).joined(separator: "; "))")
        check("agent completed the form through the bridge", confirmation.contains("Confirmation BC-87"), confirmation)
        check("agent reported the confirmation", first.contains("BC-87"), first)
        check("the agent's tab is marked as agent-owned", page?.owner == .agent && page?.isShared == true)

        // 5. Prompt 2: the guidance reached the model.
        let second = try await api.prompt(sid, """
            Without calling any tools, answer in one short line: according to your instructions for this session, which \
            browser operations are unavailable in this session's browser?
            """)
        let lower = second.lowercased()
        check("model guidance takes effect (names unavailable operations)", ["lighthouse", "trace", "heap", "cpu"].contains { lower.contains($0) }, second)

        let report = checks.map { "\($0.1 ? "PASS" : "FAIL")  \($0.0)" }.joined(separator: "\n")
            + "\n\ncommands: \(set.commandLog.joined(separator: ", "))\nreply 1: \(first)\nreply 2: \(second)\n"
        try? report.write(to: snapshots.appending(path: "browser-e2e.txt"), atomically: true, encoding: .utf8)
        await workspace.close()
        let failed = checks.filter { !$0.1 }
        print("End-to-end: \(checks.count - failed.count)/\(checks.count) passed")
        return failed.isEmpty
    }
}

/// Plain authenticated requests for the e2e script (prompt, wait, messages), outside the code under test.
struct RawAPI {
    let connection: ServerConnection
    let directory: String

    func raw(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> (status: Int, body: JSONValue) {
        var components = URLComponents(url: connection.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "location[directory]", value: directory)] + (path.hasSuffix("/message") ? [URLQueryItem(name: "limit", value: "50")] : [])
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 600
        request.setValue(connection.credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try body.encodedData()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONValue.parse(data)) ?? .null)
    }

    func send(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        try await raw(method, path, body: body).body
    }

    /// Sends a prompt, waits for the turn to end (bounded), and returns the newest assistant text.
    func prompt(_ sessionID: String, _ text: String) async throws -> String {
        let sent = try await raw("POST", "api/session/\(sessionID)/prompt", body: ["text": .string(text)])
        print("e2e: prompt sent (\(sent.status))")
        let started = Date()
        let waiter = Task { _ = try? await raw("POST", "api/experimental/session/\(sessionID)/wait") }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(360))
            waiter.cancel()
        }
        _ = await waiter.value
        timeout.cancel()
        print("e2e: turn finished after \(Int(Date().timeIntervalSince(started))) s")
        let messages = try await send("GET", "api/session/\(sessionID)/message")
        for item in messages["data"]?.arrayValue ?? [] where item["type"]?.stringValue == "assistant" {
            let texts = (item["content"]?.arrayValue ?? []).filter { $0["type"]?.stringValue == "text" }.compactMap { $0["text"]?.stringValue }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return ""
    }
}
