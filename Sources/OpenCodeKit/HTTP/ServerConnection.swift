import Foundation

/// Basic-auth credentials for an opencode server. The password is never printed: `description` is redacted.
public struct ServerCredentials: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    /// opencode accepts only this username.
    public static let username = "opencode"

    let password: String

    public init(password: String) { self.password = password }

    /// A fresh random password (32 random bytes, base64) for one server launch.
    public static func random() -> ServerCredentials {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return ServerCredentials(password: Data(bytes).base64EncodedString())
    }

    var authorizationHeader: String {
        "Basic " + Data("\(Self.username):\(password)".utf8).base64EncodedString()
    }

    public var description: String { "ServerCredentials(<redacted>)" }
    public var debugDescription: String { description }
}

/// Where a server listens and how to authenticate to it.
public struct ServerConnection: Sendable, Hashable {
    public var baseURL: URL
    public var credentials: ServerCredentials

    public init(baseURL: URL, credentials: ServerCredentials) {
        self.baseURL = baseURL
        self.credentials = credentials
    }
}

/// A started server whose identity has been verified: the info endpoint reported the pid of the child we launched.
public struct ServerEndpoint: Sendable, Hashable {
    public var connection: ServerConnection
    public var info: ServerInfo
    /// Monotonic generation, incremented on every successful (re)start. Consumers compare it to discard results
    /// from a previous server.
    public var generation: Int

    public init(connection: ServerConnection, info: ServerInfo, generation: Int) {
        self.connection = connection
        self.info = info
        self.generation = generation
    }

    public var baseURL: URL { connection.baseURL }
    public var pid: Int { info.pid }
    public var version: String { info.version }
}
