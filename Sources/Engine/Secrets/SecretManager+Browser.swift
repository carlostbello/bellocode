import ContainerKit
import Foundation
import SecretKit

// The shared browser's place on the egress path (docs/features/secrets.md "Routing", docs/features/shared-browser.md):
// one more scope, `browser`, with its own gateway; and a routes-only `preview` scope for the WebKit preview's loopback
// proxy front. Substitution never depends on the route or the client: a scope's `admitsProject` is all the proxy knows.

extension SecretManager {
    nonisolated public static let browserScopeKey = BrowserContainerSpec.scopeKey
    nonisolated public static let previewScopeKey = "preview"

    /// Makes the browser's gateway (in the browser image, which has python3 for the relay) and registers its scope;
    /// returns where the browser container goes: the internal network, Chromium's proxy and the certificate folder
    /// (enterprise roots + BelloCode's egress CA, imported into Chromium's NSS store at every start).
    public func ensureBrowserScope(image: String, admitsProject: @escaping @Sendable (String) -> Bool,
                                   extraLabels: [String: String] = [:]) async throws -> BrowserNetworkPlacement {
        guard case .ready(let port) = egressStatus, let proxy, let configuration, let socket = environments?.activeRuntime.socketPath else {
            throw BrowserStartError.unavailable(
                "The shared Chrome reaches the network only through BelloCode's egress proxy, which is not running. Turn on Settings ▸ Secrets ▸ Container network (enforced egress) and relaunch.")
        }
        let key = Self.browserScopeKey
        let scope = EgressScope(id: key, token: scopes[key]?.token ?? (UUID().uuidString.lowercased() + UUID().uuidString.lowercased()),
                                admitsProject: admitsProject)
        scopes[key] = scope
        await proxy.publishScopes(Array(scopes.values))
        let spec = EgressGatewaySpec(scopeKey: key, image: image, proxyPort: Int(port), token: scope.token,
                                     extraLabels: [BrowserImageContext.labelBrowser: "1"].merging(extraLabels) { a, _ in a })
        try await EgressGateway(client: EngineClient(socketPath: socket)).ensure(spec)
        return BrowserNetworkPlacement(network: EgressGateway.networkName(key), proxy: EgressAttachment.proxyURL,
                                       certificateDirectory: Self.certificateDirectory(configuration).path)
    }

    /// A routes-only scope for the WebKit preview's proxy front on the Mac: it reaches registered `*.bc` routes and
    /// nothing else, and no placeholder is ever substituted for it.
    public func previewScope() -> (port: UInt16, token: String)? {
        guard case .ready(let port) = egressStatus, let proxy else { return nil }
        let key = Self.previewScopeKey
        let scope = scopes[key] ?? EgressScope(id: key, token: UUID().uuidString.lowercased() + UUID().uuidString.lowercased()) { _ in false }
        scopes[key] = scope
        proxy.setScopes(Array(scopes.values))
        return (port, scope.token)
    }

    /// The egress CA certificate (DER), which the WebKit preview trusts for `*.bc` names only.
    public var egressAuthorityDER: Data? {
        guard let configuration else { return nil }
        return try? Data(contentsOf: configuration.directory.appending(path: "egress-ca.der"))
    }
}
