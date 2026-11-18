import BelloCore
import ContainerKit
import Engine
import Foundation
import OpenCodeKit

/// `make e2e-exec` (`BELLOCODE_SMOKE_EXEC=1 BelloCode --smoke-test`): the shared workspace through the app's launch
/// path with the real opencode binary. Two repositories under one temporary code root; an agent on a free built-in
/// model runs a command in repo A that reads repo B, then starts a two-service compose stack from inside the shared
/// workspace through BelloCode's filtered Docker endpoint, and a hostile docker request is refused. Two prompts. The
/// shared workspace uses its own identity (never the developer's) and everything is removed afterwards. Needs
/// `bellocode-test-ws:1` (docs/features/workspace-image.Dockerfile) and `redis:7-alpine` present.
enum ExecModesEndToEnd {
    static let image = "bellocode-test-ws:1"

    @MainActor
    static func run(engine: Engine, client: OpenCodeClient, root: URL, log: (String) -> Void) async -> Bool {
        var passed = true
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            log("  exec: \(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
            passed = passed && ok
        }
        let environments = engine.environments
        let codeRoot = (CodeRootPaths.canonical(root.path) ?? root.path) + "/Repos"
        let repoA = codeRoot + "/a", repoB = codeRoot + "/b"
        for path in [repoA + "/out", repoB] { try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        try? "from repo b\n".write(toFile: repoB + "/hello.txt", atomically: true, encoding: .utf8)
        try? """
        services:
          cache:
            image: redis:7-alpine
          probe:
            image: redis:7-alpine
            command: ["sh", "-c", "until redis-cli -h cache ping > /out/ping.txt 2>/dev/null; do sleep 0.3; done; sleep 3600"]
            volumes: ["./out:/out"]
            depends_on: [cache]
        """.write(toFile: repoA + "/compose.yaml", atomically: true, encoding: .utf8)

        environments.sharedKeySeed = "smoke-shared-\(UUID().uuidString.prefix(8))"
        var defaults = environments.defaults
        defaults.defaultImage = image
        await environments.setDefaults(defaults)
        await environments.setCodeRoots([codeRoot])
        _ = try? await client.createSession(SessionCreateRequest(directory: repoA, title: "exec modes"))
        let environment = environments.environment(for: repoA)
        let started = ContinuousClock.now
        let ready = await waitUntil(timeout: .seconds(60)) {
            environments.activate(repoA)
            return environment.phase == .ready
        }
        check("shared workspace ready for repo A", ready && environment.mode == .sharedWorkspace,
              "\(environment.mode.title), \(environment.phase.label), \(Int((ContinuousClock.now - started).components.seconds)) s")
        check("filtered Docker endpoint running", environments.dockerEndpoint != nil)
        guard ready else { return false }
        await environments.writeConfigNow()

        // The path without a model: a shell job in repo A reads repo B and reaches the filtered endpoint.
        let direct = await shellJob(client, repoA, "pwd; cat ../b/hello.txt; uname -s; docker version --format 'server {{.Server.APIVersion}}' 2>&1 | tail -1")
        check("shell job in repo A reads repo B in the shared workspace", direct.contains("from repo b") && direct.contains("Linux"), String(direct.prefix(300)))
        check("docker inside reaches the filtered endpoint", direct.contains("server 1."), String(direct.suffix(160)))

        // The same compose stack and a hostile request through opencode's shell API (the path the agent's shell tool
        // takes: opencode → bellocode-exec → the shared workspace → the filtered endpoint), without a model.
        let up = await shellJob(client, repoA, "docker compose -p bcsmokeapi up -d 2>&1 | tail -3; docker run --rm -v /etc:/x redis:7-alpine true 2>&1 | grep -o 'BelloCode refused[^:]*'")
        var apiPong = ""
        for _ in 0..<60 where apiPong.isEmpty {
            apiPong = (try? String(contentsOfFile: repoA + "/out/ping.txt", encoding: .utf8)) ?? ""
            if apiPong.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
        }
        check("compose stack started through opencode's shell from the shared workspace", apiPong.contains("PONG"), String(up.prefix(200)))
        check("host mount refused through opencode's shell", up.contains("BelloCode refused"), String(up.suffix(200)))
        _ = await shellJob(client, repoA, "docker compose -p bcsmokeapi down -v -t 1")
        try? FileManager.default.removeItem(atPath: repoA + "/out/ping.txt")

        let free = (engine.root.catalog.current?.models ?? []).filter(\.isFree)
        guard !free.isEmpty else {
            log("  exec: SKIP agent prompts: no free model in the catalog")
            return passed
        }
        log("  exec: free models: \(free.map(\.modelID).joined(separator: ", "))")
        var models = free.filter { $0.modelID.contains("pickle") } + free.filter { !$0.modelID.contains("pickle") }
        var limited: [String] = []
        /// Runs the prompt with the first free model that is not over its provider limit; nil when all are.
        func prompt(_ text: String, until file: String, timeout: Int = Int(ProcessInfo.processInfo.environment["BELLOCODE_EXEC_TIMEOUT"] ?? "") ?? 180) async -> String? {
            while let model = models.first {
                do {
                    let session = try await client.createSession(SessionCreateRequest(
                        directory: repoA, title: "BelloCode exec e2e", model: ModelRef(id: model.modelID, providerID: model.providerID),
                        permissions: [PermissionRule(action: "*", resource: "*", effect: .allow)]))
                    _ = try await client.prompt(sessionID: session.id, PromptRequest(text: text))
                    var content = ""
                    var overLimit = false
                    for _ in 0..<(timeout * 2) {
                        try? await Task.sleep(for: .milliseconds(500))
                        content = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
                        if !content.isEmpty { break }
                        if let page = try? await client.messages(sessionID: session.id), page.data.contains(where: { message in
                            // Over its free limit, deprecated, unavailable: the provider refused this model, try the next.
                            if case .idle(let idle) = message, idle.error?.type.hasPrefix("provider.") == true { return true }
                            return false
                        }) {
                            overLimit = true
                            break
                        }
                    }
                    if content.isEmpty, !overLimit, ProcessInfo.processInfo.environment["BELLOCODE_EXEC_DEBUG"] == "1",
                       let page = try? await client.messages(sessionID: session.id) {
                        for message in page.data { log("  exec debug: \(String(describing: message).prefix(2500))") }
                    }
                    try? await client.interrupt(sessionID: session.id)
                    try? await client.deleteSession(session.id)
                    if overLimit {
                        limited.append(model.modelID)
                        models.removeFirst()
                        continue
                    }
                    log("  exec: model \(model.providerID)/\(model.modelID)")
                    return content
                } catch {
                    return "error: \(error)"
                }
            }
            return nil
        }
        // 1. Multi-repo: a command in repo A reads repo B.
        guard let crossRepo = await prompt(
            "Use your shell tool to run exactly this command once, then reply with the single word done: cat ../b/hello.txt > from-b.txt; uname -s >> from-b.txt",
            until: repoA + "/from-b.txt") else {
            log("  exec: SKIP agent prompts: the provider refused every free model (usage limits, deprecations) (\(limited.joined(separator: ", ")))")
            await cleanUp()
            return passed
        }
        check("agent in repo A read repo B, in Linux", crossRepo.contains("from repo b") && crossRepo.contains("Linux"),
              crossRepo.isEmpty ? "no file within the timeout" : "")
        // 2. A compose stack from inside the shared workspace, and a hostile request refused.
        let compose = await prompt(
            "Use your shell tool to run exactly this command once, then reply with the single word done: docker compose up -d > compose.log 2>&1; docker run --rm -v /etc:/x redis:7-alpine true > refused.log 2>&1; echo finished >> compose.log",
            until: repoA + "/compose.log")
        var pong = ""
        for _ in 0..<60 where pong.isEmpty {
            pong = (try? String(contentsOfFile: repoA + "/out/ping.txt", encoding: .utf8)) ?? ""
            if pong.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
        }
        check("agent started a two-service compose stack from inside the shared workspace", pong.contains("PONG"),
              (compose ?? "").isEmpty ? "no compose.log (\(compose == nil ? "models over their limit" : "timeout"))" : (pong.isEmpty ? String((compose ?? "").suffix(200)) : "probe reached cache by name"))
        let refused = (try? String(contentsOfFile: repoA + "/refused.log", encoding: .utf8)) ?? ""
        check("a host mount from the agent's docker was refused", refused.contains("BelloCode refused"), String(refused.prefix(160)))
        check("the refusal is listed for the workspace", environments.dockerRefusals.contains { $0.scope == environment.containerKey })

        await cleanUp()
        return passed

        // Clean up: the stack, then the scratch shared workspace and its volumes (explicit purge).
        func cleanUp() async {
            _ = await shellJob(client, repoA, "docker compose down -v -t 1")
            if let storage = try? await environments.storageToPurge(repoA) {
                try? await environments.purge(repoA, confirmed: storage)
            }
        }
    }

    private static func shellJob(_ client: OpenCodeClient, _ directory: String, _ command: String) async -> String {
        guard let job = try? await client.createShellJob(command: command, cwd: directory, timeout: 60_000) else { return "" }
        var current = job
        for _ in 0..<600 where !current.isFinished {
            try? await Task.sleep(for: .milliseconds(100))
            if let next = try? await client.shellJob(job.id, directory: directory) { current = next }
        }
        return (try? await client.shellJobOutput(job.id, directory: directory))?.output ?? ""
    }
}
