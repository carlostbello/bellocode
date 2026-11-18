import Foundation
import Testing

@testable import ContainerKit

/// Corporate network in containers: NO_PROXY composition, the variables and mounts at creation (never overriding a
/// value the definition sets), proxies on the Mac's loopback, the Mac's and an administrator's proxy settings, and the
/// diagnostics probe's parsing.
@Suite("Corporate network")
struct CorporateNetworkTests {
    @Test func noProxyAlwaysHasLoopbackThenTheProjectsServicesOnceEach() {
        let value = CorporateNetwork.composeNoProxy([".corp.example", "LOCALHOST", "internal.example"], extra: ["db", "cache", "db", " "])
        #expect(value == ".corp.example,LOCALHOST,internal.example,127.0.0.1,::1,db,cache")
        #expect(CorporateNetwork.composeNoProxy([], extra: []) == "localhost,127.0.0.1,::1")
    }

    @Test func certificatesAreMountedReadOnlyAndEveryToolIsPointedAtThem() {
        let network = CorporateNetwork(certificateDirectory: "/Users/me/Library/Application Support/BelloCode/opencode/network/certs",
                                       certificateFingerprint: String(repeating: "ab", count: 32))
        let env = network.environment(noProxyExtra: [])
        #expect(env["SSL_CERT_FILE"] == "/etc/bellocode/certs/ca-bundle.pem")
        #expect(env["REQUESTS_CA_BUNDLE"] == "/etc/bellocode/certs/ca-bundle.pem")
        #expect(env["PIP_CERT"] == "/etc/bellocode/certs/ca-bundle.pem")
        #expect(env["GIT_SSL_CAINFO"] == "/etc/bellocode/certs/ca-bundle.pem")
        #expect(env["NODE_EXTRA_CA_CERTS"] == "/etc/bellocode/certs/enterprise-roots.pem", "Node adds to its own roots")
        #expect(env["HTTP_PROXY"] == nil && env["NO_PROXY"] == nil, "no proxy variables without a proxy")
        #expect(network.mounts.allSatisfy { $0.readOnly == true })
        #expect(Set(network.mounts.map(\.target)) == [CorporateNetwork.containerDirectory, CorporateNetwork.debianAnchor, CorporateNetwork.redHatAnchor])
    }

    @Test func applyNeverOverridesTheDefinitionsOwnValues() {
        var body = ContainerCreate(image: "x")
        body.env = ["HTTPS_PROXY=http://own:3128"]
        var host = HostConfig()
        host.mounts = [Mount(type: .bind, source: "/a", target: "/a")]
        body.hostConfig = host
        let network = CorporateNetwork(certificateDirectory: "/c", httpProxy: "http://proxy.corp:8080", httpsProxy: "http://proxy.corp:8080",
                                       noProxy: [".corp"])
        network.apply(to: &body, noProxyExtra: ["db"])
        #expect(body.env?.filter { $0.hasPrefix("HTTPS_PROXY=") } == ["HTTPS_PROXY=http://own:3128"])
        #expect(body.env?.contains("HTTP_PROXY=http://proxy.corp:8080") == true)
        #expect(body.env?.contains("NO_PROXY=.corp,localhost,127.0.0.1,::1,db") == true)
        #expect(body.env?.contains("no_proxy=.corp,localhost,127.0.0.1,::1,db") == true)
        #expect(body.hostConfig?.mounts?.first?.source == "/a")
        #expect(body.hostConfig?.mounts?.count == 4)
    }

    @Test func aProxyOnTheMacsLoopbackIsReachedThroughTheHostName() {
        #expect(CorporateNetwork.containerProxyURL("http://127.0.0.1:9000") == "http://host.docker.internal:9000")
        #expect(CorporateNetwork.containerProxyURL("http://localhost:3128") == "http://host.docker.internal:3128")
        #expect(CorporateNetwork.containerProxyURL("http://proxy.corp:8080") == "http://proxy.corp:8080")
    }

    @Test func aWorkspaceWithCorporateNetworkIsRecreatedWhenTheBundleChanges() {
        var spec = WorkspaceSpec(projectRoot: "/p", image: "img")
        let plain = spec.configHash(imageID: "sha256:1")
        spec.corporateNetwork = CorporateNetwork(certificateDirectory: "/c", certificateFingerprint: "aa")
        let first = spec.configHash(imageID: "sha256:1")
        spec.corporateNetwork?.certificateFingerprint = "bb"
        #expect(plain != first)
        #expect(first != spec.configHash(imageID: "sha256:1"), "a new selection reaches existing containers")
        spec.serviceNames = ["db"]
        spec.corporateNetwork?.httpProxy = "http://p:1"
        #expect(spec.createBody(imageID: nil).env?.contains("NO_PROXY=localhost,127.0.0.1,::1,db") == true)
    }

    @Test func servicesGetTheBundleAndTheirSiblingsBypassTheProxy() {
        var spec = ServiceSpec(projectRoot: "/p", definition: ServiceDefinition(name: "api", image: "img"), network: "n")
        spec.corporateNetwork = CorporateNetwork(certificateDirectory: "/c", httpsProxy: "http://proxy:1")
        spec.siblings = ["api", "db"]
        let body = spec.createBody(imageID: nil)
        #expect(body.env?.contains("NO_PROXY=localhost,127.0.0.1,::1,api,db") == true)
        #expect(body.hostConfig?.mounts?.contains { $0.target == CorporateNetwork.containerDirectory } == true)
    }

    @Test func theMacsProxyComesFromTheEnvironmentThenSystemSettings() {
        let fromEnv = SystemProxySettings.from(environment: ["https_proxy": "http://p:8", "NO_PROXY": "a, b"], system: ["HTTPEnable": 1, "HTTPProxy": "x"])
        #expect(fromEnv == SystemProxySettings(httpProxy: nil, httpsProxy: "http://p:8", noProxy: ["a", "b"], source: "environment"))
        let system: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "proxy.corp", "HTTPPort": 8080, "HTTPSEnable": 1, "HTTPSProxy": "proxy.corp",
                                     "HTTPSPort": 8443, "ExceptionsList": ["*.local", "169.254/16"]]
        let fromSystem = SystemProxySettings.from(environment: [:], system: system)
        #expect(fromSystem.httpProxy == "http://proxy.corp:8080")
        #expect(fromSystem.httpsProxy == "http://proxy.corp:8443")
        #expect(fromSystem.noProxy == [".local", "169.254/16"])
        #expect(SystemProxySettings.from(environment: [:], system: ["HTTPEnable": 0, "HTTPProxy": "x"]).source == nil,
                "a transparent proxy sets nothing: nothing is passed")
    }

    @Test func anAdministratorsKeysAreRead() {
        let values: [String: Any] = [
            ManagedNetworkPolicy.trustKey: true,
            ManagedNetworkPolicy.certificatesKey: ["AB:CD:EF", "0123 4567"],
            ManagedNetworkPolicy.httpsProxyKey: "http://proxy.corp:8080",
            ManagedNetworkPolicy.noProxyKey: ".corp, .internal",
            ManagedNetworkPolicy.diagnosticsKey: ["https://gitlab.example.com"],
        ]
        let managed = ManagedNetworkPolicy.managed(from: { values[$0] }, source: "configuration profile")
        #expect(managed.trustEnterpriseCertificates == true)
        #expect(managed.certificates == ["abcdef", "01234567"])
        #expect(managed.httpsProxy == "http://proxy.corp:8080")
        #expect(managed.noProxy == [".corp", ".internal"])
        #expect(managed.setsProxy)
        #expect(managed.diagnosticsURLs == ["https://gitlab.example.com"])
    }

    @Test func theProbeReportsIssuerProxyHeadersAndFailures() {
        let output = """
        @@url https://registry.npmjs.org
        @@tool curl
        * Uses proxy env variable https_proxy == 'http://proxy.corp:8080'
        *  subject: CN=registry.npmjs.org
        *  issuer: C=US; O=Example Corp; CN=Example Corp TLS Inspection CA
        < HTTP/2 200
        < content-type: application/json
        < via: 1.1 proxy.corp (squid)
        < X-Cache: MISS from proxy.corp

        @@exit 0
        @@url https://pypi.org/simple/
        @@tool curl
        curl: (60) SSL certificate problem: unable to get local issuer certificate

        @@exit 60
        """
        let results = NetworkProbe.parse(output, urls: ["https://registry.npmjs.org", "https://pypi.org/simple/", "https://gitlab.example.com"])
        #expect(results[0].ok)
        #expect(results[0].status == 200)
        #expect(results[0].issuer == "C=US; O=Example Corp; CN=Example Corp TLS Inspection CA")
        #expect(results[0].proxyHeaders == ["via: 1.1 proxy.corp (squid)", "X-Cache: MISS from proxy.corp"])
        #expect(results[0].proxy == "http://proxy.corp:8080")
        #expect(!results[1].ok)
        #expect(results[1].error?.contains("unable to get local issuer certificate") == true)
        #expect(!results[2].ok, "a URL the probe never reached is a failure, not silence")
        let none = NetworkProbe.parse("@@url https://x\n@@tool none\n@@exit 127\n", urls: ["https://x"])
        #expect(none[0].error == "the container image has no curl, python3 or wget to fetch with")
    }
}
