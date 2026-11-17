import BelloCore
import ContainerKit
import Darwin
import Engine
import Foundation
import OpenCodeKit
import Synchronization

/// End-to-end proof against the pinned opencode binary: opencode runs on the host with isolated XDG directories and
/// `bellocode-exec` as its shell; every command, the agent's included, lands in the workspace container.
@MainActor
enum EndToEnd {
    struct Check: Codable { var name: String; var passed: Bool; var detail: String }
    static var checks: [Check] = []
    static var helperPath = ""
    static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        checks.append(Check(name: name, passed: passed, detail: String(detail.prefix(600))))
        log("\(passed ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail.prefix(300))")")
    }

    static func run(repo: String, prompts: Bool) async throws {
        let fm = FileManager.default
        let root = NSHomeDirectory() + "/.bellocode-g6-spike/e2e"
        try? fm.removeItem(atPath: root)
        let project = root + "/proj", helpers = root + "/helpers", serverRoot = root + "/server"
        let worktrees = serverRoot + "/data/opencode/worktree"
        for dir in [project, helpers, worktrees, root + "/guard"] { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }

        // Project: a failing Python test (add() subtracts) and a repository config that tries to switch the shell.
        try "def add(a, b):\n    return a - b\n".write(toFile: project + "/calc.py", atomically: true, encoding: .utf8)
        try """
        import unittest
        from calc import add

        class T(unittest.TestCase):
            def test_add(self):
                self.assertEqual(add(2, 3), 5)

        if __name__ == "__main__":
            unittest.main()
        """.write(toFile: project + "/test_calc.py", atomically: true, encoding: .utf8)
        try #"{"$schema":"https://opencode.ai/config.json","shell":"/bin/zsh","formatter":true}"#
            .write(toFile: project + "/opencode.json", atomically: true, encoding: .utf8)
        // A repository-local plugin would run inside opencode, on the host: it must not load.
        try fm.createDirectory(atPath: project + "/.opencode/plugins/evil", withIntermediateDirectories: true)
        try #"{"name":"evil","private":true,"type":"module"}"#.write(toFile: project + "/.opencode/plugins/evil/package.json", atomically: true, encoding: .utf8)
        try """
        import { writeFileSync } from "fs"
        export default { id: "evil", setup: async () => { writeFileSync("\(root)/EVIL-PLUGIN-RAN", "x") } }
        """.write(toFile: project + "/.opencode/plugins/evil/server.ts", atomically: true, encoding: .utf8)
        try host("/usr/bin/git", ["init", "-q"], cwd: project)
        try host("/usr/bin/git", ["-c", "user.email=spike@example.invalid", "-c", "user.name=spike", "add", "."], cwd: project)
        try host("/usr/bin/git", ["-c", "user.email=spike@example.invalid", "-c", "user.name=spike", "commit", "-qm", "init"], cwd: project)

        // Workspace container and helper.
        try await Spike.ensureImage()
        let spec = Spike.spec(project: project, extra: [worktrees], ports: [])
        let container = try await WorkspaceManager(client: Spike.client).ensureRunning(spec)
        let helper = helpers + "/bellocode-exec"
        helperPath = helper
        try fm.copyItem(atPath: repo + "/.build/debug/bellocode-exec", toPath: helper)
        try? fm.copyItem(atPath: repo + "/Vendor/ripgrep/rg", toPath: helpers + "/rg")
        let execConfig = root + "/exec.json"
        try Spike.writeHelperConfig(spec, container: container, to: execConfig)

        // Defence in depth: a plugin forces the shell of every shell job to the helper.
        try #"{"name":"bellocode-container-guard","private":true,"type":"module"}"#.write(toFile: root + "/guard/package.json", atomically: true, encoding: .utf8)
        try """
        export default {
          id: "bellocode-container-guard",
          setup: async (ctx) => {
            const helper = process.env.BELLOCODE_EXEC_PATH
            await ctx.shell.hook("create.before", (event) => { event.shell = helper })
          },
        }
        """.write(toFile: root + "/guard/server.ts", atomically: true, encoding: .utf8)
        let configContent = #"{"shell":"\#(helper)","formatter":false,"mcp":{},"plugins":[{"package":"\#(root)/guard"}]}"#

        guard let executable = Self.opencode(repo: repo) else { throw EngineError.progress("run Scripts/fetch-opencode.sh") }
        let supervisor = ServerSupervisor(configuration: ServerConfiguration(
            executableURL: executable, dataRoot: URL(fileURLWithPath: serverRoot), helpersDirectory: URL(fileURLWithPath: helpers),
            basePath: "/usr/bin:/bin", expectedVersion: "2.3.0",
            extraEnvironment: [
                "SHELL": helper, "BELLOCODE_EXEC_PATH": helper, "BELLOCODE_EXEC_CONFIG": execConfig,
                "OPENCODE_CONFIG_CONTENT": configContent,
            ].merging(ProcessInfo.processInfo.environment["G6_CONTROL_PROJECT_CONFIG"] == nil ? ["OPENCODE_DISABLE_PROJECT_CONFIG": "1"] : [:]) { a, _ in a }))
        await supervisor.start()
        var endpoint = await supervisor.endpoint
        for _ in 0..<1500 where endpoint == nil {
            try await Task.sleep(for: .milliseconds(20))
            endpoint = await supervisor.endpoint
        }
        guard let endpoint else { throw EngineError.progress("server did not start") }
        let api = API(connection: endpoint.connection, directory: project)
        let pid = await supervisor.childPID

        do {
            try await drive(api: api, endpoint: endpoint, spec: spec, container: container, project: project, prompts: prompts)
        } catch {
            check("e2e completed without error", false, String(describing: error))
        }
        await supervisor.stop()
        try? await Task.sleep(for: .milliseconds(300))
        if let pid { check("opencode server exited", kill(pid, 0) != 0) }
        try? await Task.sleep(for: .milliseconds(2500))  // a cancelled job's watcher waits 2 s before its final SIGKILL
        let leftovers = try await ExecSession.run(client: Spike.client, container: container,
                                                  argv: ["sh", "-c", "ps -eo pid,args --no-headers | grep -v -E 'sleep infinity|docker-init|ps -eo|grep|sh -c'"], wrap: false)
        let remaining = String(decoding: leftovers.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        check("no processes left in the workspace container", remaining.isEmpty, remaining)
        let control = ProcessInfo.processInfo.environment["G6_CONTROL_PROJECT_CONFIG"] != nil
        try writeReport(control ? "e2e-control-project-config-allowed" : prompts ? "e2e" : "e2e-no-prompts", checks)
        let failed = checks.filter { !$0.passed }.count
        log("End-to-end: \(checks.count - failed)/\(checks.count) passed")
    }

    static func opencode(repo: String) -> URL? {
        let version = (try? String(contentsOfFile: repo + "/Scripts/opencode-version", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "2.3.0"
        let path = repo + "/Vendor/opencode/\(version)/opencode"
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    static func drive(api: API, endpoint: ServerEndpoint, spec: WorkspaceSpec, container: String, project: String, prompts: Bool) async throws {
        // 1. Shell jobs without a model (`POST /api/shell` uses the same Shell service as the agent's tool).
        let job = try await api.shellJob("uname -s; pwd; id -u; python3 -c 'import sys;print(\"py\", sys.version.split()[0])'; node -e 'console.log(\"node\", process.version)'; echo to-stderr >&2; exit 7")
        check("shell job runs in Linux", job.output.contains("Linux"), job.output)
        check("shell job working directory is the host path", job.output.contains(project), job.output)
        check("shell job runs as the host uid", job.output.contains("\n\(getuid())\n"), job.output)
        check("python3 and node come from the container", job.output.contains("py 3.") && job.output.contains("node v22"), job.output)
        check("stderr captured", job.output.contains("to-stderr"), job.output)
        check("exit code 7 reported", job.exit == 7, "exit \(String(describing: job.exit)) status \(job.status)")
        check("shell is the helper despite the repository's opencode.json", job.shell.hasSuffix("bellocode-exec"), job.shell)
        let plugins = try await api.raw("GET", "api/plugin")
        let pluginList = String(decoding: plugins.1, as: UTF8.self)
        check("repository-local plugin not loaded (OPENCODE_DISABLE_PROJECT_CONFIG)",
              !FileManager.default.fileExists(atPath: (project as NSString).deletingLastPathComponent + "/EVIL-PLUGIN-RAN") && !pluginList.contains("\"evil\""),
              pluginList.contains("bellocode-container-guard") ? "guard plugin listed" : String(pluginList.prefix(200)))
        let outside = try await api.shellJob("echo should-not-run", cwd: "/private/tmp")
        check("a directory outside the project is refused (fail closed)", outside.exit == 126 && !outside.output.contains("should-not-run"), outside.output)
        let timed = try await api.shellJob("sleep 30", timeout: 1500)
        check("a timed-out job is stopped", timed.status == "timeout" || timed.status == "killed", "status \(timed.status)")

        // Dev server as a running shell job, reached through the forwarder, then stopped by deleting the job.
        let started = try await api.json("POST", "api/shell", body: ["command": "python3 -m http.server 8766 --bind 127.0.0.1"])
        let serverJob = ((started["data"] as? [String: Any]) ?? started)["id"] as? String ?? ""
        try await fetchThroughForwarder(container: container, port: 8766, expect: "calc.py", name: "user shell job")
        let (deleteStatus, _) = try await api.raw("DELETE", "api/shell/\(serverJob)")
        let gone = await wait(5) { await serverCount(container) == "0" }
        check("deleting the running shell job stopped the server in the container", gone, "DELETE \(deleteStatus), running \(await serverCount(container))")

        guard prompts else { return }
        let models = try await api.json("GET", "api/model")["data"] as? [[String: Any]] ?? []
        let free = models.filter { model in
            let costs = model["cost"] as? [[String: Any]] ?? []
            return !costs.isEmpty && (model["enabled"] as? Bool) != false
                && costs.allSatisfy { $0.values.allSatisfy { ($0 as? NSNumber)?.doubleValue ?? 0 == 0 || $0 is [String: Any] } }
        }
        guard let model = free.first(where: { $0["id"] as? String == "big-pickle" }) ?? free.first,
              let modelID = model["id"] as? String, let providerID = model["providerID"] as? String else {
            check("zero-cost model available", false)
            return
        }
        log("model \(providerID)/\(modelID)")
        let created = try await api.json("POST", "api/session", body: [
            "title": "G6 e2e", "location": ["directory": project], "model": ["id": modelID, "providerID": providerID],
        ])
        guard let sid = (created["data"] as? [String: Any])?["id"] as? String else { throw EngineError.progress("no session") }

        // 2. Runtimes and a failing command, through the agent's shell tool.
        let reply1 = try await api.prompt(sid, """
            Use the shell tool for each of these three commands, one call per command, in this order, then report each \
            command's output and exit code in one line each:
            1) python3 -c 'import platform, os; print(platform.system(), os.getcwd())'
            2) node -e 'console.log(process.platform, process.version)'
            3) python3 -c 'import sys; sys.stderr.write("boom\\n"); sys.exit(3)'
            """)
        let tools1 = try await api.toolResults(sid)
        check("agent: python ran in Linux in the project directory", tools1.contains("Linux \(project)"), tools1)
        check("agent: node ran in Linux", tools1.contains("linux v22"), tools1)
        check("agent: failing command surfaced (stderr and exit 3)", tools1.contains("boom") && (tools1.contains("exit code 3") || tools1.contains("\"exit\":3") || reply1.contains("3")), reply1)

        // 3. Host-side edit with the file tool, then a test in the container that sees it.
        let reply2 = try await api.prompt(sid, """
            calc.py has a bug: add() subtracts. Fix it with your file editing tool (do not use the shell to edit), \
            then run `python3 -m unittest -v test_calc` with the shell tool and report the final line of its output.
            """)
        let calc = (try? String(contentsOfFile: project + "/calc.py", encoding: .utf8)) ?? ""
        let tools2 = try await api.toolResults(sid)
        check("agent: file edited on the host", calc.contains("a + b"), calc)
        check("agent: test in the container saw the edit (OK)", tools2.contains("OK") && tools2.contains("test_add"), reply2)

        // 4. Dev server in the container, reached from the host through the exec forwarder (port never published).
        _ = try await api.prompt(sid, """
            Start a web server with the shell tool as a background command (background: true): \
            `python3 -m http.server 8765 --bind 127.0.0.1`. Do not wait for it or poll it. Reply "started".
            """)
        try await fetchThroughForwarder(container: container, port: 8765, expect: "calc.py", name: "agent's background server")
        let running = try await api.json("GET", "api/shell")["data"] as? [[String: Any]] ?? []
        for job in running {
            if let id = job["id"] as? String { _ = try? await api.raw("DELETE", "api/shell/\(id)") }
        }
        let stopped = await wait(5) { await serverCount(container) == "0" }
        check("deleting the agent's background shell job stopped the server in the container", stopped,
              "jobs listed \(running.count), running \(await serverCount(container))")

        // 5. Interactive terminal through opencode's persistent PTY API and BelloCode's TerminalService.
        try await terminal(endpoint: endpoint, sessionID: sid, project: project, container: container)
    }

    static func serverCount(_ container: String) async -> String {
        let result = try? await ExecSession.run(client: Spike.client, container: container,
                                                argv: ["sh", "-c", "ps -eo args | grep -c '^python3 -m [h]ttp.server' || true"], wrap: false)
        return String(decoding: result?.stdout ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fetchThroughForwarder(container: String, port: Int, expect: String, name: String) async throws {
        let forwarder = try PortForwarder(client: Spike.client, container: container, containerPort: port)
        let task = Task { await forwarder.run() }
        var body = ""
        let start = ContinuousClock.now
        var firstByte: Double?
        for _ in 0..<40 where !body.contains(expect) {
            let attempt = ContinuousClock.now
            if let (data, _) = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(forwarder.hostPort)/")!) {
                body = String(decoding: data, as: UTF8.self)
                if body.contains(expect) { firstByte = ms(attempt) }
            }
            if !body.contains(expect) { try await Task.sleep(for: .milliseconds(250)) }
        }
        check("\(name): fetched from the host via 127.0.0.1:\(forwarder.hostPort) → container 127.0.0.1:\(port), port never published"
              + (firstByte.map { String(format: " (request %.0f ms, ready after %.1f s)", $0, ms(start) / 1000) } ?? ""),
              body.contains(expect), String(body.prefix(160)))
        forwarder.stop()
        task.cancel()
    }

    final class Sink: TerminalOutputSink {
        let state = Mutex(Data())
        func reset(trimmed: Bool) { state.withLock { $0.removeAll() } }
        func feed(_ data: Data) { state.withLock { $0.append(data) } }
        var text: String { state.withLock { String(decoding: $0, as: UTF8.self) } }
    }

    static func wait(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    static func terminal(endpoint: ServerEndpoint, sessionID: String, project: String, container: String) async throws {
        let client = OpenCodeClient(endpoint: endpoint)
        // Production default is `.userDefault()` (the user's login shell). Containerised, the terminal runs the helper,
        // which opens an interactive login shell in the workspace container.
        let launch = TerminalLaunch(command: helperPath, args: [], environment: ["TERM": "xterm-256color", "LANG": "C.UTF-8"])
        let service = TerminalService(store: try ProjectionStore(location: .inMemory), client: { client }, launch: launch)
        let terminals = service.terminals(for: SessionID(sessionID))
        guard let record = await terminals.create(directory: project, size: PTYSize(cols: 100, rows: 30)) else {
            check("PTY created", false, terminals.lastError?.userMessage ?? "")
            return
        }
        let info = try await client.terminal(record.id)
        check("PTY program is the helper", info.command.hasSuffix("bellocode-exec"), info.command)
        let sink = Sink()
        let stream = service.makeStream(record.id, in: terminals, sink: sink)
        stream.resize(to: PTYSize(cols: 100, rows: 30))
        stream.activate()
        _ = await wait(15) { stream.status == .live }
        _ = await wait(10) { sink.text.contains("$") }
        stream.send(Array("uname -a; echo marker-$((6*7)); pwd\r".utf8))
        check("PTY lands in the container (uname)", await wait(10) { sink.text.contains("Linux") && sink.text.contains("marker-42") }, String(sink.text.suffix(300)))
        check("PTY starts in the project path", sink.text.contains(project))
        let echoStart = ContinuousClock.now
        stream.send(Array("x".utf8))
        let before = sink.text.count
        _ = await wait(5) { sink.text.count > before }
        check("PTY keystroke echo (ms) \(String(format: "%.1f", ms(echoStart)))", sink.text.count > before)
        stream.send([0x15])  // ^U clears the line
        stream.resize(to: PTYSize(cols: 91, rows: 27))
        try await Task.sleep(for: .milliseconds(400))
        stream.send(Array("stty size\r".utf8))
        check("PTY resize reaches the container", await wait(10) { sink.text.contains("27 91") }, String(sink.text.suffix(200)))
        stream.send(Array("sleep 100\r".utf8))
        try await Task.sleep(for: .milliseconds(500))
        stream.send([0x03])
        stream.send(Array("echo after-ctrl-$((2+3))\r".utf8))
        check("Ctrl-C interrupts the foreground process", await wait(10) { sink.text.contains("after-ctrl-5") }, String(sink.text.suffix(200)))
        stream.send(Array("vi /tmp/g6.txt\r".utf8))
        _ = await wait(5) { sink.text.contains("\u{1b}[?1049h") }
        stream.send(Array("ihello-from-vi\u{1b}:wq\r".utf8))
        stream.send(Array("cat /tmp/g6.txt\r".utf8))
        check("full-screen program (vi) runs and saves", await wait(10) { sink.text.contains("\u{1b}[?1049h") && sink.text.components(separatedBy: "hello-from-vi").count >= 3 },
              "alt-screen \(sink.text.contains("\u{1b}[?1049h"))")
        let read = try? await client.readTerminal(sessionID: sessionID)
        check("agent can read the containerised terminal", read?.screen.text.contains("hello-from-vi") == true)
        stream.send(Array("exit 5\r".utf8))
        check("PTY exit code reaches opencode", await wait(15) { terminals.record(record.id)?.state == .exited(code: 5) },
              String(describing: terminals.record(record.id)?.state))
        await service.shutdown()
    }

    /// Plain authenticated requests (outside the code under test).
    struct API {
        let connection: ServerConnection
        let directory: String

        func raw(_ method: String, _ path: String, body: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> (Int, Data) {
            var components = URLComponents(url: connection.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "location[directory]", value: directory)] + query
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.timeoutInterval = 600
            let password = connection.credentials.clientEnvironment["OPENCODE_PASSWORD"] ?? ""
            request.setValue("Basic " + Data("opencode:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            if let body {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }

        func json(_ method: String, _ path: String, body: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> [String: Any] {
            let (_, data) = try await raw(method, path, body: body, query: query)
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }

        struct Job { var status: String; var exit: Int?; var shell: String; var output: String }

        func shellJob(_ command: String, cwd: String? = nil, timeout: Int? = nil) async throws -> Job {
            var body: [String: Any] = ["command": command]
            if let cwd { body["cwd"] = cwd }
            if let timeout { body["timeout"] = timeout }
            let created = try await json("POST", "api/shell", body: body)
            let info = created["data"] as? [String: Any] ?? created
            guard let id = info["id"] as? String else { throw EngineError.progress("shell create: \(created)") }
            var current = info
            for _ in 0..<600 where (current["status"] as? String) == "running" {
                try await Task.sleep(for: .milliseconds(50))
                let got = try await json("GET", "api/shell/\(id)")
                current = got["data"] as? [String: Any] ?? got
            }
            let output = try await raw("GET", "api/shell/\(id)/output")
            let outputJSON = (try? JSONSerialization.jsonObject(with: output.1)) as? [String: Any]
            let text = ((outputJSON?["data"] as? [String: Any])?["output"] as? String) ?? (outputJSON?["output"] as? String)
                ?? String(decoding: output.1, as: UTF8.self)
            return Job(status: current["status"] as? String ?? "?", exit: (current["exit"] as? NSNumber)?.intValue,
                       shell: current["shell"] as? String ?? "", output: "\n" + text)
        }

        func prompt(_ sessionID: String, _ text: String) async throws -> String {
            let (status, _) = try await raw("POST", "api/session/\(sessionID)/prompt", body: ["text": text])
            log("prompt sent (\(status))")
            let started = Date()
            let waiter = Task { _ = try? await raw("POST", "api/experimental/session/\(sessionID)/wait") }
            let timeout = Task {
                try? await Task.sleep(for: .seconds(300))
                waiter.cancel()
            }
            _ = await waiter.value
            timeout.cancel()
            log("turn finished after \(Int(Date().timeIntervalSince(started))) s")
            let messages = try await json("GET", "api/session/\(sessionID)/message", query: [URLQueryItem(name: "limit", value: "50")])
            for item in messages["data"] as? [[String: Any]] ?? [] where item["type"] as? String == "assistant" {
                let texts = (item["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                if !texts.isEmpty { return texts.joined(separator: "\n") }
            }
            return ""
        }

        /// Every tool call's input and result in the session, as JSON text (for assertions; never logged whole).
        func toolResults(_ sessionID: String) async throws -> String {
            let (_, data) = try await raw("GET", "api/session/\(sessionID)/message", query: [URLQueryItem(name: "limit", value: "50")])
            return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
        }
    }
}
