import BelloCore
import ContainerKit
import Foundation
import Network
import OpenCodeKit
import Synchronization
import Testing

@testable import Engine
@testable import SecretKit

/// The shared browser on the real Rancher Desktop (docs/features/shared-browser.md "Verification"), opt-in:
/// `BELLOCODE_CONTAINER_TESTS=1 swift test --filter LiveSharedBrowser`. One browser container built from
/// Containers/browser with a throwaway packing key, behind a real in-process egress proxy and gateway; two agents
/// through the real broker and pooled `browse mcp`; a "workspace" container with a loopback-only dev server and a
/// service container on a project network reached by canonical names; a company test CA; a placeholder secret bound to
/// a test destination; a sign-in cookie across an orderly idle stop and a crash. Everything is labelled and removed.
@Suite("Live shared browser", .serialized, .timeLimit(.minutes(10)),
       .enabled(if: ProcessInfo.processInfo.environment["BELLOCODE_CONTAINER_TESTS"] == "1", "set BELLOCODE_CONTAINER_TESTS=1"))
struct LiveSharedBrowserTests {
    static let label = ["app.bellocode.test": "shared-browser"]
    static let nodeImage = "node:22-bookworm-slim"
    let socket = NSHomeDirectory() + "/.rd/docker.sock"
    var client: EngineClient { EngineClient(socketPath: socket) }
    static let context = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Containers/browser")

    @Test func sharedBrowserEndToEnd() async throws {
        let key = "sb" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let work = FileManager.default.temporaryDirectory.appending(path: "bc-live-browser-\(key)")
        let certs = NSHomeDirectory() + "/Library/Caches/BelloCode/tests/browser-certs-\(key)"
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: certs, withIntermediateDirectories: true)
        var report: [String: String] = [:]
        let names = (container: "bellocode-test-browser-\(key)", volume: "bellocode-test-browser-\(key)", net: ServiceLabels.networkName(projectKey: key, offline: false),
                     ws: "bellocode-test-bws-\(key)", api: "bellocode-test-api-\(key)")

        // Certificates: a company test CA (upstream destinations) and the proxy's CA (what Chrome sees for every host).
        let companyCA = try CertificateAuthority(commonName: "BelloCode live company test CA")
        let proxyCA = try CertificateAuthority(commonName: "BelloCode live egress CA")
        try Data((companyCA.pem + proxyCA.pem).utf8).write(to: URL(filePath: certs + "/enterprise-roots.pem"))
        try Data((companyCA.pem + proxyCA.pem).utf8).write(to: URL(filePath: certs + "/ca-bundle.pem"))
        chmod(certs, 0o755)

        // A destination signed by the company CA, with a placeholder secret bound to it.
        let bound = try await MiniTLSServer(name: "bound.test", authority: companyCA)
        let canary = "sk_live_CANARY_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let secret = ManagedSecret(account: "bcs_browser", name: "API_KEY", label: "Canary", mode: .placeholder,
                                   bindings: [SecretBinding(host: "bound.test", pathPrefixes: ["/v1"], locations: [.header("Authorization", prefix: "Bearer ")])])
        let placeholder = Placeholder.make()

        // Routing: canonical names through the table, the rest to the internet path (here: the test destination).
        let forwards = Mutex<[String: PortForwarder]>([:])
        let gatewayName = EgressGateway.containerName(key)
        let projects = [BrowserRouteProject(directory: work.path, label: "proj", projectKey: key, workspaceContainer: names.ws, workspaceRunning: true,
                                            services: ["api": [8080]])]
        let socketPath = socket
        let router = BrowserEgressRouter(table: { destination, _ in
            switch BrowserRouteTable.resolve(destination, projects: projects) {
            case .refuse(let reason): return .refuse(reason)
            case .target(let target):
                let id = "\(target.container)|\(target.host)|\(target.port)"
                if let existing = forwards.withLock({ $0[id] }) { return .dial(EgressDial(endpoint: HostPort(host: "127.0.0.1", port: existing.hostPort), terminatesTLS: true)) }
                guard let forwarder = try? PortForwarder(client: EngineClient(socketPath: socketPath), container: target.container,
                                                         containerPort: target.port, containerHost: target.host) else { return nil }
                forwards.withLock { $0[id] = forwarder }
                Task { await forwarder.run() }
                return .dial(EgressDial(endpoint: HostPort(host: "127.0.0.1", port: forwarder.hostPort), terminatesTLS: true))
            }
        }, fallback: InternetRouter(), routesOnlyScopes: ["preview"])
        let proxy = EgressProxy(authority: proxyCA, configuration: EgressProxyConfiguration(
            extraAnchors: [companyCA.certificateDER], resolverOverrides: ["bound.test": HostPort(host: "127.0.0.1", port: Int(bound.port))], router: router))
        let proxyPort = try await proxy.start()
        let token = UUID().uuidString
        proxy.setScopes([EgressScope(id: key, token: token) { _ in true }])
        proxy.update(EgressSnapshot(grants: [placeholder: PlaceholderGrant(placeholder: placeholder, account: secret.account, sessionID: "ses_a", projectDirectory: work.path)],
                                    secrets: [secret.account: secret], values: [secret.account: SecretValue(canary)]))

        let pem = try BrowserExtensionKey.generatePEM()
        let runtime = DockerBrowserRuntime(
            socketPath: socket, docker: BrowserImageBuilder.rancherDocker(), contextDirectory: Self.context, configDirectory: work.appending(path: "docker"),
            key: { pem },
            network: { image in
                try await EgressGateway(client: EngineClient(socketPath: socketPath)).ensure(EgressGatewaySpec(
                    scopeKey: key, image: image, proxyPort: Int(proxyPort), token: token, extraLabels: Self.label))
                return BrowserNetworkPlacement(network: EgressGateway.networkName(key), proxy: EgressAttachment.proxyURL, certificateDirectory: certs)
            },
            containerName: names.container, volume: names.volume, extraLabels: Self.label)
        let supervisor = BrowserSupervisor(runtime: runtime, timing: .init(idle: .seconds(600)), spec: { image, placement, seccomp in
            BrowserContainerSpec(image: image, seccompProfile: seccomp, network: placement.network, proxy: placement.proxy,
                                 certificateDirectory: placement.certificateDirectory, volume: names.volume, name: names.container, extraLabels: Self.label)
        })
        let host = LiveBrowserHost(supervisor: supervisor, socket: socket, container: names.container)
        let broker = SharedBrowserBroker(host: host)
        await supervisor.observe({ _, _, _ in }, onRestart: { generation, reason in
            Task { await broker.browserRestarted(generation: generation, reason: reason) }
        })
        func call(_ tool: String, _ args: [String: JSONValue], _ session: String) async -> ClientMCPResult {
            await broker.call(ClientMCPCall(tool: tool, arguments: .object(args), sessionID: session, directory: work.path))
        }
        func text(_ session: String, _ expression: String, tab: String? = nil) async -> String {
            var args: [String: JSONValue] = ["expression": .string(expression)]
            if let tab { args["tab"] = .string(tab) }
            return await call("eval", args, session).text
        }

        do {
            // Project fixtures: a workspace whose dev server listens on its loopback only, and a service by alias.
            _ = try await client.createNetwork(name: names.net, labels: Self.label, isInternal: false)
            let devServer = """
                require('http').createServer((q,r)=>{const h={'Content-Type':'text/html'};if(q.url.startsWith('/set'))h['Set-Cookie']='session=signed-in-as-ada; Max-Age=86400; Path=/; Secure';\
                r.writeHead(200,h);r.end('<h1>hello from the dev server</h1><p>host '+q.headers.host+'</p>')}).listen(5173,'127.0.0.1')
                """
            for (name, script, alias) in [(names.ws, devServer, nil as String?),
                                          (names.api, "require('http').createServer((q,r)=>r.end('hello from api')).listen(8080)", "api")] {
                var body = ContainerCreate(image: Self.nodeImage)
                body.cmd = ["node", "-e", script]
                body.labels = Self.label
                var hostConfig = HostConfig()
                hostConfig.networkMode = names.net
                body.hostConfig = hostConfig
                if let alias { body.networkingConfig = NetworkingConfig(endpointsConfig: [names.net: .init(aliases: [alias])]) }
                try await client.startContainer(try await client.createContainer(name: name, body))
            }

            // 1. Image: built locally (cached by input hash), size.
            let buildStart = ContinuousClock.now
            let tag = try await runtime.prepareImage { _ in }
            report["build"] = "\(ContinuousClock.now - buildStart)"
            report["imageBytes"] = "\(try await client.inspectImage(tag)?.size ?? 0)"

            // 2. Lazy start: nothing runs before the first call.
            #expect(try await runtime.inspect() == nil, "no container before first use")
            let coldStart = ContinuousClock.now
            let first = await call("navigate", ["url": .string("https://proj.bc:5173/")], "ses_a")
            report["coldStartToFirstResult"] = "\(ContinuousClock.now - coldStart)"
            #expect(!first.isError, "first call: \(first.text.prefix(400))")
            let status = try await runtime.status()
            #expect(status?.sandbox == "ok", "sandbox verified: \(String(describing: status))")
            #expect(status?.extension == "connected", "paired automatically")
            #expect((status?.caCount ?? 0) >= 2, "company CA and egress CA imported")
            report["idleAfterStart"] = await Self.stats(names.container)

            // 3. Two agents at once, each in its own group; a project dev server (loopback only) and a service by name.
            async let a = call("navigate", ["url": .string("https://proj.bc:5173/")], "ses_a")
            async let b = call("navigate", ["url": .string("https://api.proj.bc/")], "ses_b")
            let (ra, rb) = await (a, b)
            #expect(!ra.isError && !rb.isError, "A: \(ra.text.prefix(300)) B: \(rb.text.prefix(300))")
            let pageA = await text("ses_a", "() => document.body.innerText")
            print("live: B navigate → \(rb.text.prefix(600))")
            let pageB = await text("ses_b", "() => document.body.innerText")
            #expect(pageA.contains("hello from the dev server") && pageA.contains("host proj.bc:5173"), "dev server by canonical name: \(pageA.prefix(300))")
            #expect(pageB.contains("hello from api"), "service by canonical name: \(pageB.prefix(300))")
            report["activeTwoAgents"] = await Self.stats(names.container)
            let groupA = BrowserNaming.group(sessionID: "ses_a"), groupB = BrowserNaming.group(sessionID: "ses_b")
            let listA = await call("tabs", ["action": .string("list")], "ses_a").text
            #expect(listA.contains(groupA) && !listA.contains(groupB), "A lists only its own group: \(listA.prefix(400))")
            let poke = await call("snapshot", ["tab": .string("\(groupA)-main")], "ses_b")
            #expect(poke.isError, "B cannot use A's tab without a share")

            // 4. A deliberate share: B drives A's tab, A gets Busy; B's concurrent calls on it are serialised.
            await host.share("\(groupA)-main", with: "ses_b")
            async let s1 = call("eval", ["tab": .string("\(groupA)-main"), "expression": .string("() => 1")], "ses_b")
            async let s2 = call("eval", ["tab": .string("\(groupA)-main"), "expression": .string("() => 2")], "ses_b")
            let (r1, r2) = await (s1, s2)
            #expect(!r1.isError && !r2.isError, "serialised calls on a shared tab both run: \(r1.text.prefix(200)) \(r2.text.prefix(200))")
            let busy = await call("eval", ["tab": .string("\(groupA)-main"), "expression": .string("() => 3")], "ses_a")
            #expect(busy.isError && busy.text.hasPrefix("Busy"), "the owner waits while B drives: \(busy.text.prefix(200))")
            _ = await call(SharedBrowserBroker.releaseTool, ["tab": .string("\(groupA)-main")], "ses_b")
            #expect(!(await call("eval", ["tab": .string("\(groupA)-main"), "expression": .string("() => 4")], "ses_a")).isError)

            // 5. Company CA: a site signed by it loads through the proxy; a placeholder from the page is substituted.
            let boundPage = await call("navigate", ["url": .string("https://bound.test/page")], "ses_a")
            #expect(!boundPage.isError, "\(boundPage.text.prefix(300))")
            let fetched = await text("ses_a", "async () => { const r = await fetch('/v1/echo', {headers: {Authorization: 'Bearer \(placeholder)'}}); return r.status + ' ' + await r.text(); }")
            #expect(bound.received.contains(canary), "the bound destination received the real value")
            #expect(!fetched.contains(canary) && fetched.contains("200"), "the page never sees the value: \(fetched.prefix(300))")

            // 6. Sign-in across an orderly idle stop (set immediately before it) and a warm start.
            let setResult = await call("navigate", ["url": .string("https://proj.bc:5173/set")], "ses_a")
            print("live: /set → \(setResult.text.prefix(400)); cookie now: \(await text("ses_a", "() => document.cookie"))")
            let stopStart = ContinuousClock.now
            await supervisor.stop(reason: "idle")
            report["orderlyStop"] = "\(ContinuousClock.now - stopStart)"
            #expect(try await runtime.inspect()?.running == false)
            let warm = ContinuousClock.now
            _ = await call("navigate", ["url": .string("https://proj.bc:5173/")], "ses_a")
            report["warmStartToFirstResult"] = "\(ContinuousClock.now - warm)"
            let cookie = await text("ses_a", "() => document.cookie")
            #expect(cookie.contains("session=signed-in-as-ada"), "sign-in survived the idle stop: \(cookie.prefix(200))")

            // 7. A crash: the generation advances, the thread is told, the sign-in is still there.
            let before = await supervisor.generation
            try await client.killContainer(names.container)
            for _ in 0..<300 {
                let generation = await supervisor.generation
                let ready = await supervisor.phase.isReady
                if generation > before, ready { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(await supervisor.generation > before)
            let after = await call("navigate", ["url": .string("https://proj.bc:5173/")], "ses_a")
            #expect(after.text.contains("[BelloCode]"), "told plainly: \(after.text.prefix(300))")
            let cookieAfter = await text("ses_a", "() => document.cookie")
            #expect(cookieAfter.contains("session=signed-in-as-ada"), "sign-in survived the crash restart: \(cookieAfter.prefix(200))")
            report["idleEnd"] = await Self.stats(names.container)
        } catch {
            Issue.record("live shared browser: \(error)")
        }

        // Cleanup: everything this test made.
        if ProcessInfo.processInfo.environment["BELLOCODE_KEEP_LIVE"] == "1" {
            try? Data(key.utf8).write(to: URL(filePath: NSTemporaryDirectory() + "bellocode-live-browser-kept"))
            try? await Task.sleep(for: .seconds(300))
        }
        await broker.shutdown()
        forwards.withLock { $0.values.forEach { $0.stop() } }
        await supervisor.stop(reason: "test end")
        for name in [names.container, names.ws, names.api] { try? await client.removeContainer(name, force: true) }
        await EgressGateway(client: client).remove(scopeKey: key, network: true)
        try? await client.removeNetwork(names.net)
        try? await client.removeVolume(names.volume, force: true)
        if ProcessInfo.processInfo.environment["BELLOCODE_KEEP_BROWSER_IMAGE"] != "1", let tag = try? await runtime.expectedTag() {
            try? await client.removeImage(tag, force: true)
        }
        proxy.stop()
        bound.stop()
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.removeItem(atPath: certs)
        let out = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "build/shared-browser-live.json")
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out)
        print("shared browser live report: \(report)")
        for name in [names.container, names.ws, names.api, gatewayName] {
            #expect(try await client.inspectContainer(name) == nil, "\(name) left behind")
        }
    }

    /// `docker stats --no-stream` for one container (CPU %, memory), via Rancher's CLI.
    static func stats(_ name: String) async -> String {
        let process = Process()
        process.executableURL = URL(filePath: NSHomeDirectory() + "/.rd/bin/docker")
        process.arguments = ["stats", "--no-stream", "--format", "{{.CPUPerc}} {{.MemUsage}}", name]
        process.environment = ["DOCKER_HOST": "unix://" + NSHomeDirectory() + "/.rd/docker.sock", "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume(returning: String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            do { try process.run() } catch { continuation.resume(returning: "unavailable") }
        }
    }
}

/// The broker's host for the live test: everything approved, bindings and shares in memory, the real supervisor.
actor LiveBrowserHost: SharedBrowserHost {
    let supervisor: BrowserSupervisor
    let socket: String
    let container: String
    var bindings: [String: BrowserBinding] = [:]
    var shared: [String: Set<String>] = [:]

    init(supervisor: BrowserSupervisor, socket: String, container: String) {
        self.supervisor = supervisor
        self.socket = socket
        self.container = container
    }

    func share(_ tab: String, with session: String) { shared[session, default: []].insert(tab) }

    func access(session: String, directory: String) async -> BrowserAccess { .allowed }
    func requestAccess(session: String, directory: String) async -> ClientMCPResult { ClientMCPResult(text: "allowed") }
    func binding(session: String, directory: String) async -> BrowserBinding {
        if let existing = bindings[session] { return existing }
        let made = BrowserBinding(sessionID: session, project: directory, group: BrowserNaming.group(sessionID: session))
        bindings[session] = made
        return made
    }
    func save(_ binding: BrowserBinding) async { bindings[binding.sessionID] = binding }
    func shares(session: String) async -> (withMe: Set<String>, byMe: Set<String>, owners: [String: String]) {
        var owners: [String: String] = [:]
        for binding in bindings.values { for tab in binding.tabs { owners[tab] = "thread \(binding.sessionID)" } }
        let byMe = Set(shared.values.flatMap { $0 }.filter { bindings[session]?.owns($0) == true })
        return (shared[session] ?? [], byMe, owners)
    }
    func beginCall() async throws { try await supervisor.begin(.call) }
    func endCall() async { await supervisor.end(.call) }
    func makeTransport() async throws -> any BrowseMCPTransport {
        try await ExecBrowseTransport(client: EngineClient(socketPath: socket), container: container)
    }
    func generation() async -> Int { await supervisor.generation }
    func threadTitle(session: String) async -> String { "thread \(session)" }
}

/// A tiny HTTPS server on the Mac's loopback signed by a given CA: `/page` (HTML) and `/v1/echo` (reflects headers).
final class MiniTLSServer: Sendable {
    let port: UInt16
    private let listener: NWListener
    private let receivedText = Mutex("")
    private let queue = DispatchQueue(label: "mini-tls", attributes: .concurrent)
    var received: String { receivedText.withLock { $0 } }

    init(name: String, authority: CertificateAuthority) async throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(try authority.identity(for: name))!)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tls)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let box = Mutex<MiniTLSServer?>(nil)
        let queue = self.queue
        listener.newConnectionHandler = { connection in box.withLock { $0 }?.serve(connection) }
        let started = Mutex(false)
        port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if started.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(returning: listener.port!.rawValue) }
                case .failed(let error): if started.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        box.withLock { $0 = self }
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        let wire = WireConnection(connection, queue: queue)
        Task {
            do {
                try await wire.start()
                while let data = try await wire.readHead(), let head = HTTPHead(data) {
                    _ = try await wire.readBody(head.requestFraming() ?? .empty, limit: 1 << 20)
                    receivedText.withLock { $0 += String(decoding: data, as: UTF8.self) }
                    let body: Data
                    var type = "text/html"
                    if head.startLine[1].hasPrefix("/v1/echo") {
                        type = "text/plain"
                        body = Data(head.fields.map { "\($0.name): \($0.value)" }.joined(separator: "\n").utf8)
                    } else {
                        body = Data("<h1>bound page</h1>".utf8)
                    }
                    try await wire.send(HTTPHead(startLine: ["HTTP/1.1", "200", "OK"], fields: [
                        HTTPField("Content-Type", type), HTTPField("Content-Length", String(body.count)),
                    ]).serialized + body)
                }
            } catch {}
            wire.cancel()
        }
    }
}
