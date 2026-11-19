import Foundation

/// A Docker object with one of BelloCode's names exists but does not carry the labels BelloCode puts on what it
/// creates: BelloCode never stops, removes, recreates or adopts it (docs/reviews/release-1.0-review.md, R07). The
/// message names the object and what the person can do; nothing is changed.
public struct ForeignResourceError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable { case container, volume, network }
    public var kind: Kind
    public var name: String

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }

    public var description: String {
        "A Docker \(kind.rawValue) named \(name) exists but was not created by BelloCode (it does not carry BelloCode's labels), so BelloCode left it untouched. If it is yours, rename it; if it is unused, remove it (docker \(kind.rawValue) rm \(name)). Then retry."
    }
}

/// The ownership rule: an object is BelloCode's for a role only when it carries every one of the role's labels with
/// the exact value. Names alone never prove ownership (anyone can create `bellocode-…`).
public enum ResourceOwnership {
    public static func isOwned(_ labels: [String: String]?, by required: [String: String]) -> Bool {
        guard let labels, !required.isEmpty else { return false }
        return required.allSatisfy { labels[$0.key] == $0.value }
    }
}

extension EngineClient {
    /// `GET /volumes/{name}`: the volume with its labels, nil when absent.
    public func inspectVolume(_ name: String) async throws -> VolumeInfo? {
        do {
            return try decode(VolumeInfo.self, try await call("GET", "/volumes/\(Self.escape(name))"))
        } catch ContainerError.notFound {
            return nil
        }
    }

    /// The container named `name` when it carries every `required` label; nil when there is none; throws
    /// `ForeignResourceError` when one exists without them (the caller must then leave it alone).
    public func ownedContainer(_ name: String, required: [String: String]) async throws -> ContainerInspect? {
        guard let existing = try await inspectContainer(name) else { return nil }
        guard ResourceOwnership.isOwned(existing.config.labels, by: required) else { throw ForeignResourceError(kind: .container, name: name) }
        return existing
    }

    /// The volume named `name` when it carries every `required` label; nil when absent; throws otherwise.
    public func ownedVolume(_ name: String, required: [String: String]) async throws -> VolumeInfo? {
        guard let existing = try await inspectVolume(name) else { return nil }
        guard ResourceOwnership.isOwned(existing.labels, by: required) else { throw ForeignResourceError(kind: .volume, name: name) }
        return existing
    }

    /// Creates the volume, or confirms that the existing one is BelloCode's (creating an existing volume "succeeds" in
    /// Docker and would silently adopt someone else's data). Checked after the create, so a concurrent foreign create
    /// is caught too.
    public func ensureOwnedVolume(name: String, labels: [String: String], required: [String: String]) async throws {
        if try await ownedVolume(name, required: required) != nil { return }
        try await createVolume(name: name, labels: labels)
        guard try await ownedVolume(name, required: required) != nil else { throw ContainerError.notFound(name) }
    }

    /// The network named `name` when it carries every `required` label; nil when absent; throws otherwise.
    public func ownedNetwork(_ name: String, required: [String: String]) async throws -> NetworkInfo? {
        guard let existing = try await inspectNetwork(name) else { return nil }
        guard ResourceOwnership.isOwned(existing.labels, by: required) else { throw ForeignResourceError(kind: .network, name: name) }
        return existing
    }
}
