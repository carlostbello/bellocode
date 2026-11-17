import BelloCore
import Engine
import Foundation
import OpenCodeKit

/// `make e2e-containers` (`BELLOCODE_SMOKE_E2E=1 BelloCode --smoke-test`): after the smoke test's isolation check,
/// the real opencode binary through the app's launch path, in the temporary project's container:
/// 1. a script runs in Linux with a PATH that names no host runtime folder (and no bun or opencode in the image);
/// 2. a test fails, the file is fixed on the Mac (as the agent's file tools and the user's editor do), and the test
///    passes in the container;
/// 3. a dev server listening on the container's loopback is reached through the per-project loopback forward the
///    built-in browser uses;
/// 4. one prompt on a free built-in model makes the agent run a shell command, which lands in the container.
/// Prints derived results only (never command output or environment).
enum ContainerEndToEnd {
    @MainActor
    static func run(engine: Engine, client: OpenCodeClient, project: String, log: (String) -> Void) async -> Bool {
        var passed = true
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            log("  e2e: \(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
            passed = passed && ok
        }
        let add = URL(filePath: project).appending(path: "src/add.js")
        try? FileManager.default.createDirectory(at: add.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("module.exports = (a, b) => a - b;\n".utf8).write(to: add)
        try? Data("""
            const add = require('./src/add.js');
            if (add(2, 3) !== 5) { console.error('add is wrong'); process.exit(1); }
            console.log('tests pass');
            """.utf8).write(to: URL(filePath: project).appending(path: "test.js"))

        // 1 + 2a. PATH, runtimes, failing test.
        let first = await job(client, project, """
            uname -s; printf 'PATH=%s\\n' "$PATH"; for t in node bun opencode brew; do command -v $t >/dev/null && echo "has-$t" || echo "no-$t"; done; node test.js; echo "exit=$?"
            """)
        check("script runs in Linux", first.contains("Linux"))
        let path = first.split(separator: "\n").first { $0.hasPrefix("PATH=") }.map(String.init) ?? ""
        check("PATH names no host folder", !path.isEmpty && !path.contains("/opt/homebrew") && !path.contains("/Users/") && !path.contains("/Applications"),
              path.replacingOccurrences(of: "PATH=", with: ""))
        check("no bun, opencode or brew in the container", first.contains("no-bun") && first.contains("no-opencode") && first.contains("no-brew"))
        check("node comes from the image", first.contains("has-node"))
        check("test fails before the fix", first.contains("exit=1"))

        // 2b. Edit on the Mac, test in the container.
        let edited = ContinuousClock.now
        try? Data("module.exports = (a, b) => a + b;\n".utf8).write(to: add)
        let second = await job(client, project, "node test.js; echo \"exit=$?\"")
        check("host edit seen by the container test", second.contains("tests pass") && second.contains("exit=0"),
              "\(Int((ContinuousClock.now - edited).components.attoseconds / 1_000_000_000_000_000 + (ContinuousClock.now - edited).components.seconds * 1000)) ms to green")

        // 3. Dev server through the loopback forward.
        let server = try? await client.createShellJob(
            command: "node -e \"require('http').createServer((q, r) => r.end('hello-from-container')).listen(5173, '127.0.0.1')\"",
            cwd: project, timeout: 60_000)
        var body = ""
        var forwarded: URL?
        for _ in 0..<40 where body.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
            await engine.environments.refreshPorts(project)
            guard engine.environments.environment(for: project).ports.contains(where: { $0.port == 5173 }) else { continue }
            forwarded = await engine.environments.browserURL(for: URL(string: "http://localhost:5173/")!, directory: project)
            if let forwarded, let (data, _) = try? await URLSession.shared.data(from: forwarded) { body = String(decoding: data, as: UTF8.self) }
        }
        check("dev server reached through the loopback forward", body == "hello-from-container", forwarded?.absoluteString ?? "no forward")
        check("forward is loopback only", forwarded?.host == "127.0.0.1")
        engine.environments.stopForward(project, port: 5173)
        if let server { try? await client.deleteShellJob(server.id, directory: project) }
        let reaped = await engine.environments.cleanUpProcesses(project)
        log("  e2e: stray processes cleaned after the dev server: \(reaped)")

        // 4. One prompt on a free model: the agent's shell tool lands in the container.
        let free = (engine.root.catalog.current?.models ?? []).filter(\.isFree)
        guard let model = free.first(where: { $0.modelID.contains("pickle") }) ?? free.first else {
            log("  e2e: SKIP agent prompt: no free model in the catalog")
            return passed
        }
        let marker = URL(filePath: project).appending(path: "agent-ran.txt")
        do {
            let session = try await client.createSession(SessionCreateRequest(
                directory: project, title: "BelloCode container e2e", model: ModelRef(id: model.modelID, providerID: model.providerID),
                permissions: [PermissionRule(action: "shell", resource: "*", effect: .allow)]))
            _ = try await client.prompt(sessionID: session.id, PromptRequest(
                text: "Use your shell tool to run exactly this command once, then reply with the single word done: uname -s > agent-ran.txt"))
            var text = ""
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(500))
                text = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
                if !text.isEmpty { break }
            }
            check("agent shell tool ran in the container (\(model.providerID)/\(model.modelID))", text.contains("Linux"),
                  text.isEmpty ? "no file within 120 s" : "")
            try? await client.interrupt(sessionID: session.id)
            try? await client.deleteSession(session.id)
        } catch {
            check("agent prompt", false, "\(error)")
        }
        return passed
    }

    private static func job(_ client: OpenCodeClient, _ directory: String, _ command: String) async -> String {
        guard let job = try? await client.createShellJob(command: command, cwd: directory, timeout: 60_000) else { return "" }
        var current = job
        for _ in 0..<300 where !current.isFinished {
            try? await Task.sleep(for: .milliseconds(100))
            if let next = try? await client.shellJob(job.id, directory: directory) { current = next }
        }
        return (try? await client.shellJobOutput(job.id, directory: directory))?.output ?? ""
    }
}
