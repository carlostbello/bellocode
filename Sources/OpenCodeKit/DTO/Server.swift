import Foundation

/// `ServerInfo` (`GET /api/info`). Only server info proves readiness and identity.
public struct ServerInfo: Codable, Sendable, Hashable {
    public struct Paths: Codable, Sendable, Hashable {
        public var tmp: String
    }

    public struct Capabilities: Codable, Sendable, Hashable {
        public var persistentPty: Bool?
    }

    public var version: String
    public var pid: Int
    public var hostname: String?
    public var urls: [String]
    public var paths: Paths
    public var capabilities: Capabilities?

    public init(version: String, pid: Int, hostname: String? = nil, urls: [String] = [], tmp: String = "/tmp") {
        self.version = version
        self.pid = pid
        self.hostname = hostname
        self.urls = urls
        self.paths = Paths(tmp: tmp)
    }
}

/// The single JSON line `opencode serve --stdio` prints on stdout once it listens.
public struct ServerReadyLine: Decodable, Sendable, Hashable {
    public var url: URL
}
