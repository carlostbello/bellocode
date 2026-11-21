import Foundation
import Synchronization
import Testing

@testable import ContainerKit

/// A small stateful Docker daemon for the egress gateway: images by ID and tag, networks, containers with their
/// networks and logs. Bridge attachments can be made to fail; relays can be made never to report ready.
final class GatewayDaemon: Sendable {
    struct Container: Sendable {
        var id: String
        var image: String
        var labels: [String: String]
        var running: Bool
        var networks: Set<String>
        var logs: String
    }

    struct State: Sendable {
        var images: [String: [String: String]] = [:]  // id → labels
        var tags: [String: String] = [:]  // tag → id
        var containers: [String: Container] = [:]  // name → container
        var networks: [String: [String: String]] = [:]  // name → labels
        var bridgeFailures = 0
        var relayReady = true
        var builds = 0
        var creates: [String] = []  // the image of each create
    }

    static let built = "sha256:" + String(repeating: "a", count: 64)
    static let foreign = "sha256:" + String(repeating: "e", count: 64)

    let state = Mutex(State())
    private let serverBox = Mutex<FakeEngineServer?>(nil)

    init() throws {
        let server = try FakeEngineServer { [weak self] request, stream in
            guard let self else { return }
            try await self.handle(request, stream)
        }
        serverBox.withLock { $0 = server }
    }

    var client: EngineClient { serverBox.withLock { $0! }.client }
    func stop() { serverBox.withLock { $0?.stop() } }

    private func container(named key: String, in state: State) -> (String, Container)? {
        if let found = state.containers[key] { return (key, found) }
        return state.containers.first { $0.value.id == key }.map { ($0.key, $0.value) }
    }

    private func json(_ object: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
    }

    func handle(_ request: FakeEngineServer.Request, _ stream: FileStream) async throws {
        let path = request.path.removingPercentEncoding ?? request.path
        let parts = path.split(separator: "/").map(String.init).drop { $0.hasPrefix("v1.") }
        let segments = Array(parts)
        switch (request.method, segments.first, segments.count) {
        case ("GET", "networks", 2):
            let name = segments[1]
            if let labels = state.withLock({ $0.networks[name] }) {
                try await stream.respond(200, json: json(["Id": "net-" + name, "Name": name, "Internal": true, "Labels": labels]))
            } else {
                try await stream.respond(404, json: #"{"message":"no such network"}"#)
            }
        case ("POST", "networks", 2) where segments[1] == "create":
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let name = body["Name"] as? String ?? ""
            state.withLock { $0.networks[name] = body["Labels"] as? [String: String] ?? [:] }
            try await stream.respond(201, json: json(["Id": "net-" + name]))
        case ("POST", "networks", 3) where segments[2] == "connect":
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let target = body["Container"] as? String ?? ""
            let network = segments[1]
            let ok = state.withLock { state -> Bool in
                if network == "bridge", state.bridgeFailures > 0 { state.bridgeFailures -= 1; return false }
                guard let (name, _) = container(named: target, in: state) else { return false }
                state.containers[name]?.networks.insert(network)
                return true
            }
            if ok { try await stream.respond(200, json: "{}") } else { try await stream.respond(500, json: #"{"message":"injected failure"}"#) }
        case ("GET", "images", _) where segments.last == "json":
            let reference = segments.dropFirst().dropLast().joined(separator: "/")
            let found = state.withLock { state -> (String, [String: String])? in
                let id = state.images[reference] != nil ? reference : state.tags[reference]
                return id.flatMap { id in state.images[id].map { (id, $0) } }
            }
            if let (id, labels) = found {
                try await stream.respond(200, json: json(["Id": id, "Config": ["Labels": labels]]))
            } else {
                try await stream.respond(404, json: #"{"message":"no such image"}"#)
            }
        case ("POST", "build", _):
            let query = URLComponents(string: "http://x" + request.target)?.queryItems ?? []
            let tag = query.first { $0.name == "t" }?.value ?? ""
            let labels = (query.first { $0.name == "labels" }?.value?.data(using: .utf8))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
            state.withLock { state in
                state.builds += 1
                state.images[Self.built] = labels
                state.tags[tag] = Self.built
            }
            let lines = json(["stream": "Step 1/4\n"]) + "\n" + json(["aux": ["ID": Self.built]]) + "\n"
            try await stream.respondChunked(200, chunks: [Data(lines.utf8)])
        case ("POST", "containers", 2) where segments[1] == "create":
            let name = URLComponents(string: "http://x" + request.target)?.queryItems?.first { $0.name == "name" }?.value ?? ""
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let image = body["Image"] as? String ?? ""
            let network = (body["HostConfig"] as? [String: Any])?["NetworkMode"] as? String ?? "default"
            let id = "ctr-" + UUID().uuidString.prefix(8)
            let rejected = state.withLock { state -> Bool in
                if state.containers[name] != nil { return true }
                state.creates.append(image)
                state.containers[name] = Container(id: String(id), image: image, labels: body["Labels"] as? [String: String] ?? [:],
                                                   running: false, networks: [network], logs: "")
                return false
            }
            if rejected { try await stream.respond(409, json: #"{"message":"conflict"}"#) } else { try await stream.respond(201, json: json(["Id": id])) }
        case ("POST", "containers", 3) where segments[2] == "start":
            state.withLock { state in
                guard let (name, _) = container(named: segments[1], in: state) else { return }
                state.containers[name]?.running = true
                if state.relayReady { state.containers[name]?.logs = "bellocode-relay ready 10.0.0.2\n" }
            }
            try await stream.respond(204)
        case ("GET", "containers", 3) where segments[2] == "json":
            guard let (name, found) = state.withLock({ container(named: segments[1], in: $0) }) else {
                try await stream.respond(404, json: #"{"message":"no such container"}"#)
                return
            }
            let networks = Dictionary(uniqueKeysWithValues: found.networks.map { ($0, [String: String]()) })
            try await stream.respond(200, json: json([
                "Id": found.id, "Name": "/" + name, "Image": found.image,
                "State": ["Status": found.running ? "running" : "created", "Running": found.running],
                "Config": ["Labels": found.labels, "Image": found.image], "NetworkSettings": ["Networks": networks],
            ]))
        case ("GET", "containers", 3) where segments[2] == "logs":
            let text = state.withLock { state in container(named: segments[1], in: state)?.1.logs ?? "" }
            let payload = Data(text.utf8)
            var frame = Data([1, 0, 0, 0])
            withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
            try await stream.respondChunked(200, chunks: payload.isEmpty ? [] : [frame + payload])
        case ("DELETE", "containers", 2):
            state.withLock { state in
                if let (name, _) = container(named: segments[1], in: state) { state.containers[name] = nil }
            }
            try await stream.respond(204)
        default:
            try await stream.respond(404, json: #"{"message":"unexpected \#(request.method) \#(path)"}"#)
        }
    }
}

/// v1.0.0 review A07, A21 and N19 (1): the gateway runs the image ID this launch built (never a tag someone else can
/// point elsewhere), and a running gateway is reused only when the setup that made it usable still holds.
@Suite("Egress gateway lifecycle", .serialized, .timeLimit(.minutes(2)))
struct EgressGatewayLifecycleTests {
    static func spec() -> EgressGatewaySpec { EgressGatewaySpec(scopeKey: "p1234", proxyPort: 49_152, token: "tok-1") }

    @Test func aForeignImageUnderTheTagIsNeverRun() async throws {
        let daemon = try GatewayDaemon()
        defer { daemon.stop() }
        // Someone else's image already sits under BelloCode's tag, with the inputs label BelloCode would write.
        daemon.state.withLock { state in
            state.images[GatewayDaemon.foreign] = [EgressGatewayImage.labelInputs: EgressGatewayImage.inputHash]
            state.tags[EgressGatewayImage.tag] = GatewayDaemon.foreign
        }
        try await EgressGateway(client: daemon.client).ensure(Self.spec())
        let creates = daemon.state.withLock { $0.creates }
        #expect(creates == [GatewayDaemon.built], "the gateway must be created by the ID BelloCode built: \(creates)")
        #expect(daemon.state.withLock { $0.builds } == 1)
    }

    @Test func aRunningGatewayOnAnotherImageIsReplaced() async throws {
        let daemon = try GatewayDaemon()
        defer { daemon.stop() }
        let spec = Self.spec()
        let labels = EgressGateway.createBody(spec).labels ?? [:]
        daemon.state.withLock { state in
            state.networks[spec.networkName] = EgressGateway.ownership(spec.scopeKey)
            state.containers[spec.containerName] = .init(id: "ctr-old", image: GatewayDaemon.foreign, labels: labels, running: true,
                                                        networks: [spec.networkName, "bridge"], logs: "bellocode-relay ready 10.0.0.2\n")
        }
        try await EgressGateway(client: daemon.client).ensure(spec)
        let running = try #require(daemon.state.withLock { $0.containers[spec.containerName] })
        #expect(running.image == GatewayDaemon.built, "a matching label on another image is not a trusted gateway")
        #expect(running.id != "ctr-old")
    }

    @Test func aRetryAfterTheBridgeStepFailedLeavesAUsableGateway() async throws {
        let daemon = try GatewayDaemon()
        defer { daemon.stop() }
        let spec = Self.spec()
        daemon.state.withLock { $0.bridgeFailures = 1 }
        await #expect(throws: (any Error).self) { try await EgressGateway(client: daemon.client).ensure(spec) }
        try await EgressGateway(client: daemon.client).ensure(spec)
        let gateway = try #require(daemon.state.withLock { $0.containers[spec.containerName] })
        #expect(gateway.running && gateway.networks.contains("bridge"), "reported ready but has no way out: \(gateway.networks)")
        #expect(gateway.networks.contains(spec.networkName))
    }

    @Test func aReusedGatewayMissingTheBridgeIsRepairedInPlace() async throws {
        let daemon = try GatewayDaemon()
        defer { daemon.stop() }
        let spec = Self.spec()
        try await EgressGateway(client: daemon.client).ensure(spec)
        let first = try #require(daemon.state.withLock { $0.containers[spec.containerName] })
        // The bridge attachment is lost (a daemon restart, a manual disconnect, or a setup that failed at that step).
        daemon.state.withLock { $0.containers[spec.containerName]?.networks.remove("bridge") }
        try await EgressGateway(client: daemon.client).ensure(spec)
        let second = try #require(daemon.state.withLock { $0.containers[spec.containerName] })
        #expect(second.id == first.id, "repaired, not recreated")
        #expect(second.networks.contains("bridge"))
    }

    @Test func aGatewayWhoseRelayNeverReportedReadyIsRecreated() async throws {
        let daemon = try GatewayDaemon()
        defer { daemon.stop() }
        let spec = Self.spec()
        try await EgressGateway(client: daemon.client).ensure(spec)
        let first = try #require(daemon.state.withLock { $0.containers[spec.containerName] })
        daemon.state.withLock { $0.containers[spec.containerName]?.logs = "" }
        try await EgressGateway(client: daemon.client).ensure(spec)
        let second = try #require(daemon.state.withLock { $0.containers[spec.containerName] })
        #expect(second.id != first.id, "an unready relay is not reused")
        #expect(second.logs.contains("ready") && second.networks.contains("bridge"))
    }

    @Test func aFailedFirstSetupLeavesNoRunningGateway() async throws {
        let daemon = try GatewayDaemon()
        defer { daemon.stop() }
        let spec = Self.spec()
        daemon.state.withLock { $0.bridgeFailures = 1 }
        await #expect(throws: (any Error).self) { try await EgressGateway(client: daemon.client).ensure(spec) }
        #expect(daemon.state.withLock { $0.containers[spec.containerName] } == nil, "the half-set-up gateway was removed")
    }
}
