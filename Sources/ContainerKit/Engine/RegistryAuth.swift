import Foundation

/// Credentials for one registry, sent only as the `X-Registry-Auth` header of a pull (base64url JSON, Docker's format).
/// Held in memory for the duration of the request; never stored in a container, a label, a file or a log. Its
/// description never shows the password.
public struct RegistryAuth: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var username: String
    public var password: String
    public var serverAddress: String

    public init(username: String, password: String, serverAddress: String) {
        self.username = username
        self.password = password
        self.serverAddress = serverAddress
    }

    /// The header value: base64url (no padding) of `{"username","password","serveraddress"}`.
    public var headerValue: String {
        let object: [String: String] = ["username": username, "password": password, "serveraddress": serverAddress]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public var description: String { "RegistryAuth(\(serverAddress), user \(username), password <secret>)" }
    public var debugDescription: String { description }

    /// The registry host of an image reference: the first path component when it looks like a host (has a dot or a
    /// colon, or is `localhost`), else Docker Hub (`docker.io`).
    public static func registry(of reference: String) -> String {
        let name = reference.split(separator: "@").first.map(String.init) ?? reference
        guard let slash = name.firstIndex(of: "/") else { return "docker.io" }
        let first = String(name[..<slash])
        if first.contains(".") || first.contains(":") || first == "localhost" { return first }
        return "docker.io"
    }
}
