import Foundation
import Network
import Security
import WebKit

/// The built-in preview's route to the shared browser's canonical project names (docs/features/shared-browser.md
/// "Canonical URLs on the Mac"): a project's website data store sends `*.bc` requests (only those) through BelloCode's
/// authenticated loopback proxy front, so `https://<project>.bc:<port>/` is the same URL in the preview and in the
/// shared Chrome. TLS for those names is terminated by BelloCode's egress CA, trusted here for `*.bc` hosts only.
/// Everything else keeps the store's normal path. Set by the app once the shared browser's front runs.
@MainActor
public enum CanonicalPreviewProxy {
    public struct Endpoint: Sendable, Equatable {
        public var port: UInt16
        public var username: String
        public var password: String
        public var authorityDER: Data?
        public init(port: UInt16, username: String, password: String, authorityDER: Data?) {
            self.port = port
            self.username = username
            self.password = password
            self.authorityDER = authorityDER
        }
    }

    public private(set) static var endpoint: Endpoint?
    private static var configured: [ObjectIdentifier: WKWebsiteDataStore] = [:]

    public static func set(_ endpoint: Endpoint?) {
        guard endpoint != self.endpoint else { return }
        self.endpoint = endpoint
        for store in configured.values { apply(to: store) }
    }

    /// Applies the proxy (or removes it) on a store; remembered so a later endpoint change reaches it.
    static func apply(to store: WKWebsiteDataStore) {
        configured[ObjectIdentifier(store)] = store
        guard let endpoint, let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            store.proxyConfigurations = []
            return
        }
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port), tlsOptions: nil)
        proxy.applyCredential(username: endpoint.username, password: endpoint.password)
        proxy.matchDomains = ["bc"]
        proxy.allowFailover = false
        store.proxyConfigurations = [proxy]
    }

    static func isCanonical(_ host: String) -> Bool { host.lowercased().hasSuffix(".bc") }

    /// Server trust for a `*.bc` host: valid only against BelloCode's egress CA (never for other hosts).
    static func trust(_ challenge: URLAuthenticationChallenge) -> URLCredential? {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              isCanonical(challenge.protectionSpace.host), let trust = challenge.protectionSpace.serverTrust,
              let der = endpoint?.authorityDER, let anchor = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, challenge.protectionSpace.host as CFString))
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else { return nil }
        return URLCredential(trust: trust)
    }
}
