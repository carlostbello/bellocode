import Foundation
import Testing

@testable import ContainerKit

/// Enforced egress through the filtered endpoint (docs/features/secrets.md "Agent-created containers"): a scope whose
/// workspace is egress-enforced gets the same boundary for every container and network its agent creates.
@Suite("Docker filter egress", .timeLimit(.minutes(1)))
struct DockerFilterEgressTests {
    struct Lookup: DockerLookup {
        func container(_ reference: String) async -> DockerObject? { nil }
        func volume(_ name: String) async -> DockerObject? { nil }
        func network(_ reference: String) async -> DockerObject? {
            switch reference {
            case "ownnet": DockerObject(id: "ownnet-id", name: "ownnet", labels: DockerAgentLabels.labels("s"))
            case "bridge": DockerObject(id: "bridge-id", name: "bridge")
            case "bellocode-egress-s": DockerObject(id: "egress-id", name: "bellocode-egress-s")
            default: nil
            }
        }
        func image(_ reference: String) async -> DockerObject? { nil }
        func execContainer(_ id: String) async -> String? { nil }
        func containerCount(scope: String) async -> Int { 0 }
        func createVolume(name: String, labels: [String: String]) async throws {}
    }

    let egress = DockerEgress(network: "bellocode-egress-s", environment: ["HTTPS_PROXY": "http://bellocode-proxy:3128"],
                              certificateDirectory: "/Users/me/Library/Application Support/BelloCode/egress/certs")
    var scope: DockerScope { DockerScope(key: "s", roots: ["/Users/me/Repos"], egress: egress) }
    var policy: DockerFilterPolicy { DockerFilterPolicy(lookup: Lookup()) }

    func body(_ decision: DockerDecision) -> [String: Any] {
        guard case .forward(let request, _, _, _) = decision, let data = request.body else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func create(_ json: String) async -> DockerDecision {
        await policy.decide(DockerAPIRequest.parse(method: "POST", target: "/v1.47/containers/create", body: Data(json.utf8)), scope: scope)
    }

    @Test func defaultAndBridgeContainersJoinTheEgressNetworkWithProxyAndCA() async {
        for mode in ["", "\"NetworkMode\":\"bridge\","] {
            let decision = await create(#"{"Image":"postgres:16","HostConfig":{\#(mode)"Memory":0}}"#)
            let config = body(decision)
            let host = config["HostConfig"] as? [String: Any] ?? [:]
            #expect(host["NetworkMode"] as? String == "bellocode-egress-s", "\(mode)")
            let env = config["Env"] as? [String] ?? []
            #expect(env.contains("HTTPS_PROXY=http://bellocode-proxy:3128"))
            #expect(env.contains { $0.hasPrefix("SSL_CERT_FILE=") } && env.contains { $0.hasPrefix("NODE_EXTRA_CA_CERTS=") })
            let mounts = host["Mounts"] as? [[String: Any]] ?? []
            #expect(mounts.contains { $0["Target"] as? String == CorporateNetwork.containerDirectory && $0["ReadOnly"] as? Bool == true })
            #expect((host["Sysctls"] as? [String: Any])?["net.ipv6.conf.all.disable_ipv6"] as? String == "1")
        }
    }

    @Test func ownNetworksKeepTheirNameAndAddTheEgressEndpoint() async {
        let config = body(await create(#"{"Image":"postgres:16","HostConfig":{"NetworkMode":"ownnet"},"NetworkingConfig":{"EndpointsConfig":{"ownnet":{"Aliases":["db"]}}}}"#))
        let host = config["HostConfig"] as? [String: Any] ?? [:]
        #expect(host["NetworkMode"] as? String == "ownnet")
        let endpoints = ((config["NetworkingConfig"] as? [String: Any])?["EndpointsConfig"] as? [String: Any]) ?? [:]
        #expect(Set(endpoints.keys) == ["ownnet", "bellocode-egress-s"])
    }

    @Test func noneAndHostAndForeignNetworks() async {
        let none = body(await create(#"{"Image":"postgres:16","HostConfig":{"NetworkMode":"none"}}"#))
        #expect((none["HostConfig"] as? [String: Any])?["NetworkMode"] as? String == "none")
        #expect(none["NetworkingConfig"] == nil)
        #expect(await create(#"{"Image":"postgres:16","HostConfig":{"NetworkMode":"host"}}"#).isRefused)
        #expect(await create(#"{"Image":"postgres:16","HostConfig":{"NetworkMode":"bellocode-egress-other"}}"#).isRefused)
    }

    @Test func agentNetworksAreCreatedInternal() async {
        let decision = await policy.decide(
            DockerAPIRequest.parse(method: "POST", target: "/v1.47/networks/create", body: Data(#"{"Name":"app_default","Internal":false}"#.utf8)), scope: scope)
        let object = body(decision)
        #expect(object["Internal"] as? Bool == true && object["EnableIPv6"] as? Bool == false)
        // Without enforced egress the request is unchanged.
        let open = await policy.decide(
            DockerAPIRequest.parse(method: "POST", target: "/v1.47/networks/create", body: Data(#"{"Name":"app_default"}"#.utf8)),
            scope: DockerScope(key: "s", roots: ["/Users/me/Repos"]))
        #expect(body(open)["Internal"] == nil)
    }
}
