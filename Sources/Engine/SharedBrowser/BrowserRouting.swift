import ContainerKit
import Foundation
import SecretKit

/// One canonical name resolved to a container endpoint (pure; tested).
public struct BrowserRouteTarget: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable { case workspace, service }
    public var kind: Kind
    public var project: String
    /// The container the relay runs in: always the project's workspace container. Its loopback reaches loopback-only
    /// dev servers; its project network resolves services by alias. Nothing joins a project network at runtime:
    /// attaching the egress gateway to one changed the gateway's default route and silently broke the browser's open
    /// proxy tunnels (seen live), so routes never touch the browser's own network path.
    public var container: String
    public var host: String
    public var port: Int
}

/// What the router knows about a project when it resolves a name (a snapshot taken on the main actor).
public struct BrowserRouteProject: Sendable, Equatable {
    public var directory: String
    public var label: String
    public var projectKey: String
    public var workspaceContainer: String
    public var workspaceRunning: Bool
    /// Service name → declared container ports (running services only).
    public var services: [String: [Int]]
    public var offline: Bool

    public init(directory: String, label: String, projectKey: String, workspaceContainer: String, workspaceRunning: Bool,
                services: [String: [Int]] = [:], offline: Bool = false) {
        self.directory = directory
        self.label = label
        self.projectKey = projectKey
        self.workspaceContainer = workspaceContainer
        self.workspaceRunning = workspaceRunning
        self.services = services
        self.offline = offline
    }
}

/// The routing table of canonical project names (docs/features/shared-browser.md "Networking and canonical URLs"):
/// `https://<label>.bc:<port>/` → the project's workspace container on that port (its own loopback);
/// `https://<service>.<label>.bc[:port]/` → the service by alias, from the workspace container on the project network
/// (443 → its first declared port). Anything else under `.bc` is refused, never looked up on the internet.
public enum BrowserRouteTable {
    public enum Resolution: Sendable, Equatable {
        case target(BrowserRouteTarget)
        case refuse(String)
    }

    public static func resolve(_ destination: HostPort, projects: [BrowserRouteProject]) -> Resolution {
        let parts = destination.host.lowercased().split(separator: ".").map(String.init)
        guard parts.last == BrowserNaming.suffix, parts.count == 2 || parts.count == 3 else {
            return .refuse("\(destination.host) is not a BelloCode project name (use https://<project>.bc:<port>/ or https://<service>.<project>.bc/).")
        }
        let label = parts[parts.count - 2]
        guard let project = projects.first(where: { $0.label == label }) else {
            return .refuse("No active BelloCode project is named \(label).bc. Open a thread of the project first (its URL is shown in the thread header).")
        }
        if parts.count == 2 {
            guard project.workspaceRunning else {
                return .refuse("The workspace of \(label).bc is not running; start the dev server in a thread of that project first.")
            }
            return .target(BrowserRouteTarget(kind: .workspace, project: project.directory, container: project.workspaceContainer,
                                              host: "127.0.0.1", port: destination.port))
        }
        let service = parts[0]
        guard project.workspaceRunning else {
            return .refuse("The workspace of \(label).bc is not running, and its services are reached through it; open a thread of that project first.")
        }
        guard let ports = project.services[service] else {
            return .refuse("\(label).bc has no running service named \(service).")
        }
        let port: Int
        if destination.port == 443 || destination.port == 80 {
            guard let first = ports.first else { return .refuse("The service \(service) declares no port.") }
            port = first
        } else {
            guard ports.contains(destination.port) else {
                return .refuse("The service \(service) of \(label).bc does not declare port \(destination.port) (declared: \(ports.map(String.init).joined(separator: ", "))).")
            }
            port = destination.port
        }
        return .target(BrowserRouteTarget(kind: .service, project: project.directory, container: project.workspaceContainer, host: service, port: port))
    }
}

/// The proxy's router with the shared browser: `.bc` names through the table; other names to the internet path for
/// scopes allowed to reach it (the browser), refused for the WebKit preview scope (routes only).
public struct BrowserEgressRouter: EgressRouter {
    public let table: @Sendable (HostPort, String) async -> EgressRoute?
    public let fallback: any EgressRouter
    public let routesOnlyScopes: Set<String>

    public init(table: @escaping @Sendable (HostPort, String) async -> EgressRoute?, fallback: any EgressRouter, routesOnlyScopes: Set<String>) {
        self.table = table
        self.fallback = fallback
        self.routesOnlyScopes = routesOnlyScopes
    }

    public func route(scheme: String, destination: HostPort, scope: String) async -> EgressRoute {
        if destination.host == BrowserNaming.suffix || destination.host.hasSuffix("." + BrowserNaming.suffix) {
            return await table(destination, scope) ?? .refuse("\(destination) is not a known BelloCode route.")
        }
        if routesOnlyScopes.contains(scope) { return .refuse("This proxy listener reaches only BelloCode project routes (*.bc).") }
        return await fallback.route(scheme: scheme, destination: destination, scope: scope)
    }
}
