import Foundation
import Synchronization
import Testing

@testable import ContainerKit

/// Service lifecycle against a stateful fake daemon: dependency order, healthcheck gating, recreate on change, orphans.
@Suite("Service manager", .timeLimit(.minutes(3)))
struct ServiceManagerTests {
    /// A tiny Docker daemon: containers with labels and state; a service's health turns `final` after `healthAfter`
    /// inspections once started.
    final class Daemon: Sendable {
        struct Box: Sendable {
            var id: String
            var name: String
            var labels: [String: String]
            var running = false
            var inspections = 0
        }
        let containers = Mutex<[String: Box]>([:])
        let events = Mutex<[String]>([])
        let health: [String: (after: Int, final: String)]
        let counter = Mutex(0)

        init(health: [String: (after: Int, final: String)]) { self.health = health }

        func handle(_ request: FakeEngineServer.Request, _ stream: FileStream) async throws {
            let path = request.path.replacingOccurrences(of: #"^/v[0-9.]+"#, with: "", options: .regularExpression)
            switch (request.method, path) {
            case ("GET", let p) where p.hasPrefix("/images/"):
                try await stream.respond(200, json: #"{"Id":"sha256:img"}"#)
            case ("POST", "/volumes/create"):
                try await stream.respond(201, json: "{}")
            case ("GET", "/containers/json"):
                let filters = Self.labelFilters(request.target)
                let rows = containers.withLock { boxes in
                    boxes.values.filter { box in filters.allSatisfy { filter in
                        let parts = filter.split(separator: "=", maxSplits: 1).map(String.init)
                        return parts.count == 1 ? box.labels[parts[0]] != nil : box.labels[parts[0]] == parts[1]
                    } }
                }
                let json = rows.map { box in
                    let labels = (try? String(decoding: JSONSerialization.data(withJSONObject: box.labels), as: UTF8.self)) ?? "{}"
                    return #"{"Id":"\#(box.id)","Names":["/\#(box.name)"],"Image":"img","State":"\#(box.running ? "running" : "created")","Labels":\#(labels)}"#
                }
                try await stream.respond(200, json: "[" + json.joined(separator: ",") + "]")
            case ("POST", "/containers/create"):
                let name = URLComponents(string: request.target)?.queryItems?.first { $0.name == "name" }?.value ?? "?"
                let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
                let labels = body?["Labels"] as? [String: String] ?? [:]
                let id = "c" + String(counter.withLock { $0 += 1; return $0 })
                containers.withLock { $0[id] = Box(id: id, name: name, labels: labels) }
                events.withLock { $0.append("create \(labels[ServiceLabels.service] ?? name)") }
                try await stream.respond(201, json: #"{"Id":"\#(id)"}"#)
            case ("POST", let p) where p.hasSuffix("/start"):
                let id = p.split(separator: "/")[1]
                let service = containers.withLock { boxes -> String in
                    boxes[String(id)]?.running = true
                    return boxes[String(id)]?.labels[ServiceLabels.service] ?? "?"
                }
                events.withLock { $0.append("start \(service)") }
                try await stream.respond(204)
            case ("DELETE", let p) where p.hasPrefix("/containers/"):
                let id = String(p.split(separator: "/")[1])
                let service = containers.withLock { $0.removeValue(forKey: id)?.labels[ServiceLabels.service] ?? "?" }
                events.withLock { $0.append("remove \(service)") }
                try await stream.respond(204)
            case ("GET", let p) where p.hasPrefix("/containers/") && p.hasSuffix("/json"):
                let id = String(p.split(separator: "/")[1])
                guard let box = containers.withLock({ boxes -> Box? in
                    boxes[id]?.inspections += 1
                    return boxes[id]
                }) else { return try await stream.respond(404, json: #"{"message":"no such container"}"#) }
                let service = box.labels[ServiceLabels.service] ?? ""
                var healthJSON = ""
                if let rule = health[service], box.running {
                    let status = box.inspections >= rule.after ? rule.final : "starting"
                    if box.inspections == rule.after { events.withLock { $0.append("\(status) \(service)") } }
                    healthJSON = #","Health":{"Status":"\#(status)"}"#
                }
                let labels = (try? String(decoding: JSONSerialization.data(withJSONObject: box.labels), as: UTF8.self)) ?? "{}"
                try await stream.respond(200, json: #"{"Id":"\#(box.id)","Name":"/\#(box.name)","Image":"sha256:img","State":{"Status":"\#(box.running ? "running" : "created")","Running":\#(box.running),"ExitCode":0\#(healthJSON)},"Config":{"Labels":\#(labels)}}"#)
            default:
                try await stream.respond(404, json: #"{"message":"unexpected \#(request.method) \#(path)"}"#)
            }
        }

        static func labelFilters(_ target: String) -> [String] {
            guard let raw = URLComponents(string: target)?.queryItems?.first(where: { $0.name == "filters" })?.value,
                  let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: [String]] else { return [] }
            return object["label"] ?? []
        }
    }

    func specs(_ definitions: [ServiceDefinition]) -> [ServiceSpec] {
        definitions.map { ServiceSpec(projectRoot: "/Users/t/p", definition: $0, network: "bellocode-net-k") }
    }

    let projectKey = WorkspaceSpec.projectKey(for: "/Users/t/p")

    @Test func dependantsWaitUntilTheirDependencyIsHealthy() async throws {
        let daemon = Daemon(health: ["db": (after: 3, final: "healthy")])
        let server = try FakeEngineServer { try await daemon.handle($0, $1) }
        defer { server.stop() }
        var manager = ServiceManager(client: server.client)
        manager.pollInterval = .milliseconds(5)
        let services = specs([
            ServiceDefinition(name: "app", image: "node", dependsOn: [.init(service: "db", condition: .healthy)]),
            ServiceDefinition(name: "db", image: "postgres", healthcheck: .init(test: ["CMD", "true"], intervalSeconds: 1, retries: 2)),
            ServiceDefinition(name: "logger", image: "busybox", dependsOn: [.init(service: "db")]),
        ])
        let outcomes = try await manager.ensure(services, projectKey: projectKey)
        #expect(outcomes == ["db": .running, "app": .running, "logger": .running])
        let events = daemon.events.withLock { $0 }
        let healthy = try #require(events.firstIndex(of: "healthy db"))
        let appCreated = try #require(events.firstIndex(of: "create app"))
        #expect(events.firstIndex(of: "start db")! < healthy && healthy < appCreated, "app is created only once db is healthy: \(events)")
        #expect(events.firstIndex(of: "start db")! < events.firstIndex(of: "create logger")!, "service_started waits for the start only")
    }

    @Test func anUnhealthyDependencyBlocksItsDependants() async throws {
        let daemon = Daemon(health: ["db": (after: 2, final: "unhealthy")])
        let server = try FakeEngineServer { try await daemon.handle($0, $1) }
        defer { server.stop() }
        var manager = ServiceManager(client: server.client)
        manager.pollInterval = .milliseconds(5)
        let outcomes = try await manager.ensure(specs([
            ServiceDefinition(name: "db", image: "postgres", healthcheck: .init(test: ["CMD", "false"])),
            ServiceDefinition(name: "app", image: "node", dependsOn: [.init(service: "db", condition: .healthy)]),
            ServiceDefinition(name: "web", image: "node", dependsOn: [.init(service: "app")]),
        ]), projectKey: projectKey)
        #expect(outcomes["db"] == .running)
        #expect(outcomes["app"] == .blocked("db is unhealthy"))
        #expect(outcomes["web"] == .blocked("waiting for app, which did not start"))
        #expect(!daemon.events.withLock { $0 }.contains("create app"), "nothing is started past a failed gate")
    }

    @Test func healthGateWithoutAHealthcheckSaysSo() async throws {
        let daemon = Daemon(health: [:])
        let server = try FakeEngineServer { try await daemon.handle($0, $1) }
        defer { server.stop() }
        let outcomes = try await ServiceManager(client: server.client).ensure(specs([
            ServiceDefinition(name: "db", image: "postgres"),
            ServiceDefinition(name: "app", image: "node", dependsOn: [.init(service: "db", condition: .healthy)]),
        ]), projectKey: projectKey)
        if case .blocked(let message)? = outcomes["app"] { #expect(message.contains("no healthcheck")) } else { Issue.record("\(outcomes)") }
    }

    @Test func changesRecreateAndRemovedServicesGoWithoutTheirVolumes() async throws {
        let daemon = Daemon(health: [:])
        let server = try FakeEngineServer { try await daemon.handle($0, $1) }
        defer { server.stop() }
        let manager = ServiceManager(client: server.client)
        let first = specs([ServiceDefinition(name: "cache", image: "redis"), ServiceDefinition(name: "old", image: "redis")])
        _ = try await manager.ensure(first, projectKey: projectKey)
        daemon.events.withLock { $0.removeAll() }
        // Same definition: nothing recreated. Changed definition: recreated. `old` dropped: removed.
        var changed = specs([ServiceDefinition(name: "cache", image: "redis")])
        _ = try await manager.ensure(changed, projectKey: projectKey)
        #expect(daemon.events.withLock { $0 } == ["remove old"], "\(daemon.events.withLock { $0 })")
        daemon.events.withLock { $0.removeAll() }
        changed[0].definition.environment = ["MAXMEMORY": "64mb"]
        _ = try await manager.ensure(changed, projectKey: projectKey)
        #expect(daemon.events.withLock { $0 } == ["remove cache", "create cache", "start cache"])
        let requests = server.requests.withLock { $0 }
        #expect(!requests.contains { $0.method == "DELETE" && $0.path.contains("/volumes/") }, "volumes are never removed by start or recreate")
        let status = try await manager.status(projectKey: projectKey, specs: changed, imageIDs: ["redis": "sha256:img"])
        #expect(status["cache"]?.isRunning == true && status["cache"]?.outdated == false)
    }
}
