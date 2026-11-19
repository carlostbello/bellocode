import CryptoKit
import Foundation

/// How a workspace container reaches the network when BelloCode enforces its egress (docs/features/secrets.md
/// "Egress"): it is attached only to an internal Docker network (no default route, no external DNS, IPv6 off), whose
/// one way out is the gateway container answering as `bellocode-proxy:3128`; the gateway relays to BelloCode's proxy
/// on the Mac. Part of `WorkspaceSpec`, so it applies to whichever workspace container a thread uses (a project's own,
/// or a shared one across code roots).
public struct EgressAttachment: Codable, Sendable, Equatable, Hashable {
    /// The internal network (`bellocode-egress-<scope>`).
    public var network: String
    /// SHA-256 of the proxy's CA (part of the container configuration: a new CA recreates the container).
    public var caFingerprint: String
    /// Hosts reached without the proxy: loopback and the project's service names (on the same internal network).
    public var noProxy: [String]

    /// The scope key the network was named after.
    public var scopeKey: String { String(network.dropFirst("bellocode-egress-".count)) }

    public static let proxyAlias = "bellocode-proxy"
    public static let proxyPort = 3128
    /// The gateway's raw relay to BelloCode's filtered Docker endpoint (execution modes), when it runs.
    public static let dockerPort = 2375
    public static var proxyURL: String { "http://\(proxyAlias):\(proxyPort)" }

    public init(network: String, caFingerprint: String, noProxy: [String] = []) {
        self.network = network
        self.caFingerprint = caFingerprint
        self.noProxy = noProxy
    }

    /// Variables every process in the workspace sees (exec environments cannot override these to reach the network:
    /// the network itself has no other way out).
    public var environment: [String: String] {
        let noProxy = (["localhost", "127.0.0.1", "::1", Self.proxyAlias] + noProxy).joined(separator: ",")
        return [
            "HTTP_PROXY": Self.proxyURL, "HTTPS_PROXY": Self.proxyURL, "http_proxy": Self.proxyURL, "https_proxy": Self.proxyURL,
            "NO_PROXY": noProxy, "no_proxy": noProxy,
            // npm and yarn read their own settings too; pip and git read the variables above.
            "npm_config_proxy": Self.proxyURL, "npm_config_https_proxy": Self.proxyURL,
            "BELLOCODE_EGRESS": "enforced", "BELLOCODE_EGRESS_CA": caFingerprint.prefix(16).description,
        ]
    }

    /// Applies the attachment to a create body: the internal network as the only network, the proxy variables
    /// (before anything else sets them), IPv6 off inside the container.
    public func apply(to body: inout ContainerCreate) {
        var env = body.env ?? []
        let names = Set(environment.keys)
        env.removeAll { entry in names.contains(String(entry.split(separator: "=", maxSplits: 1).first ?? "")) }
        env += environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        body.env = env
        var host = body.hostConfig ?? HostConfig()
        host.networkMode = network
        host.portBindings = nil
        host.sysctls = (host.sysctls ?? [:]).merging(["net.ipv6.conf.all.disable_ipv6": "1", "net.ipv6.conf.default.disable_ipv6": "1"]) { _, new in new }
        body.hostConfig = host
        body.exposedPorts = nil
        body.networkingConfig = nil
    }
}

/// The gateway for one egress scope: what it runs and where it relays to.
public struct EgressGatewaySpec: Sendable, Equatable {
    /// `<projectKey>` for a project's container, or the shared workspace's key.
    public var scopeKey: String
    /// An image with `node` or `python3` (the workspace's own image normally: already pulled and allowed by policy).
    public var image: String
    /// BelloCode's proxy on the Mac (reached as `host.docker.internal:<port>`).
    public var proxyPort: Int
    /// Per-launch token the gateway sends first on every connection (the proxy refuses connections without it).
    public var token: String
    public var extraLabels: [String: String]

    public init(scopeKey: String, image: String, proxyPort: Int, token: String, extraLabels: [String: String] = [:]) {
        self.scopeKey = scopeKey
        self.image = image
        self.proxyPort = proxyPort
        self.token = token
        self.extraLabels = extraLabels
    }

    public var networkName: String { EgressGateway.networkName(scopeKey) }
    public var containerName: String { "bellocode-egress-gw-\(scopeKey)" }

    /// Identifies the configuration (recreated when it changes); the token is hashed, never stored in a label.
    var configHash: String {
        SHA256.hash(data: Data("\(image)\n\(proxyPort)\n\(token)\n\(EgressGateway.relayScriptVersion)".utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

public struct EgressGatewayError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// Creates and keeps the internal network and the gateway container (ContainerKit; no secrets pass through here).
public struct EgressGateway: Sendable {
    public static let labelEgress = "app.bellocode.egress"
    public static let labelScope = "app.bellocode.egress-scope"
    public static let labelConfig = "app.bellocode.egress-config"
    static let relayScriptVersion = "5"

    public let client: EngineClient
    public init(client: EngineClient) { self.client = client }

    public static func networkName(_ scopeKey: String) -> String { "bellocode-egress-\(scopeKey)" }

    /// The labels proving a gateway container or network is BelloCode's for this scope (R07: a same-name object of
    /// someone else is never removed, recreated or adopted; `ForeignResourceError` names it instead).
    public static func ownership(_ scopeKey: String) -> [String: String] { [labelEgress: "1", labelScope: scopeKey] }

    /// The internal network (created if missing): no route out, no IPv6, no masquerading. Returns its name.
    @discardableResult
    public func ensureNetwork(scopeKey: String, extraLabels: [String: String] = [:]) async throws -> String {
        let name = Self.networkName(scopeKey)
        if let existing = try await client.ownedNetwork(name, required: Self.ownership(scopeKey)) {
            guard existing.isInternal else {
                throw EgressGatewayError("The network \(name) exists but is not internal; remove it (Prune BelloCode Resources) so BelloCode can recreate it.")
            }
            return name
        }
        do {
            _ = try await client.createInternalNetwork(
                name: name, labels: [Self.labelEgress: "1", Self.labelScope: scopeKey, WorkspaceSpec.labelWorkspace: "1"].merging(extraLabels) { a, _ in a })
        } catch ContainerError.conflict {
            // Created concurrently (the helper and the app): fine if it is ours.
            guard try await client.ownedNetwork(name, required: Self.ownership(scopeKey)) != nil else {
                throw ForeignResourceError(kind: .network, name: name)
            }
        }
        return name
    }

    /// Makes sure the gateway runs with this configuration: the network exists, the container is (re)created when its
    /// configuration changed, started, its relay listening on the internal network, and then joined to the default
    /// bridge (its only way out, to the Mac).
    public func ensure(_ spec: EgressGatewaySpec) async throws {
        try await ensureNetwork(scopeKey: spec.scopeKey, extraLabels: spec.extraLabels)
        if let existing = try await client.ownedContainer(spec.containerName, required: Self.ownership(spec.scopeKey)) {
            if existing.config.labels?[Self.labelConfig] == spec.configHash, existing.state.running { return }
            try? await client.removeContainer(existing.id, force: true)
        }
        var body = ContainerCreate(image: spec.image)
        body.entrypoint = ["/bin/sh", "-c", Self.relayLauncher]
        body.cmd = []
        body.env = ["BC_HOST=host.docker.internal", "BC_PORT=\(spec.proxyPort)", "BC_TOKEN=\(spec.token)",
                    "BC_LISTEN_PORT=\(EgressAttachment.proxyPort)", "BC_NODE=\(Self.nodeRelay)", "BC_PY=\(Self.pythonRelay)"]
            + ["BC_DOCKER_LISTEN=\(EgressAttachment.dockerPort)"]
        body.user = "65534:65534"
        body.labels = [Self.labelEgress: "1", Self.labelScope: spec.scopeKey, Self.labelConfig: spec.configHash, WorkspaceSpec.labelWorkspace: "1"]
            .merging(spec.extraLabels) { a, _ in a }
        body.stopSignal = "SIGTERM"
        body.stopTimeout = 1
        var host = HostConfig()
        host.init_ = true
        host.privileged = false
        host.readonlyRootfs = true
        host.capDrop = ["ALL"]
        host.securityOpt = ["no-new-privileges:true"]
        host.nanoCPUs = 1_000_000_000
        host.memory = 256 << 20
        host.pidsLimit = 128
        host.networkMode = spec.networkName
        host.sysctls = ["net.ipv6.conf.all.disable_ipv6": "1"]
        body.hostConfig = host
        body.networkingConfig = NetworkingConfig(endpointsConfig: [spec.networkName: .init(aliases: [EgressAttachment.proxyAlias])])
        let id = try await client.createContainer(name: spec.containerName, body)
        try await client.startContainer(id)
        // The relay binds only the internal network's address, chosen at start while that is its only interface; it
        // retries its upstream dial for a few seconds, so a connection that arrives before the bridge joins still works.
        try await waitForRelay(id)
        try await client.connectNetwork("bridge", container: id)
    }

    /// Waits (bounded) until the relay printed `ready`, or reports why it could not start.
    func waitForRelay(_ id: String) async throws {
        for _ in 0..<100 {
            let text = try await logText(id)
            if text.contains("bellocode-relay ready") { return }
            if text.contains("bellocode-relay unavailable") {
                throw EgressGatewayError("The egress gateway needs node or python3 in its image; the workspace's image has neither. Choose an image with one of them (Project Settings ▸ Environment).")
            }
            if let inspect = try await client.inspectContainer(id), !inspect.state.running {
                throw EgressGatewayError("The egress gateway stopped (exit \(inspect.state.exitCode ?? -1)).")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw EgressGatewayError("The egress gateway did not start in time.")
    }

    private func logText(_ id: String) async throws -> String {
        var text = ""
        for try await chunk in try await client.logs(id, follow: false, tail: "20") { text += String(decoding: chunk.bytes, as: UTF8.self) }
        return text
    }

    /// Joins the gateway to another Docker network at runtime (a project's services or workspace network, for routes
    /// from a shared browser): a `PortForwarder` on the gateway with `containerHost` set to a name on that network then
    /// reaches it. Idempotent.
    public func attach(scopeKey: String, network: String, aliases: [String]? = nil) async throws {
        try await client.connectNetwork(network, container: "bellocode-egress-gw-\(scopeKey)", aliases: aliases)
    }

    /// Leaves a network joined with `attach` (absent: nothing to do).
    public func detach(scopeKey: String, network: String) async {
        try? await client.disconnectNetwork(network, container: "bellocode-egress-gw-\(scopeKey)")
    }

    /// The gateway's container name for a scope (the container a `PortForwarder` relays through).
    public static func containerName(_ scopeKey: String) -> String { "bellocode-egress-gw-\(scopeKey)" }

    /// Removes the gateway (and the network when `network` is true and nothing else uses it).
    public func remove(scopeKey: String, network: Bool) async {
        // Only what carries this scope's labels; a foreign same-name container or network stays.
        if let existing = try? await client.ownedContainer(Self.containerName(scopeKey), required: Self.ownership(scopeKey)) {
            try? await client.removeContainer(existing.id, force: true)
        }
        if network, let owned = try? await client.ownedNetwork(Self.networkName(scopeKey), required: Self.ownership(scopeKey)) {
            try? await client.removeNetwork(owned.id)
        }
    }

    // MARK: Relay programs

    /// Chooses node, then python3; prints `bellocode-relay unavailable` when neither exists.
    static let relayLauncher = """
        if command -v node >/dev/null 2>&1; then exec node -e "$BC_NODE"; \
        elif command -v python3 >/dev/null 2>&1; then exec python3 -c "$BC_PY"; \
        else echo "bellocode-relay unavailable"; exit 3; fi
        """

    /// Listens on the container's one non-loopback IPv4 address (the internal network) and relays each connection to
    /// the proxy with the token line first.
    /// Half-closes are passed on (`allowHalfOpen`): `docker run` ends its side of an attach stream and then reads.
    static let nodeRelay = """
        const net=require('net'),os=require('os');
        const ip=Object.values(os.networkInterfaces()).flat().find(i=>i&&i.family==='IPv4'&&!i.internal);
        if(!ip){console.log('bellocode-relay no-address');process.exit(4)}
        const T=process.env.BC_TOKEN,H=process.env.BC_HOST,P=+process.env.BC_PORT;
        const relay=(line)=>net.createServer({allowHalfOpen:true},c=>{c.pause();let u=null;
        c.on('error',()=>{if(u)u.destroy();c.destroy()});c.on('close',()=>{if(u)u.destroy()});
        const dial=n=>{const s=net.connect({port:P,host:H,allowHalfOpen:true});
        s.on('connect',()=>{u=s;s.write(line);c.pipe(s);s.pipe(c);c.resume();s.on('close',()=>c.destroy())});
        s.on('error',()=>{if(!u&&n<50&&!c.destroyed)setTimeout(()=>dial(n+1),100);else c.destroy()})};dial(0)});
        relay('BCEGRESS '+T+'\\n').listen(+process.env.BC_LISTEN_PORT,ip.address,()=>console.log('bellocode-relay ready '+ip.address));
        relay('BCEGRESS '+T+' docker\\n').listen(+process.env.BC_DOCKER_LISTEN,ip.address);
        """

    static let pythonRelay = """
        import os,socket,threading,time
        def addr():
            s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
            try:
                s.connect(('10.255.255.255',1));return s.getsockname()[0]
            except Exception:
                return socket.gethostbyname(socket.gethostname())
            finally:
                s.close()
        T=os.environ['BC_TOKEN'];H=os.environ['BC_HOST'];P=int(os.environ['BC_PORT'])
        def pump(a,b):
            try:
                while True:
                    d=a.recv(65536)
                    if not d:break
                    b.sendall(d)
            except Exception:pass
            try:b.shutdown(socket.SHUT_WR)
            except Exception:pass
        def serve(c,preamble):
            u=None
            for _ in range(50):
                try:
                    u=socket.create_connection((H,P));break
                except Exception:
                    time.sleep(0.1)
            if u is None:
                c.close();return
            try:u.sendall(('BCEGRESS '+T+preamble+'\\n').encode())
            except Exception:
                c.close();u.close();return
            t=threading.Thread(target=pump,args=(c,u),daemon=True);t.start();pump(u,c);t.join()
            for s in (c,u):
                try:s.close()
                except Exception:pass
        def listen(port,preamble):
            l=socket.socket();l.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
            l.bind((ip,port));l.listen(128)
            def loop():
                while True:
                    c,_=l.accept();threading.Thread(target=serve,args=(c,preamble),daemon=True).start()
            return loop
        ip=addr()
        main=listen(int(os.environ['BC_LISTEN_PORT']),'')
        threading.Thread(target=listen(int(os.environ['BC_DOCKER_LISTEN']),' docker'),daemon=True).start()
        print('bellocode-relay ready '+ip,flush=True)
        main()
        """
}

extension EngineClient {
    /// An internal bridge network: no gateway to the outside, IPv6 off, no masquerading.
    public func createInternalNetwork(name: String, labels: [String: String]) async throws -> String {
        struct Body: Encodable {
            var name: String
            var labels: [String: String]
            var `internal` = true
            var enableIPv6 = false
            var options: [String: String]
            enum CodingKeys: String, CodingKey {
                case name = "Name", labels = "Labels", `internal` = "Internal", enableIPv6 = "EnableIPv6", options = "Options"
            }
        }
        struct Created: Decodable { var Id: String }
        let data = try await call("POST", "/networks/create", json: Body(
            name: name, labels: labels, options: ["com.docker.network.bridge.enable_ip_masquerade": "false"]))
        return try JSONDecoder().decode(Created.self, from: data).Id
    }

    /// `POST /networks/{id}/disconnect`.
    public func disconnectNetwork(_ network: String, container: String) async throws {
        struct Body: Encodable {
            var container: String
            var force = true
            enum CodingKeys: String, CodingKey { case container = "Container", force = "Force" }
        }
        try await call("POST", "/networks/\(Self.escape(network))/disconnect", json: Body(container: container))
    }

    /// `POST /networks/{id}/connect`.
    public func connectNetwork(_ network: String, container: String, aliases: [String]? = nil) async throws {
        struct Body: Encodable {
            struct Endpoint: Encodable {
                var aliases: [String]?
                enum CodingKeys: String, CodingKey { case aliases = "Aliases" }
            }
            var container: String
            var endpointConfig: Endpoint?
            enum CodingKeys: String, CodingKey { case container = "Container", endpointConfig = "EndpointConfig" }
        }
        do {
            try await call("POST", "/networks/\(Self.escape(network))/connect",
                           json: Body(container: container, endpointConfig: aliases.map { Body.Endpoint(aliases: $0) }))
        } catch ContainerError.conflict {
            // Already connected.
        }
    }
}
