import Foundation

/// Where the proxy sends one request (docs/features/secrets.md "Routing"). The proxy asks its router after the request
/// has been checked and any secret substituted, so substitution never depends on the route or on which client (a
/// workspace container, a browser container) sent the request.
public enum EgressRoute: Sendable {
    /// The internet: the system resolver and trust, through the company proxy when one is configured.
    case internet
    /// A container address reached through a gateway that is attached to the container's Docker network.
    case dial(EgressDial)
    /// Not allowed; the text goes to the client in a 403.
    case refuse(String)
}

/// How to reach a container: an endpoint on the Mac's loopback that leads to it. In practice a ContainerKit
/// `PortForwarder` on a gateway attached to the container's Docker network, with `containerHost` set to the container's
/// name or alias there (an exec relay per connection: no published port, works on internal networks). An optional
/// preamble is sent first (for relays that need one).
public struct EgressDial: Sendable, Hashable {
    public var endpoint: HostPort
    public var preamble: Data?

    public init(endpoint: HostPort, preamble: Data? = nil) {
        self.endpoint = endpoint
        self.preamble = preamble
    }
}

/// The pluggable routing step. `scope` is the client's gateway scope (which workspace or browser the request came from).
public protocol EgressRouter: Sendable {
    func route(scheme: String, destination: HostPort, scope: String) async -> EgressRoute
}

/// The default: everything goes to the internet (workspaces today).
public struct InternetRouter: EgressRouter {
    public init() {}
    public func route(scheme: String, destination: HostPort, scope: String) async -> EgressRoute { .internet }
}

/// Routes names under a private suffix (`.bc`) through a table, everything else to the internet; unknown private names
/// are refused rather than looked up on the internet.
public struct SuffixRouter: EgressRouter {
    public var suffix: String
    public var table: @Sendable (HostPort, String) async -> EgressRoute?

    public init(suffix: String = "bc", table: @escaping @Sendable (HostPort, String) async -> EgressRoute?) {
        self.suffix = suffix.lowercased()
        self.table = table
    }

    public func route(scheme: String, destination: HostPort, scope: String) async -> EgressRoute {
        guard destination.host == suffix || destination.host.hasSuffix("." + suffix) else { return .internet }
        return await table(destination, scope) ?? .refuse("\(destination) is not a known BelloCode route.")
    }
}
