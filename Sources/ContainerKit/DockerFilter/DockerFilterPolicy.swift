import Foundation

// The policy of BelloCode's filtered Docker endpoint (docs/features/containers.md, "Docker from the workspace").
// Default deny: a request is forwarded only when its route is listed here and every check passes; anything else gets a
// Docker-style error the agent can act on. Every operation is checked, including exec, attach, build contexts and the
// hijacked streams they open (a stream is only opened for a container this scope created).

/// Who is asking: the shared workspace or one project, with the folders its bind mounts may use.
public struct DockerScope: Sendable, Equatable {
    /// Stable key (`WorkspaceSpec.projectKey`, or the shared workspace's).
    public var key: String
    /// Folders bind mounts may use (code roots in shared mode; the project and its worktrees otherwise).
    public var roots: [String]
    /// Limits every container gets at most (and by default).
    public var limits: ResourceLimits
    /// Containers this scope may have at once.
    public var maxContainers: Int
    /// Enforced egress (secret manager): what the scope's own workspace has, applied to every container and network it
    /// creates. Nil: containers get ordinary networking.
    public var egress: DockerEgress?

    public init(key: String, roots: [String], limits: ResourceLimits = ResourceLimits(cpus: 2, memoryBytes: 4 << 30, pidsLimit: 2048),
                maxContainers: Int = 32, egress: DockerEgress? = nil) {
        self.key = key
        self.roots = roots
        self.limits = limits
        self.maxContainers = maxContainers
        self.egress = egress
    }
}

/// The egress boundary of a scope (docs/features/secrets.md "Agent-created containers"): containers join the scope's
/// internal egress network (alone, or beside the agent's own networks, which are created internal), get the proxy
/// variables and the CA bundle, and IPv6 off. The only way out is `bellocode-proxy`, which also relays `docker` to
/// this endpoint.
public struct DockerEgress: Sendable, Equatable {
    public var network: String
    public var environment: [String: String]
    /// Host folder of the container trust bundles (mounted read-only like the workspace's).
    public var certificateDirectory: String?

    public init(network: String, environment: [String: String], certificateDirectory: String?) {
        self.network = network
        self.environment = environment
        self.certificateDirectory = certificateDirectory
    }
}

/// Labels the endpoint puts on everything it creates (containers, volumes, networks, built images). A request may never
/// set an `app.bellocode.` label itself.
public enum DockerAgentLabels {
    public static let agent = "app.bellocode.agent"
    public static let scope = "app.bellocode.agent-scope"
    public static let reservedPrefix = "app.bellocode."
    /// Names reserved for BelloCode's own resources.
    public static let reservedNamePrefix = "bellocode-"

    public static func labels(_ scope: String) -> [String: String] { [agent: "1", Self.scope: scope] }
}

/// A Docker object as the daemon reports it.
public struct DockerObject: Sendable, Equatable {
    public var id: String
    public var name: String
    public var labels: [String: String]
    public init(id: String, name: String = "", labels: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.labels = labels
    }
    public func owned(by scope: String) -> Bool { labels[DockerAgentLabels.scope] == scope }
}

/// What the policy asks the daemon (inspect by ID or name). Implemented over the real socket by
/// `EngineDockerLookup`; tests use a fake.
public protocol DockerLookup: Sendable {
    func container(_ reference: String) async -> DockerObject?
    func volume(_ name: String) async -> DockerObject?
    func network(_ reference: String) async -> DockerObject?
    func image(_ reference: String) async -> DockerObject?
    /// The container an exec instance belongs to.
    func execContainer(_ id: String) async -> String?
    func containerCount(scope: String) async -> Int
    func createVolume(name: String, labels: [String: String]) async throws
}

/// One parsed API request (token and version prefix removed from the path).
public struct DockerAPIRequest: Sendable {
    public var method: String
    /// The route, e.g. `/containers/create` (no `/v1.47`, no token).
    public var path: String
    /// `/v1.47` or empty.
    public var versionPrefix: String
    public var query: [(String, String)]
    public var body: Data?

    public init(method: String, path: String, versionPrefix: String = "", query: [(String, String)] = [], body: Data? = nil) {
        self.method = method
        self.path = path
        self.versionPrefix = versionPrefix
        self.query = query
        self.body = body
    }

    public func value(_ name: String) -> String? { query.first { $0.0 == name }?.1 }
    public func values(_ name: String) -> [String] { query.filter { $0.0 == name }.map(\.1) }

    /// Splits a request target (`/v1.47/containers/json?all=1`) into version prefix, route and query.
    public static func parse(method: String, target: String, body: Data? = nil) -> DockerAPIRequest {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var path = String(parts.first ?? "")
        var prefix = ""
        if path.hasPrefix("/v"), let slash = path.dropFirst().firstIndex(of: "/"),
           path[path.index(path.startIndex, offsetBy: 2)..<slash].allSatisfy({ $0.isNumber || $0 == "." }) {
            prefix = String(path[..<slash])
            path = String(path[slash...])
        }
        path = (path.removingPercentEncoding ?? path)
        var query: [(String, String)] = []
        if parts.count == 2 {
            for item in URLComponents(string: "?" + parts[1])?.queryItems ?? [] { query.append((item.name, item.value ?? "")) }
        }
        return DockerAPIRequest(method: method.uppercased(), path: path, versionPrefix: prefix, query: query, body: body)
    }

    /// The target to send to the daemon (version prefix kept, query re-encoded, path segments percent-encoded).
    public var target: String {
        let encodedPath = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? String($0) }
            .joined(separator: "/")
        var target = versionPrefix + encodedPath
        if !query.isEmpty {
            var components = URLComponents()
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            target += "?" + (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        }
        return target
    }
}

/// What to do with a request.
public enum DockerDecision: Sendable, Equatable {
    /// Forward (possibly rewritten). `streamBody`: the body (build context, archive) is passed through as it arrives;
    /// `hijack`: the connection becomes a raw stream after the answer (attach, exec start, build session).
    case forward(DockerAPIRequest, streamBody: Bool, hijack: Bool, after: AfterAction?)
    case refuse(status: Int, message: String)

    public static func == (lhs: DockerDecision, rhs: DockerDecision) -> Bool {
        switch (lhs, rhs) {
        case (.refuse(let a, let b), .refuse(let c, let d)): a == c && b == d
        case (.forward(let a, let s1, let h1, let x), .forward(let b, let s2, let h2, let y)):
            a.target == b.target && a.body == b.body && s1 == s2 && h1 == h2 && x == y
        default: false
        }
    }

    public var isRefused: Bool { if case .refuse = self { true } else { false } }
    public var message: String? { if case .refuse(_, let message) = self { message } else { nil } }
}

/// Bookkeeping after a successful forward.
public enum AfterAction: Sendable, Equatable {
    /// An image was pulled for the scope (it may delete it later; Prune may remove it).
    case pulled(String)
}

public struct DockerFilterPolicy: Sendable {
    public let lookup: any DockerLookup
    /// Why an image may not be pulled or run under the image policy, or nil.
    public let imageRefusal: @Sendable (String) -> String?
    /// Images a scope pulled (it may delete them): scope → references.
    public let pulledBy: @Sendable (String) -> Set<String>
    /// Canonicalises a host path (links resolved, longest existing prefix); injectable for tests.
    public let canonical: @Sendable (String) -> String

    public init(lookup: any DockerLookup, imageRefusal: @escaping @Sendable (String) -> String? = { _ in nil },
                pulledBy: @escaping @Sendable (String) -> Set<String> = { _ in [] },
                canonical: @escaping @Sendable (String) -> String = DockerFilterPolicy.resolveExistingPrefix) {
        self.lookup = lookup
        self.imageRefusal = imageRefusal
        self.pulledBy = pulledBy
        self.canonical = canonical
    }

    static let prefix = "BelloCode refused this Docker request: "

    static func refuse(_ reason: String, status: Int = 403) -> DockerDecision {
        .refuse(status: status, message: prefix + reason)
    }

    // MARK: Routing

    public func decide(_ request: DockerAPIRequest, scope: DockerScope) async -> DockerDecision {
        let method = request.method
        let segments = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if segments.contains(where: { $0 == "." || $0 == ".." }) || request.path.contains("\0") {
            return Self.refuse("the request path contains “.” or “..” segments.", status: 400)
        }
        let plain = DockerDecision.forward(request, streamBody: false, hijack: false, after: nil)
        switch (method, segments.first ?? "") {
        case ("GET", "_ping"), ("HEAD", "_ping"):
            return segments.count == 1 ? plain : unknown(request)
        case ("GET", "version"), ("GET", "info"):
            return segments.count == 1 ? plain : unknown(request)
        case (_, "containers"): return await containers(request, segments: segments, scope: scope)
        case (_, "exec"): return await exec(request, segments: segments, scope: scope)
        case (_, "images"): return await images(request, segments: segments, scope: scope)
        case ("POST", "build"): return await build(request, segments: segments, scope: scope)
        case ("POST", "session"):
            // BuildKit's file-sync session for a `/build` (the daemon asks the client for its context): no daemon
            // control flows this way.
            return segments.count == 1 ? .forward(request, streamBody: false, hijack: true, after: nil) : unknown(request)
        case (_, "grpc"):
            return Self.refuse("BuildKit's gRPC API (docker buildx, BuildKit builds) cannot be filtered, so it is not available here. Plain docker build works: the environment sets DOCKER_BUILDKIT=0, which uses the classic builder through the filtered /build route.")
        case (_, "networks"): return await networks(request, segments: segments, scope: scope)
        case (_, "volumes"): return await volumes(request, segments: segments, scope: scope)
        case ("GET", "events"): return withScopeFilter(request, scope: scope)
        case ("GET", "distribution"):
            let reference = segments.dropFirst().dropLast().joined(separator: "/")
            if let refusal = imageRefusal(reference) { return Self.refuse(refusal) }
            return segments.last == "json" ? plain : unknown(request)
        case (_, "auth"):
            return Self.refuse("registry sign-in is not available through BelloCode's endpoint. Pull public images, or ask the person to sign in to the registry in BelloCode's settings.")
        default:
            return unknown(request)
        }
    }

    func unknown(_ request: DockerAPIRequest) -> DockerDecision {
        Self.refuse("\(request.method) \(request.path) is not one of the operations BelloCode's filtered endpoint allows (containers, exec, images, build, networks and volumes this workspace created; pulls under the image policy). Nothing was sent to Docker.")
    }

    // MARK: Containers

    func containers(_ request: DockerAPIRequest, segments: [String], scope: DockerScope) async -> DockerDecision {
        let plain = DockerDecision.forward(request, streamBody: false, hijack: false, after: nil)
        if segments.count == 2 {
            switch (request.method, segments[1]) {
            case ("GET", "json"): return withScopeFilter(request, scope: scope)
            case ("POST", "create"): return await createContainer(request, scope: scope)
            case ("POST", "prune"): return withScopeFilter(request, scope: scope)
            case ("GET", _), ("DELETE", _): break  // GET/DELETE /containers/{name}: checked below
            default: return unknown(request)
            }
        }
        guard segments.count >= 2 else { return unknown(request) }
        let reference = segments[1]
        guard let container = await lookup.container(reference) else {
            return .refuse(status: 404, message: "No such container: \(reference)")
        }
        guard container.owned(by: scope.key) else {
            return Self.refuse("the container \(container.name.isEmpty ? reference : container.name) was not created through this workspace's Docker endpoint (it belongs to BelloCode, another project or something else on this Mac), so it cannot be inspected, changed, attached to or exec'd into.")
        }
        // Address it by full ID from here on, so a rename or a new container with the same name cannot be swapped in.
        var pinned = request
        pinned.path = "/containers/\(container.id)" + (segments.count > 2 ? "/" + segments.dropFirst(2).joined(separator: "/") : "")
        let pinnedPlain = DockerDecision.forward(pinned, streamBody: false, hijack: false, after: nil)
        if segments.count == 2 {
            switch request.method {
            case "GET", "DELETE": return pinnedPlain
            default: return unknown(request)
            }
        }
        let action = segments[2]
        switch (request.method, action) {
        case ("GET", "json"), ("GET", "top"), ("GET", "logs"), ("GET", "stats"), ("GET", "changes"),
             ("POST", "start"), ("POST", "stop"), ("POST", "restart"), ("POST", "kill"), ("POST", "pause"), ("POST", "unpause"),
             ("POST", "wait"), ("POST", "resize"), ("GET", "archive"), ("HEAD", "archive"):
            _ = plain
            return pinnedPlain
        case ("PUT", "archive"):
            return .forward(pinned, streamBody: true, hijack: false, after: nil)
        case ("POST", "attach") where segments.count == 3:
            return .forward(pinned, streamBody: false, hijack: true, after: nil)
        case ("POST", "rename"):
            if let name = request.value("name"), name.hasPrefix(DockerAgentLabels.reservedNamePrefix) {
                return Self.refuse("names starting with “bellocode-” are reserved for BelloCode's own containers.")
            }
            return pinnedPlain
        case ("POST", "exec"):
            return execCreate(pinned)
        case ("POST", "update"):
            return Self.refuse("changing a running container's limits is not allowed; recreate it instead.")
        default:
            return unknown(request)
        }
    }

    func execCreate(_ request: DockerAPIRequest) -> DockerDecision {
        guard let body = request.body, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return Self.refuse("the exec request has no valid JSON body.", status: 400)
        }
        if truthy(object["Privileged"]) { return Self.refuse("privileged exec is not allowed.") }
        return .forward(request, streamBody: false, hijack: false, after: nil)
    }

    func exec(_ request: DockerAPIRequest, segments: [String], scope: DockerScope) async -> DockerDecision {
        guard segments.count == 3 else { return unknown(request) }
        guard let containerID = await lookup.execContainer(segments[1]) else {
            return .refuse(status: 404, message: "No such exec instance: \(segments[1])")
        }
        guard let container = await lookup.container(containerID), container.owned(by: scope.key) else {
            return Self.refuse("that exec instance belongs to a container this workspace did not create.")
        }
        switch (request.method, segments[2]) {
        case ("POST", "start"): return .forward(request, streamBody: false, hijack: true, after: nil)
        case ("POST", "resize"), ("GET", "json"): return .forward(request, streamBody: false, hijack: false, after: nil)
        default: return unknown(request)
        }
    }

    /// `POST /containers/create`: the body's every security-relevant field is checked; labels and limits are added.
    func createContainer(_ request: DockerAPIRequest, scope: DockerScope) async -> DockerDecision {
        if let name = request.value("name"), name.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasPrefix(DockerAgentLabels.reservedNamePrefix) {
            return Self.refuse("names starting with “bellocode-” are reserved for BelloCode's own containers.")
        }
        guard let body = request.body, var config = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return Self.refuse("the create request has no valid JSON body.", status: 400)
        }
        for key in config.keys where !Self.containerConfigKeys.contains(key) && !isEmpty(config[key]) {
            return Self.refuse("the container setting \(key) is not supported by BelloCode's endpoint.")
        }
        guard let image = config["Image"] as? String, !image.isEmpty else { return Self.refuse("no image was given.", status: 400) }
        if let refusal = await imageCheck(image, scope: scope) { return Self.refuse(refusal) }
        switch labelsWithScope(config["Labels"], scope: scope) {
        case .failure(let refusal): return Self.refuse(refusal.message)
        case .success(let labels): config["Labels"] = labels
        }
        var host = (config["HostConfig"] as? [String: Any]) ?? [:]
        switch await checkHostConfig(&host, scope: scope) {
        case .some(let message): return Self.refuse(message)
        case .none: break
        }
        config["HostConfig"] = host
        if let networking = config["NetworkingConfig"] as? [String: Any], let endpoints = networking["EndpointsConfig"] as? [String: Any] {
            for name in endpoints.keys.sorted() {
                if let message = await networkUseCheck(name, scope: scope) { return Self.refuse(message) }
            }
        }
        if let egress = scope.egress { applyEgress(egress, to: &config) }
        guard await lookup.containerCount(scope: scope.key) < scope.maxContainers else {
            return Self.refuse("this workspace already has \(scope.maxContainers) containers. Remove some (docker rm, docker compose down) first.")
        }
        var rewritten = request
        rewritten.body = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        return .forward(rewritten, streamBody: false, hijack: false, after: nil)
    }

    /// Enforced egress for an agent container (after every check: these additions are BelloCode's, not the request's).
    func applyEgress(_ egress: DockerEgress, to config: inout [String: Any]) {
        var host = (config["HostConfig"] as? [String: Any]) ?? [:]
        let mode = (host["NetworkMode"] as? String) ?? ""
        var networking = (config["NetworkingConfig"] as? [String: Any]) ?? [:]
        var endpoints = (networking["EndpointsConfig"] as? [String: Any]) ?? [:]
        for builtIn in ["bridge", "default"] { endpoints.removeValue(forKey: builtIn) }
        if ["", "default", "bridge"].contains(mode) {
            host["NetworkMode"] = egress.network
        }
        if mode != "none", !mode.hasPrefix("container:") {
            // Beside the agent's own (internal) networks: the egress network is how the proxy is reached.
            if endpoints[egress.network] == nil { endpoints[egress.network] = [String: Any]() }
            networking["EndpointsConfig"] = endpoints
            config["NetworkingConfig"] = networking
        }
        var env = (config["Env"] as? [String]) ?? []
        let present = Set(env.compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        for (name, value) in egress.environment.sorted(by: { $0.key < $1.key }) where !present.contains(name) {
            env.append("\(name)=\(value)")
        }
        config["Env"] = env
        if let directory = egress.certificateDirectory {
            let corporate = CorporateNetwork(certificateDirectory: directory)
            for (name, value) in corporate.environment(noProxyExtra: []).sorted(by: { $0.key < $1.key }) where !present.contains(name) {
                config["Env"] = ((config["Env"] as? [String]) ?? []) + ["\(name)=\(value)"]
            }
            var mounts = (host["Mounts"] as? [[String: Any]]) ?? []
            let targets = Set(mounts.compactMap { $0["Target"] as? String })
            for mount in corporate.mounts where !targets.contains(mount.target) {
                mounts.append(["Type": "bind", "Source": mount.source, "Target": mount.target, "ReadOnly": true])
            }
            host["Mounts"] = mounts
        }
        var sysctls = (host["Sysctls"] as? [String: Any]) ?? [:]
        sysctls["net.ipv6.conf.all.disable_ipv6"] = "1"
        host["Sysctls"] = sysctls
        config["HostConfig"] = host
    }

    /// Top-level container settings that are allowed (each security-relevant one is checked).
    static let containerConfigKeys: Set<String> = [
        "Hostname", "Domainname", "User", "AttachStdin", "AttachStdout", "AttachStderr", "ExposedPorts", "Tty", "OpenStdin", "StdinOnce",
        "Env", "Cmd", "Healthcheck", "ArgsEscaped", "Image", "Volumes", "WorkingDir", "Entrypoint", "NetworkDisabled", "MacAddress",
        "OnBuild", "Labels", "StopSignal", "StopTimeout", "Shell", "HostConfig", "NetworkingConfig", "Platform",
    ]
    /// HostConfig keys with no effect on isolation.
    static let freeHostKeys: Set<String> = [
        "RestartPolicy", "AutoRemove", "ShmSize", "Init", "Tmpfs", "ExtraHosts", "Dns", "DnsOptions", "DnsSearch", "Ulimits",
        "ReadonlyRootfs", "GroupAdd", "ConsoleSize", "CpuShares", "CpuPeriod", "CpuQuota", "CpuRealtimePeriod", "CpuRealtimeRuntime",
        "CpusetCpus", "CpusetMems", "MemoryReservation", "MemorySwap", "MemorySwappiness", "OomScoreAdj", "BlkioWeight",
        "CpuCount", "CpuPercent", "ContainerIDFile", "KernelMemory", "KernelMemoryTCP", "OomKillDisable", "Isolation",
        "CapDrop", "IOMaximumBandwidth", "IOMaximumIOps",
    ]
    /// HostConfig keys that must be empty (host devices, kernel parameters, unmasking, alternative runtimes…).
    static let emptyHostKeys: [String: String] = [
        "Devices": "host devices", "DeviceRequests": "device requests (GPUs)", "DeviceCgroupRules": "device cgroup rules",
        "Sysctls": "kernel parameters (sysctls)", "CgroupParent": "a cgroup parent", "MaskedPaths": "changed masked paths",
        "ReadonlyPaths": "changed read-only paths", "VolumeDriver": "a volume driver", "StorageOpt": "storage options",
        "Annotations": "annotations", "BlkioWeightDevice": "block device settings", "BlkioDeviceReadBps": "block device settings",
        "BlkioDeviceWriteBps": "block device settings", "BlkioDeviceReadIOps": "block device settings",
        "BlkioDeviceWriteIOps": "block device settings", "Links": "legacy links",
    ]

    /// Checks (and rewrites) a HostConfig; returns why it is refused, or nil.
    func checkHostConfig(_ host: inout [String: Any], scope: DockerScope) async -> String? {
        let checked: Set<String> = [
            "Binds", "Mounts", "NetworkMode", "PortBindings", "PublishAllPorts", "Privileged", "CapAdd", "SecurityOpt", "PidMode",
            "IpcMode", "UTSMode", "UsernsMode", "CgroupnsMode", "Cgroup", "VolumesFrom", "Runtime", "LogConfig", "Memory", "NanoCpus",
            "PidsLimit", "CpusetCpus",
        ]
        for key in host.keys.sorted() where !checked.contains(key) && !Self.freeHostKeys.contains(key) {
            if let what = Self.emptyHostKeys[key] {
                if !isEmpty(host[key]) { return "\(what) are not allowed (\(key))." }
            } else if !isEmpty(host[key]) {
                return "the host setting \(key) is not supported by BelloCode's endpoint."
            }
        }
        if truthy(host["Privileged"]) { return "privileged containers are not allowed." }
        if !isEmpty(host["CapAdd"]) { return "adding capabilities (--cap-add \(stringList(host["CapAdd"]).joined(separator: ", "))) is not allowed." }
        for option in stringList(host["SecurityOpt"]) {
            let normalized = option.replacingOccurrences(of: "=", with: ":")
            guard normalized == "no-new-privileges" || normalized == "no-new-privileges:true" else {
                return "the security option “\(option)” is not allowed (only no-new-privileges)."
            }
        }
        var securityOptions = stringList(host["SecurityOpt"]).filter { !$0.hasPrefix("no-new-privileges") }
        securityOptions.append("no-new-privileges:true")
        host["SecurityOpt"] = securityOptions
        for (key, label) in [("PidMode", "PID"), ("IpcMode", "IPC"), ("UTSMode", "UTS"), ("UsernsMode", "user"), ("CgroupnsMode", "cgroup")] {
            let value = (host[key] as? String) ?? ""
            if value == "host" { return "the host \(label) namespace (--\(label.lowercased()) host) is not allowed." }
            if value.hasPrefix("container:") {
                let reference = String(value.dropFirst("container:".count))
                guard let target = await lookup.container(reference), target.owned(by: scope.key) else {
                    return "sharing the \(label) namespace of a container this workspace did not create is not allowed."
                }
                host[key] = "container:" + target.id
            } else if !["", "private", "shareable", "none"].contains(value) {
                return "the \(label) namespace mode “\(value)” is not allowed."
            }
        }
        if let cgroup = host["Cgroup"] as? String, !cgroup.isEmpty { return "joining another cgroup is not allowed." }
        if let runtime = host["Runtime"] as? String, !["", "runc", "io.containerd.runc.v2"].contains(runtime) {
            return "the runtime “\(runtime)” is not allowed."
        }
        if let log = host["LogConfig"] as? [String: Any], let type = log["Type"] as? String, !["", "json-file", "local", "none"].contains(type) {
            return "the log driver “\(type)” is not allowed."
        }
        // Network.
        let network = (host["NetworkMode"] as? String) ?? ""
        if let message = await networkUseCheck(network, scope: scope) { return message }
        if network.hasPrefix("container:"), let target = await lookup.container(String(network.dropFirst(10))) {
            host["NetworkMode"] = "container:" + target.id
        }
        // Published ports: loopback of the Mac only (Rancher Desktop forwards 0.0.0.0 to every interface).
        if truthy(host["PublishAllPorts"]) { return "publishing all ports (-P) is not allowed; publish ports explicitly (they are bound to 127.0.0.1)." }
        if var bindings = host["PortBindings"] as? [String: Any] {
            for (port, value) in bindings {
                var list = (value as? [[String: Any]]) ?? []
                for index in list.indices {
                    let ip = (list[index]["HostIp"] as? String) ?? ""
                    guard ["", "127.0.0.1", "localhost", "::1"].contains(ip) else {
                        return "publishing port \(port) on \(ip) is not allowed; ports are published on 127.0.0.1 only."
                    }
                    list[index]["HostIp"] = ip == "::1" ? "::1" : "127.0.0.1"
                }
                bindings[port] = list
            }
            host["PortBindings"] = bindings
        }
        // Mounts.
        var binds: [String] = []
        for bind in stringList(host["Binds"]) {
            switch await checkBind(bind, scope: scope) {
            case .failure(let refusal): return refusal.message
            case .success(let rewritten): binds.append(rewritten)
            }
        }
        if host["Binds"] != nil { host["Binds"] = binds }
        if let mounts = host["Mounts"] as? [[String: Any]] {
            var rewritten: [[String: Any]] = []
            for mount in mounts {
                switch await checkMount(mount, scope: scope) {
                case .failure(let refusal): return refusal.message
                case .success(let value): rewritten.append(value)
                }
            }
            host["Mounts"] = rewritten
        }
        var volumesFrom: [String] = []
        for entry in stringList(host["VolumesFrom"]) {
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            guard let target = await lookup.container(parts[0]), target.owned(by: scope.key) else {
                return "--volumes-from \(parts[0]): that container was not created through this workspace's endpoint."
            }
            volumesFrom.append(([target.id] + parts.dropFirst()).joined(separator: ":"))
        }
        if host["VolumesFrom"] != nil { host["VolumesFrom"] = volumesFrom }
        // Limits: the scope's at most, and by default.
        let limits = scope.limits
        let memory = (host["Memory"] as? NSNumber)?.int64Value ?? 0
        host["Memory"] = memory > 0 ? min(memory, limits.memoryBytes) : limits.memoryBytes
        let cpus = (host["NanoCpus"] as? NSNumber)?.int64Value ?? 0
        let maxCPUs = Int64(limits.cpus * 1_000_000_000)
        host["NanoCpus"] = cpus > 0 ? min(cpus, maxCPUs) : maxCPUs
        let pids = (host["PidsLimit"] as? NSNumber)?.int64Value ?? 0
        host["PidsLimit"] = pids > 0 ? min(pids, limits.pidsLimit) : limits.pidsLimit
        return nil
    }

    /// `src:dst[:opts]`: a host folder inside the scope's roots (rewritten to its canonical path) or a named volume this
    /// scope owns (created with its labels when missing).
    func checkBind(_ bind: String, scope: DockerScope) async -> Result<String, BindRefusal> {
        let parts = bind.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.count <= 3, !parts[0].isEmpty, !parts[1].isEmpty else {
            return .failure(BindRefusal("the volume “\(bind)” is not in a supported form (source:target[:options])."))
        }
        let options = parts.count == 3 ? parts[2].split(separator: ",").map(String.init) : []
        for option in options where !["ro", "rw", "z", "Z", "consistent", "cached", "delegated", "nocopy", "private", "rprivate"].contains(option) {
            return .failure(BindRefusal("the mount option “\(option)” is not allowed."))
        }
        if parts[0].hasPrefix("/") {
            switch checkHostPath(parts[0], scope: scope) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let canonical): return .success(([canonical] + parts.dropFirst()).joined(separator: ":"))
            }
        }
        if let message = await volumeUseCheck(parts[0], scope: scope) { return .failure(BindRefusal(message)) }
        return .success(bind)
    }

    func checkMount(_ mount: [String: Any], scope: DockerScope) async -> Result<[String: Any], BindRefusal> {
        var mount = mount
        let type = (mount["Type"] as? String) ?? "volume"
        let source = (mount["Source"] as? String) ?? ""
        switch type {
        case "bind":
            if let options = mount["BindOptions"] as? [String: Any] {
                let propagation = (options["Propagation"] as? String) ?? ""
                guard ["", "private", "rprivate"].contains(propagation) else {
                    return .failure(BindRefusal("bind propagation “\(propagation)” is not allowed."))
                }
            }
            switch checkHostPath(source, scope: scope) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let canonical): mount["Source"] = canonical
            }
        case "volume":
            if let options = mount["VolumeOptions"] as? [String: Any], !isEmpty(options["DriverConfig"]) {
                return .failure(BindRefusal("volume driver options are not allowed (they can mount host folders)."))
            }
            if !source.isEmpty, let message = await volumeUseCheck(source, scope: scope) { return .failure(BindRefusal(message)) }
        case "tmpfs":
            break
        default:
            return .failure(BindRefusal("mounts of type “\(type)” are not allowed."))
        }
        return .success(mount)
    }

    public struct BindRefusal: Error, Equatable, Sendable {
        public var message: String
        init(_ message: String) { self.message = message }
    }

    /// A host folder may be mounted when it is inside the scope's roots both as written and with links resolved.
    func checkHostPath(_ path: String, scope: DockerScope) -> Result<String, BindRefusal> {
        let lexical = (path as NSString).standardizingPath
        let resolved = canonical(lexical)
        let roots = scope.roots.map { (canonical($0), ($0 as NSString).standardizingPath) }
        let insideLexical = roots.contains { Self.inside(lexical, $0.1) || Self.inside(lexical, $0.0) }
        let insideResolved = roots.contains { Self.inside(resolved, $0.0) }
        guard insideLexical, insideResolved, !path.contains("/../"), !path.hasSuffix("/..") else {
            let allowed = scope.roots.joined(separator: ", ")
            return .failure(BindRefusal("mounting \(path) is not allowed: only folders inside \(allowed) can be mounted\(insideLexical ? " (that path leads outside them through a link)" : ""). Use a path in the project, or a named volume."))
        }
        return .success(resolved)
    }

    func volumeUseCheck(_ name: String, scope: DockerScope) async -> String? {
        if name.hasPrefix(DockerAgentLabels.reservedNamePrefix) { return "the volume \(name) belongs to BelloCode." }
        if let volume = await lookup.volume(name) {
            return volume.owned(by: scope.key) ? nil : "the volume \(name) was not created through this workspace's endpoint."
        }
        // `docker run -v name:/x` would let the daemon create it unlabelled: create it with the scope's labels first.
        do {
            try await lookup.createVolume(name: name, labels: DockerAgentLabels.labels(scope.key))
            return nil
        } catch {
            return "the volume \(name) could not be created (\(error))."
        }
    }

    func networkUseCheck(_ name: String, scope: DockerScope) async -> String? {
        switch name {
        case "", "default", "bridge", "none": return nil
        case "host": return "the host network (--network host) is not allowed."
        default:
            if name.hasPrefix("container:") {
                guard let target = await lookup.container(String(name.dropFirst(10))), target.owned(by: scope.key) else {
                    return "joining the network of a container this workspace did not create is not allowed."
                }
                return nil
            }
            guard let network = await lookup.network(name), network.owned(by: scope.key) else {
                return "the network \(name) was not created through this workspace's endpoint."
            }
            return nil
        }
    }

    /// May the scope run `image`? Its own builds always; anything else under the image policy.
    func imageCheck(_ image: String, scope: DockerScope) async -> String? {
        if let existing = await lookup.image(image), existing.owned(by: scope.key) { return nil }
        return imageRefusal(image)
    }

    // MARK: Images and builds

    func images(_ request: DockerAPIRequest, segments: [String], scope: DockerScope) async -> DockerDecision {
        let plain = DockerDecision.forward(request, streamBody: false, hijack: false, after: nil)
        // DELETE /images/{name}: the name may itself contain slashes.
        if request.method == "DELETE", segments.count >= 2 {
            let full = segments.dropFirst().joined(separator: "/")
            guard let image = await lookup.image(full) else { return .refuse(status: 404, message: "No such image: \(full)") }
            guard owns(image, scope: scope) else {
                return Self.refuse("only images this workspace built or pulled can be removed; \(full) is not one of them.")
            }
            return plain
        }
        if segments.count == 2 {
            switch (request.method, segments[1]) {
            case ("GET", "json"): return plain
            case ("POST", "create"):
                if request.value("fromSrc") != nil { return Self.refuse("importing an image from a file or URL is not allowed.") }
                guard var reference = request.value("fromImage"), !reference.isEmpty else { return Self.refuse("no image to pull was named.", status: 400) }
                if let tag = request.value("tag"), !tag.isEmpty, !reference.contains("@") {
                    reference += (tag.hasPrefix("sha256:") ? "@" : ":") + tag
                }
                if let refusal = imageRefusal(reference) { return Self.refuse(refusal) }
                return .forward(request, streamBody: false, hijack: false, after: .pulled(reference))
            default:
                return Self.refuse("\(request.method) /images/\(segments[1]) (load, save, prune, search) is not allowed.")
            }
        }
        guard segments.count >= 3 else { return unknown(request) }
        let name = segments.dropFirst().dropLast().joined(separator: "/")
        let action = segments.last ?? ""
        switch (request.method, action) {
        case ("GET", "json"), ("GET", "history"):
            return plain
        case ("POST", "tag"):
            guard let image = await lookup.image(name), owns(image, scope: scope) else {
                return Self.refuse("only images this workspace built or pulled can be tagged.")
            }
            let repo = request.value("repo") ?? ""
            let target = repo + ((request.value("tag") ?? "").isEmpty ? "" : ":" + (request.value("tag") ?? ""))
            if let existing = await lookup.image(target), !owns(existing, scope: scope) {
                return Self.refuse("the tag \(target) already names an image this workspace did not create; choose another tag.")
            }
            return plain
        case ("POST", "push"):
            return Self.refuse("pushing images is not allowed from the workspace.")
        default:
            break
        }
        // DELETE /images/{name}: the name may itself contain slashes.
        if request.method == "DELETE" {
            let full = segments.dropFirst().joined(separator: "/")
            guard let image = await lookup.image(full) else { return .refuse(status: 404, message: "No such image: \(full)") }
            guard owns(image, scope: scope) else {
                return Self.refuse("only images this workspace built or pulled can be removed; \(full) is not one of them.")
            }
            return plain
        }
        return unknown(request)
    }

    func owns(_ image: DockerObject, scope: DockerScope) -> Bool {
        image.owned(by: scope.key) || pulledBy(scope.key).contains(image.id) || pulledBy(scope.key).contains(image.name)
    }

    func build(_ request: DockerAPIRequest, segments: [String], scope: DockerScope) async -> DockerDecision {
        if segments.count == 2, segments[1] == "prune" { return Self.refuse("pruning the build cache is not allowed.") }
        guard segments.count == 1 else { return unknown(request) }
        if let remote = request.value("remote"), !remote.isEmpty {
            return Self.refuse("building from a remote context (\(remote)) is not allowed; build from a folder in the project.")
        }
        let network = request.value("networkmode") ?? ""
        guard ["", "default", "bridge", "none"].contains(network) else {
            return Self.refuse("builds may use the default network or none, not “\(network)”.")
        }
        for name in ["cgroupparent", "outputs", "isolation"] where !(request.value(name) ?? "").isEmpty {
            return Self.refuse("the build option \(name) is not allowed.")
        }
        if let extra = request.value("securityopt"), !extra.isEmpty { return Self.refuse("build security options are not allowed.") }
        for tag in request.values("t") {
            if let existing = await lookup.image(tag), !owns(existing, scope: scope) {
                return Self.refuse("the tag \(tag) already names an image this workspace did not create; choose another tag.")
            }
        }
        var rewritten = request
        let existing = (request.value("labels").flatMap { $0.data(using: .utf8) }).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        switch labelsWithScope(existing, scope: scope) {
        case .failure(let refusal): return Self.refuse(refusal.message)
        case .success(let labels):
            rewritten.query.removeAll { $0.0 == "labels" }
            let data = (try? JSONSerialization.data(withJSONObject: labels, options: [.sortedKeys])) ?? Data("{}".utf8)
            rewritten.query.append(("labels", String(decoding: data, as: UTF8.self)))
        }
        // Memory and CPU of build steps: within the scope's limits.
        let memory = Int64(request.value("memory") ?? "") ?? 0
        rewritten.query.removeAll { $0.0 == "memory" }
        rewritten.query.append(("memory", String(memory > 0 ? min(memory, scope.limits.memoryBytes) : scope.limits.memoryBytes)))
        // Enforced egress (R14): `RUN` steps get the scope's egress network (its only way out is BelloCode's proxy) and
        // the proxy as Docker's predefined build arguments (kept out of the image history), never the bridge.
        if let egress = scope.egress, network != "none" {
            rewritten.query.removeAll { $0.0 == "networkmode" }
            rewritten.query.append(("networkmode", egress.network))
            var arguments = Self.buildArguments(request)
            for (name, value) in egress.environment where Self.predefinedProxyArguments.contains(name) && arguments[name] == nil {
                arguments[name] = value
            }
            if !arguments.isEmpty {
                let data = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])) ?? Data("{}".utf8)
                rewritten.query.removeAll { $0.0 == "buildargs" }
                rewritten.query.append(("buildargs", String(decoding: data, as: UTF8.self)))
            }
        }
        return .forward(rewritten, streamBody: true, hijack: false, after: nil)
    }

    /// Docker's predefined proxy build arguments (not recorded in the image history).
    static let predefinedProxyArguments: Set<String> = [
        "HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "FTP_PROXY", "ftp_proxy", "NO_PROXY", "no_proxy", "ALL_PROXY", "all_proxy",
    ]

    /// The request's `buildargs` (a JSON object; null values dropped).
    static func buildArguments(_ request: DockerAPIRequest) -> [String: String] {
        guard let text = request.value("buildargs"), let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return object.compactMapValues { $0 as? String }
    }

    /// R14: the images a classic build's Dockerfile pulls (`FROM`, `COPY --from`, `RUN --mount=from=`) are under the
    /// image policy like any pull, unless the scope built them itself. Called by the proxy once it found the Dockerfile
    /// in the streamed context, before the context is completed (so nothing is built when it refuses).
    public func buildBaseRefusal(dockerfile: Data, request: DockerAPIRequest, scope: DockerScope) async -> String? {
        switch DockerfileBases.images(in: String(decoding: dockerfile, as: UTF8.self), buildArgs: Self.buildArguments(request)) {
        case .failure(let refusal):
            return Self.prefix + refusal.reason + "."
        case .success(let images):
            for image in images {
                if let existing = await lookup.image(image), owns(existing, scope: scope) { continue }
                if let refusal = imageRefusal(image) { return Self.prefix + "the Dockerfile's base image \(image) is not allowed: \(refusal)" }
            }
            return nil
        }
    }

    // MARK: Networks and volumes

    func networks(_ request: DockerAPIRequest, segments: [String], scope: DockerScope) async -> DockerDecision {
        if segments.count == 1 {
            return request.method == "GET" ? withScopeFilter(request, scope: scope) : unknown(request)
        }
        if segments.count == 2, segments[1] == "create", request.method == "POST" {
            guard let body = request.body, var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                return Self.refuse("the network request has no valid JSON body.", status: 400)
            }
            let name = (object["Name"] as? String) ?? ""
            if name.hasPrefix(DockerAgentLabels.reservedNamePrefix) { return Self.refuse("names starting with “bellocode-” are reserved for BelloCode.") }
            let driver = (object["Driver"] as? String) ?? ""
            guard ["", "bridge"].contains(driver) else { return Self.refuse("only bridge networks are allowed, not “\(driver)”.") }
            for key in ["ConfigFrom", "ConfigOnly", "Ingress", "Attachable", "Scope"] where truthy(object[key]) || ((object[key] as? String).map { !$0.isEmpty && $0 != "local" } ?? false) {
                return Self.refuse("the network setting \(key) is not allowed.")
            }
            if let options = object["Options"] as? [String: Any], !options.isEmpty {
                let allowed: Set<String> = ["com.docker.network.driver.mtu", "com.docker.network.bridge.enable_icc"]
                if let key = options.keys.first(where: { !allowed.contains($0) }) { return Self.refuse("the network option \(key) is not allowed.") }
            }
            switch labelsWithScope(object["Labels"], scope: scope) {
            case .failure(let refusal): return Self.refuse(refusal.message)
            case .success(let labels): object["Labels"] = labels
            }
            if scope.egress != nil {
                // No way out except the scope's egress network (which its containers also join).
                object["Internal"] = true
                object["EnableIPv6"] = false
            }
            var rewritten = request
            rewritten.body = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return .forward(rewritten, streamBody: false, hijack: false, after: nil)
        }
        if segments.count == 2, segments[1] == "prune" { return withScopeFilter(request, scope: scope) }
        guard let network = await lookup.network(segments[1]) else { return .refuse(status: 404, message: "network \(segments[1]) not found") }
        let builtIn = ["bridge", "none", "host"].contains(network.name)
        var pinned = request
        pinned.path = "/networks/\(network.id)" + (segments.count > 2 ? "/" + segments.dropFirst(2).joined(separator: "/") : "")
        if segments.count == 2, request.method == "GET", builtIn || network.owned(by: scope.key) {
            return .forward(pinned, streamBody: false, hijack: false, after: nil)
        }
        guard network.owned(by: scope.key) else { return Self.refuse("the network \(network.name) was not created through this workspace's endpoint.") }
        if segments.count == 2, request.method == "DELETE" { return .forward(pinned, streamBody: false, hijack: false, after: nil) }
        if segments.count == 3, request.method == "POST", ["connect", "disconnect"].contains(segments[2]) {
            guard let body = request.body, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let reference = object["Container"] as? String else { return Self.refuse("no container was named.", status: 400) }
            guard let container = await lookup.container(reference), container.owned(by: scope.key) else {
                return Self.refuse("only containers this workspace created can be connected to its networks.")
            }
            if let egress = scope.egress, network.name == egress.network {
                return Self.refuse("containers stay on BelloCode's egress network.")
            }
            return .forward(pinned, streamBody: false, hijack: false, after: nil)
        }
        return unknown(request)
    }

    func volumes(_ request: DockerAPIRequest, segments: [String], scope: DockerScope) async -> DockerDecision {
        if segments.count == 1 {
            return request.method == "GET" ? withScopeFilter(request, scope: scope) : unknown(request)
        }
        if segments.count == 2, segments[1] == "create", request.method == "POST" {
            guard let body = request.body, var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                return Self.refuse("the volume request has no valid JSON body.", status: 400)
            }
            let name = (object["Name"] as? String) ?? ""
            if name.hasPrefix(DockerAgentLabels.reservedNamePrefix) { return Self.refuse("names starting with “bellocode-” are reserved for BelloCode.") }
            let driver = (object["Driver"] as? String) ?? ""
            guard ["", "local"].contains(driver) else { return Self.refuse("only local volumes are allowed, not “\(driver)”.") }
            if !isEmpty(object["DriverOpts"]) { return Self.refuse("volume driver options are not allowed (they can mount host folders or devices).") }
            if !isEmpty(object["ClusterVolumeSpec"]) { return Self.refuse("cluster volumes are not allowed.") }
            switch labelsWithScope(object["Labels"], scope: scope) {
            case .failure(let refusal): return Self.refuse(refusal.message)
            case .success(let labels): object["Labels"] = labels
            }
            var rewritten = request
            rewritten.body = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return .forward(rewritten, streamBody: false, hijack: false, after: nil)
        }
        if segments.count == 2, segments[1] == "prune" { return withScopeFilter(request, scope: scope) }
        guard segments.count == 2, ["GET", "DELETE"].contains(request.method) else { return unknown(request) }
        guard let volume = await lookup.volume(segments[1]) else { return .refuse(status: 404, message: "get \(segments[1]): no such volume") }
        guard volume.owned(by: scope.key) else { return Self.refuse("the volume \(segments[1]) was not created through this workspace's endpoint.") }
        return .forward(request, streamBody: false, hijack: false, after: nil)
    }

    // MARK: Helpers

    /// Adds `label=app.bellocode.agent-scope=<key>` to the request's `filters` (lists, events and prunes see only the
    /// scope's own objects).
    func withScopeFilter(_ request: DockerAPIRequest, scope: DockerScope) -> DockerDecision {
        var filters: [String: Any] = [:]
        if let raw = request.value("filters"), !raw.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
                return Self.refuse("the filters parameter is not valid JSON.", status: 400)
            }
            filters = parsed
        }
        var labels: [String] = []
        switch filters["label"] {
        case let list as [String]: labels = list
        case let map as [String: Any]: labels = map.filter { truthy($0.value) }.map(\.key)
        default: break
        }
        labels.append("\(DockerAgentLabels.scope)=\(scope.key)")
        filters["label"] = labels.sorted()
        var rewritten = request
        rewritten.query.removeAll { $0.0 == "filters" }
        let data = (try? JSONSerialization.data(withJSONObject: filters, options: [.sortedKeys])) ?? Data()
        rewritten.query.append(("filters", String(decoding: data, as: UTF8.self)))
        return .forward(rewritten, streamBody: false, hijack: false, after: nil)
    }

    /// The request's labels plus the scope's; refuses any `app.bellocode.` label.
    func labelsWithScope(_ value: Any?, scope: DockerScope) -> Result<[String: String], LabelRefusal> {
        var labels: [String: String] = [:]
        if let map = value as? [String: Any] {
            for (key, value) in map {
                if key.hasPrefix(DockerAgentLabels.reservedPrefix) {
                    return .failure(LabelRefusal("labels starting with “app.bellocode.” are reserved for BelloCode (\(key))."))
                }
                labels[key] = (value as? String) ?? "\(value)"
            }
        } else if value != nil, !(value is NSNull) {
            return .failure(LabelRefusal("labels must be a JSON object."))
        }
        return .success(labels.merging(DockerAgentLabels.labels(scope.key)) { _, ours in ours })
    }

    public struct LabelRefusal: Error, Equatable, Sendable {
        public var message: String
        init(_ message: String) { self.message = message }
    }

    func truthy(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool: bool
        case let number as NSNumber: number.boolValue
        case let string as String: ["1", "true", "yes"].contains(string.lowercased())
        default: false
        }
    }

    func isEmpty(_ value: Any?) -> Bool {
        switch value {
        case nil: true
        case is NSNull: true
        case let string as String: string.isEmpty
        case let list as [Any]: list.isEmpty
        case let map as [String: Any]: map.isEmpty
        case let number as NSNumber: number == 0 || number == false as NSNumber
        default: false
        }
    }

    func stringList(_ value: Any?) -> [String] { (value as? [Any])?.compactMap { $0 as? String } ?? [] }

    static func inside(_ path: String, _ root: String) -> Bool {
        let root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// Resolves links in the longest existing prefix of `path`; the rest is appended unchanged.
    public static func resolveExistingPrefix(_ path: String) -> String {
        var prefix = (path as NSString).standardizingPath
        var rest: [String] = []
        while prefix != "/" && !prefix.isEmpty {
            if let resolved = realpath(prefix, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return rest.isEmpty ? base : (base as NSString).appendingPathComponent(rest.reversed().joined(separator: "/"))
            }
            rest.append((prefix as NSString).lastPathComponent)
            prefix = (prefix as NSString).deletingLastPathComponent
        }
        return path
    }
}

extension DockerFilterPolicy.BindRefusal: CustomStringConvertible { public var description: String { message } }
extension DockerFilterPolicy.LabelRefusal: CustomStringConvertible { public var description: String { message } }
