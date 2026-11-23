import Foundation

/// The corporate network as every BelloCode container sees it (docs/features/containers.md, "Corporate network"): the
/// enterprise root certificates a TLS-intercepting proxy signs with, and proxy variables when the Mac or an
/// administrator sets them. Applied at creation to workspace, service and MCP containers.
///
/// Certificates need no root at run time: the folder holding the bundles is mounted read-only and the common
/// variables point at it (`SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, `PIP_CERT`, `GIT_SSL_CAINFO`,
/// `CURL_CA_BUNDLE`). The enterprise roots are also mounted into the distributions' trust-store source folders, and a
/// workspace gets the combined bundle, read-only, at the distributions' compiled bundle paths (`compiledBundleMounts`),
/// so programs that ignore the variables trust them too. Nothing of a project's image runs as root for it (AF09).
public struct CorporateNetwork: Codable, Sendable, Equatable, Hashable {
    /// Host folder holding `ca-bundle.pem` (the Mac's trusted roots plus the selected enterprise roots) and
    /// `enterprise-roots.pem` (only the selected enterprise roots). Nil: no certificates are added.
    public var certificateDirectory: String?
    /// SHA-256 of the enterprise bundle: part of every container's configuration, so a new selection recreates them.
    public var certificateFingerprint: String?
    public var httpProxy: String?
    public var httpsProxy: String?
    /// Hosts that bypass the proxy (from the Mac or an administrator); loopback and the project's services are added.
    public var noProxy: [String]

    public init(certificateDirectory: String? = nil, certificateFingerprint: String? = nil, httpProxy: String? = nil, httpsProxy: String? = nil,
                noProxy: [String] = []) {
        self.certificateDirectory = certificateDirectory
        self.certificateFingerprint = certificateFingerprint
        self.httpProxy = httpProxy
        self.httpsProxy = httpsProxy
        self.noProxy = noProxy
    }

    public var isEmpty: Bool { certificateDirectory == nil && httpProxy == nil && httpsProxy == nil }
    public var hasProxy: Bool { httpProxy != nil || httpsProxy != nil }

    public static let containerDirectory = "/etc/bellocode/certs"
    public static let bundleName = "ca-bundle.pem"
    public static let enterpriseName = "enterprise-roots.pem"
    public static var containerBundle: String { "\(containerDirectory)/\(bundleName)" }
    public static var containerEnterprise: String { "\(containerDirectory)/\(enterpriseName)" }
    /// Trust-store source folders: Debian, Ubuntu and Alpine (`update-ca-certificates`), Fedora and RHEL (`update-ca-trust`).
    public static let debianAnchor = "/usr/local/share/ca-certificates/bellocode-enterprise.crt"
    public static let redHatAnchor = "/etc/pki/ca-trust/source/anchors/bellocode-enterprise.pem"
    /// Always bypass the proxy.
    public static let loopback = ["localhost", "127.0.0.1", "::1"]

    /// `NO_PROXY`: the configured hosts, loopback, then `extra` (the project's service names), each once, in order.
    public static func composeNoProxy(_ configured: [String], extra: [String]) -> String {
        var seen = Set<String>()
        var hosts: [String] = []
        for host in configured + loopback + extra {
            let trimmed = host.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            hosts.append(trimmed)
        }
        return hosts.joined(separator: ",")
    }

    /// A proxy on the Mac's own loopback (a local agent such as a VPN client's) is not reachable at `127.0.0.1` from a
    /// container: it is the Mac's `host.docker.internal` there (Rancher Desktop).
    public static func containerProxyURL(_ url: String) -> String {
        guard var components = URLComponents(string: url), let host = components.host else { return url }
        if loopback.contains(host) || host == "[::1]" { components.host = "host.docker.internal" }
        return components.string ?? url
    }

    /// Variables set in a container. `noProxyExtra` are the hosts of the container's own network (service names).
    public func environment(noProxyExtra: [String]) -> [String: String] {
        var env: [String: String] = [:]
        if certificateDirectory != nil {
            env["SSL_CERT_FILE"] = Self.containerBundle
            env["REQUESTS_CA_BUNDLE"] = Self.containerBundle
            env["PIP_CERT"] = Self.containerBundle
            env["GIT_SSL_CAINFO"] = Self.containerBundle
            env["CURL_CA_BUNDLE"] = Self.containerBundle
            // Node adds these to its own roots (it does not read SSL_CERT_FILE).
            env["NODE_EXTRA_CA_CERTS"] = Self.containerEnterprise
            if let certificateFingerprint { env["BELLOCODE_CA_FINGERPRINT"] = String(certificateFingerprint.prefix(16)) }
        }
        if hasProxy {
            if let httpProxy {
                env["HTTP_PROXY"] = Self.containerProxyURL(httpProxy)
                env["http_proxy"] = env["HTTP_PROXY"]
            }
            if let httpsProxy {
                env["HTTPS_PROXY"] = Self.containerProxyURL(httpsProxy)
                env["https_proxy"] = env["HTTPS_PROXY"]
            }
            let noProxy = Self.composeNoProxy(noProxy, extra: noProxyExtra)
            env["NO_PROXY"] = noProxy
            env["no_proxy"] = noProxy
        }
        return env
    }

    /// The mounts: the bundle folder read-only, and the enterprise roots in both trust-store source folders.
    public var mounts: [Mount] {
        guard let certificateDirectory else { return [] }
        let enterprise = (certificateDirectory as NSString).appendingPathComponent(Self.enterpriseName)
        return [
            Mount(type: .bind, source: certificateDirectory, target: Self.containerDirectory, readOnly: true),
            Mount(type: .bind, source: enterprise, target: Self.debianAnchor, readOnly: true),
            Mount(type: .bind, source: enterprise, target: Self.redHatAnchor, readOnly: true),
        ]
    }

    /// The compiled trust bundles of Debian, Ubuntu and Alpine, and of Fedora and RHEL: what programs that read no
    /// variable use. A workspace gets the combined bundle there instead of running the image's
    /// `update-ca-certificates` / `update-ca-trust` as root (AF09).
    public static let compiledBundles = ["/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt"]

    /// The combined bundle (the Mac's trusted roots and the enterprise roots), read-only at each compiled bundle path.
    public var compiledBundleMounts: [Mount] {
        guard let certificateDirectory else { return [] }
        let bundle = (certificateDirectory as NSString).appendingPathComponent(Self.bundleName)
        return Self.compiledBundles.map { Mount(type: .bind, source: bundle, target: $0, readOnly: true) }
    }

    /// Adds the variables (a value the definition already sets wins) and the mounts to a create body.
    public func apply(to body: inout ContainerCreate, noProxyExtra: [String]) {
        guard !isEmpty else { return }
        var env = body.env ?? []
        let present = Set(env.compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        for (name, value) in environment(noProxyExtra: noProxyExtra).sorted(by: { $0.key < $1.key }) where !present.contains(name) {
            env.append("\(name)=\(value)")
        }
        body.env = env
        var host = body.hostConfig ?? HostConfig()
        let targets = Set((host.mounts ?? []).map(\.target))
        host.mounts = (host.mounts ?? []) + mounts.filter { !targets.contains($0.target) }
        body.hostConfig = host
    }
}
