import Foundation
import Testing

@testable import ContainerKit

@Suite("YAML subset and compose parsing")
struct ComposeParserTests {
    @Test func yamlSubsetReadsWhatComposeFilesUse() throws {
        let node = try YAMLSubset.parse("""
            # comment
            ---
            name: demo   # trailing comment
            services:
              db:
                image: "postgres:16"
                environment:
                  - POSTGRES_PASSWORD=dev # not a secret
                  - 'QUOTED=a # b'
                ports: ["5432:5432", 8080]
                healthcheck:
                  test: [ "CMD-SHELL", "pg_isready -U postgres" ]
                  interval: 2s
              app:
                command: >
                  node server.js
                  --port 3000
                depends_on:
                - db
              script:
                command: |
                  line one
                  line two
            empty:
            flow: {a: 1, b: [x, "y z"]}
            """)
        #expect(node["name"]?.string == "demo")
        #expect(node["services"]?["db"]?["image"]?.string == "postgres:16")
        #expect(node["services"]?["db"]?["environment"]?.items?.compactMap(\.string) == ["POSTGRES_PASSWORD=dev", "QUOTED=a # b"])
        #expect(node["services"]?["db"]?["ports"]?.items?.compactMap(\.string) == ["5432:5432", "8080"])
        #expect(node["services"]?["db"]?["healthcheck"]?["test"]?.items?.compactMap(\.string) == ["CMD-SHELL", "pg_isready -U postgres"])
        #expect(node["services"]?["app"]?["command"]?.string == "node server.js --port 3000\n")
        #expect(node["services"]?["app"]?["depends_on"]?.items?.compactMap(\.string) == ["db"])
        #expect(node["services"]?["script"]?["command"]?.string == "line one\nline two\n")
        #expect(node["empty"] == .null)
        #expect(node["flow"]?["b"]?.items?.compactMap(\.string) == ["x", "y z"])
    }

    @Test func yamlSubsetRefusesWhatItDoesNotSupport() {
        let cases: [(String, String)] = [
            ("a: &x 1\nb: *x", "anchors"),
            ("base: &b\n  image: x", "anchors"),
            ("a:\n  <<: {b: 1}", "merge keys"),
            ("a: !!str 1", "tags"),
            ("a: 1\n---\nb: 2", "only one YAML document"),
            ("a:\n\tb: 1", "tabs"),
            ("a: 1\na: 2", "duplicate key"),
        ]
        for (source, fragment) in cases {
            do {
                _ = try YAMLSubset.parse(source)
                Issue.record("accepted: \(source)")
            } catch {
                #expect(error.description.contains(fragment), "\(source) → \(error.description)")
            }
        }
    }

    @Test func supportedSubsetBecomesServiceDefinitions() throws {
        let result = ComposeParser.parse("""
            version: "3.9"
            services:
              cache:
                image: redis:7-alpine
                ports: ["6379"]
                healthcheck:
                  test: ["CMD", "redis-cli", "ping"]
                  interval: 1s
                  timeout: 500ms
                  retries: 5
                  start_period: 1m30s
                volumes:
                  - cache-data:/data
                  - type: volume
                    source: extra
                    target: /extra
                    read_only: true
              app:
                image: node:22-bookworm-slim
                command: node -e "console.log(1)"
                environment:
                  REDIS_URL: redis://cache:6379
                  EMPTY: ""
                depends_on:
                  cache:
                    condition: service_healthy
            volumes:
              cache-data: {}
              extra:
            """)
        #expect(result.isUsable && result.rejected.isEmpty && result.refusedServices.isEmpty, "\(result)")
        let cache = try #require(result.services.first { $0.name == "cache" })
        #expect(cache.ports == [.init(containerPort: 6379)])
        #expect(cache.volumes == [.init(name: "cache-data", target: "/data"), .init(name: "extra", target: "/extra", readOnly: true)])
        #expect(cache.healthcheck == .init(test: ["CMD", "redis-cli", "ping"], intervalSeconds: 1, timeoutSeconds: 0.5, startPeriodSeconds: 90, retries: 5))
        let app = try #require(result.services.first { $0.name == "app" })
        #expect(app.command == ["node", "-e", "console.log(1)"])
        #expect(app.environment == ["REDIS_URL": "redis://cache:6379", "EMPTY": ""])
        #expect(app.dependsOn == [.init(service: "cache", condition: .healthy)])
        #expect(try ComposeParser.startOrder(result.services) == [["cache"], ["app"]])
    }

    @Test func refusedKeysStopTheServiceAndIgnoredKeysAreListed() {
        let result = ComposeParser.parse("""
            services:
              web:
                build: .
              priv:
                image: alpine
                privileged: true
              bind:
                image: alpine
                volumes: ["./src:/src", "/etc:/host-etc:ro"]
              ok:
                image: alpine
                restart: always
                container_name: fixed
                env_file: .env
                environment: [HOME_DIR, "TOKEN=${TOKEN}"]
                ports: ["3000-3005:3000-3005", "127.0.0.1:9000:9000"]
                networks: [default]
              needsPriv:
                image: alpine
                depends_on: [priv]
            networks:
              default: {}
            x-common: {}
            """)
        #expect(Set(result.refusedServices) == ["web", "priv", "bind", "needsPriv"])
        #expect(result.services.map(\.name) == ["ok"])
        let rejected = Set(result.rejected.map(\.path))
        #expect(rejected.isSuperset(of: ["services.web.build", "services.priv.privileged", "services.bind.volumes[0]", "services.bind.volumes[1]",
                                         "services.needsPriv.depends_on"]))
        let ignored = Set(result.ignored.map(\.path))
        #expect(ignored.isSuperset(of: ["services.ok.restart", "services.ok.container_name", "services.ok.env_file", "services.ok.networks",
                                        "services.ok.environment.HOME_DIR", "services.ok.environment.TOKEN", "services.ok.ports[0]", "networks", "x-common"]))
        #expect(result.services.first?.ports == [.init(containerPort: 9000)], "a host address is irrelevant: nothing is published")
        #expect(result.services.first?.environment["TOKEN"] == "${TOKEN}", "no interpolation from the Mac's environment")
    }

    @Test func unusableFilesSayWhy() {
        #expect(!ComposeParser.parse("services: {}").isUsable)
        #expect(!ComposeParser.parse("just text").isUsable)
        #expect(ComposeParser.parse("services:\n  a: [\n").errors.first?.contains("line") == true)
        let cycle = ComposeParser.parse("services:\n  a: {image: x, depends_on: [b]}\n  b: {image: x, depends_on: [a]}")
        #expect(cycle.errors.first?.contains("cycle") == true && cycle.services.isEmpty)
    }

    @Test func startOrderLayersDependencies() throws {
        let services = [
            ServiceDefinition(name: "web", image: "x", dependsOn: [.init(service: "api")]),
            ServiceDefinition(name: "api", image: "x", dependsOn: [.init(service: "db"), .init(service: "cache")]),
            ServiceDefinition(name: "db", image: "x"),
            ServiceDefinition(name: "cache", image: "x"),
            ServiceDefinition(name: "worker", image: "x", dependsOn: [.init(service: "db")]),
        ]
        #expect(try ComposeParser.startOrder(services) == [["cache", "db"], ["api", "worker"], ["web"]])
    }

    @Test func durationsAndGateTimeouts() {
        #expect(ComposeParser.duration("1m30s") == 90)
        #expect(ComposeParser.duration("250ms") == 0.25)
        #expect(ComposeParser.duration("2h") == 7200)
        #expect(ComposeParser.duration("5") == 5)
        #expect(ComposeParser.duration("soon") == nil)
        let check = ServiceDefinition.Healthcheck(test: ["CMD", "true"], intervalSeconds: 1, timeoutSeconds: 1, startPeriodSeconds: 5, retries: 3)
        #expect(check.gateTimeoutSeconds == 43)
        #expect(ServiceDefinition.Healthcheck(test: ["CMD"], intervalSeconds: 600, retries: 10).gateTimeoutSeconds == 300)
    }

    @Test func serviceContainersArePrivateToTheProjectNetwork() throws {
        let spec = ServiceSpec(
            projectRoot: "/Users/a/p",
            definition: ServiceDefinition(name: "db", image: "postgres:16", environment: ["A": "1"], ports: [.init(containerPort: 5432)],
                                          volumes: [.init(name: "data", target: "/var/lib/postgresql/data")],
                                          healthcheck: .init(test: ["CMD-SHELL", "pg_isready"], intervalSeconds: 2, retries: 3)),
            network: ServiceLabels.networkName(projectKey: WorkspaceSpec.projectKey(for: "/Users/a/p"), offline: false))
        let body = spec.createBody(imageID: "sha256:1")
        let host = try #require(body.hostConfig)
        #expect(host.portBindings == nil && body.exposedPorts == nil, "nothing is published on the Mac")
        #expect(host.privileged == false && host.capAdd == nil && host.securityOpt == ["no-new-privileges:true"])
        #expect(host.networkMode == spec.network)
        #expect(body.networkingConfig?.endpointsConfig[spec.network]?.aliases == ["db"], "reachable by service name")
        #expect(host.mounts == [Mount(type: .volume, source: "bellocode-\(spec.projectKey)-svc-data", target: "/var/lib/postgresql/data")])
        #expect(body.healthcheck == HealthConfig(test: ["CMD-SHELL", "pg_isready"], interval: 2_000_000_000, retries: 3))
        #expect(body.labels?[ServiceLabels.service] == "db" && body.labels?[WorkspaceSpec.labelProjectKey] == spec.projectKey)
        var changed = spec
        changed.definition.environment["A"] = "2"
        #expect(changed.configHash(imageID: "sha256:1") != spec.configHash(imageID: "sha256:1"), "a definition change recreates")

        var workspace = WorkspaceSpec(projectRoot: "/Users/a/p", image: "node:22")
        workspace.serviceNetwork = spec.network
        #expect(workspace.createBody(imageID: nil).hostConfig?.networkMode == spec.network, "the workspace joins the services' network")
        #expect(ServiceLabels.networkName(projectKey: "k", offline: true) == "bellocode-net-k-offline")
    }
}
