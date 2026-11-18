import Foundation

/// Which container images may run, for the workspace and every service (docs/features/containers.md, "Image policy").
/// App-wide: set by an administrator (managed preferences, `ManagedImagePolicy`) or, when none is managed, in
/// Settings ▸ Containers. An image outside the policy is refused with a specific message; nothing is pulled or run.
public struct ImagePolicy: Codable, Sendable, Equatable, Hashable {
    public enum PullPolicy: String, Codable, Sendable, CaseIterable, Hashable {
        /// Pull an image only when it is not on this Mac (default).
        case missing
        /// Pull before creating or recreating a container, so a moved tag is followed.
        case always
        /// Never pull: images must be loaded on this Mac by other means.
        case never
    }

    /// Registries (`registry.acme.internal`) or repository prefixes (`registry.acme.internal/dev/`,
    /// `docker.io/library/postgres`). Empty: any image.
    public var allowedPrefixes: [String]
    /// Images must be referenced by digest (`…@sha256:<64 hex>`), so a tag cannot move under the project.
    public var requireDigest: Bool
    public var pullPolicy: PullPolicy
    /// Images must carry a verified signature. BelloCode cannot verify signatures in this version
    /// (`ImageSignatureVerification`), so this refuses every image: it never weakens to "unverified".
    public var requireSignature: Bool
    /// The public key signatures would be verified with (PEM), kept for the verifier seam.
    public var signatureKey: String?

    public init(allowedPrefixes: [String] = [], requireDigest: Bool = false, pullPolicy: PullPolicy = .missing, requireSignature: Bool = false,
                signatureKey: String? = nil) {
        self.allowedPrefixes = allowedPrefixes
        self.requireDigest = requireDigest
        self.pullPolicy = pullPolicy
        self.requireSignature = requireSignature
        self.signatureKey = signatureKey
    }

    public static let open = ImagePolicy()

    enum CodingKeys: String, CodingKey { case allowedPrefixes, requireDigest, pullPolicy, requireSignature, signatureKey }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowedPrefixes = try c.decodeIfPresent([String].self, forKey: .allowedPrefixes) ?? []
        requireDigest = try c.decodeIfPresent(Bool.self, forKey: .requireDigest) ?? false
        pullPolicy = try c.decodeIfPresent(PullPolicy.self, forKey: .pullPolicy) ?? .missing
        requireSignature = try c.decodeIfPresent(Bool.self, forKey: .requireSignature) ?? false
        signatureKey = try c.decodeIfPresent(String.self, forKey: .signatureKey)
    }

    /// Why `reference` may not run, or nil when it may.
    public func refusal(for reference: String, verifier: (any ImageSignatureVerifier)? = nil) -> String? {
        let normalized = ImageReference.normalize(reference)
        let allowed = allowedPrefixes.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !allowed.isEmpty, !allowed.contains(where: { ImageReference.matches(normalized, prefix: $0) }) {
            return "The image \(reference) is not allowed by the image policy (allowed: \(allowed.joined(separator: ", "))). Choose an image from an allowed registry, or ask your administrator."
        }
        if requireDigest, !ImageReference.isPinned(reference) {
            return "The image policy requires images pinned by digest (name@sha256:…); \(reference) is not. Use the image's digest reference."
        }
        if requireSignature, verifier == nil {
            return "The image policy requires verified image signatures, which this version of BelloCode cannot check, so no image may run. Ask your administrator (docs/features/containers.md, security-team decisions)."
        }
        return nil
    }
}

/// Image reference handling (Docker's normalisation: `node:22` is `docker.io/library/node:22`).
public enum ImageReference {
    /// The registry host of a reference (`docker.io` when none is named).
    public static func registry(of reference: String) -> String {
        let first = reference.split(separator: "/", maxSplits: 1).first.map(String.init) ?? reference
        guard reference.contains("/"), first.contains(".") || first.contains(":") || first == "localhost" else { return "docker.io" }
        return first
    }

    public static func normalize(_ reference: String) -> String {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0].contains(".") || parts[0].contains(":") || parts[0] == "localhost" {
            return parts[0] == "index.docker.io" ? "docker.io/" + parts[1] : trimmed
        }
        return parts.count == 1 ? "docker.io/library/" + trimmed : "docker.io/" + trimmed
    }

    /// `prefix` without a slash names a registry; otherwise it is a repository prefix matched at a path, tag or digest
    /// boundary (`docker.io/library/postgres` matches `postgres:16` but not `postgresql`).
    public static func matches(_ normalized: String, prefix: String) -> Bool {
        let entry = prefix.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { return false }
        if !entry.contains("/") { return registry(of: normalized) == (entry == "index.docker.io" ? "docker.io" : entry) }
        let target = entry.hasPrefix("docker.io/") || registryLike(entry) ? entry : normalize(entry)
        if target.hasSuffix("/") { return normalized.hasPrefix(target) }
        guard normalized.hasPrefix(target) else { return false }
        let rest = normalized.dropFirst(target.count)
        return rest.isEmpty || rest.first == "/" || rest.first == ":" || rest.first == "@"
    }

    static func registryLike(_ entry: String) -> Bool {
        let first = entry.split(separator: "/").first.map(String.init) ?? ""
        return first.contains(".") || first.contains(":") || first == "localhost"
    }

    /// Referenced by a sha256 digest.
    public static func isPinned(_ reference: String) -> Bool {
        guard let at = reference.range(of: "@sha256:") else { return false }
        let hex = reference[at.upperBound...]
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit)
    }
}

/// The seam for image signature verification (docs/features/containers.md, "Image signatures"). No implementation
/// ships: verifying cosign or Notary v2 signatures soundly needs the registry's OCI referrers or signature-tag
/// artifacts fetched with the user's registry credentials, the signed payload's digest bound to the exact image the
/// daemon runs, and the security team's choice of key-based or keyless (Fulcio/Rekor) trust. A policy that requires
/// signatures therefore refuses every image until a verifier is provided.
public protocol ImageSignatureVerifier: Sendable {
    /// Throws unless `digestReference` (`name@sha256:…`) carries a valid signature for `publicKey`.
    func verify(digestReference: String, publicKey: String) async throws
}

/// The administrator's image policy, from managed preferences (docs/features/containers.md, "For administrators").
/// Read from (1) keys forced by a configuration profile in the app's preferences domain (`com.bellocode.app`), or
/// (2) a root-owned property list at `/Library/Preferences/app.bellocode.policy.plist` that only administrators can
/// write. Keys: `ContainerImageAllowlist` (array of strings), `ContainerImageRequireDigest` (bool),
/// `ContainerImagePullPolicy` (`missing` | `always` | `never`), `ContainerImageRequireSignature` (bool),
/// `ContainerImageSignaturePublicKey` (string, PEM), `ContainerDefaultImage` (string). When either source sets any key,
/// the policy is managed and Settings shows it read-only.
public enum ManagedImagePolicy {
    public static let allowlistKey = "ContainerImageAllowlist"
    public static let requireDigestKey = "ContainerImageRequireDigest"
    public static let pullPolicyKey = "ContainerImagePullPolicy"
    public static let requireSignatureKey = "ContainerImageRequireSignature"
    public static let signatureKeyKey = "ContainerImageSignaturePublicKey"
    public static let defaultImageKey = "ContainerDefaultImage"
    public static let keys = [allowlistKey, requireDigestKey, pullPolicyKey, requireSignatureKey, signatureKeyKey, defaultImageKey]
    public static let systemPlist = "/Library/Preferences/app.bellocode.policy.plist"

    public struct Managed: Sendable, Equatable {
        public var policy: ImagePolicy
        public var defaultImage: String?
        /// Where it came from, for Settings ("configuration profile", or the plist path).
        public var source: String

        public init(policy: ImagePolicy, defaultImage: String? = nil, source: String) {
            self.policy = policy
            self.defaultImage = defaultImage
            self.source = source
        }
    }

    /// The managed policy, or nil when an administrator set none.
    public static func read(defaults: UserDefaults = .standard, systemPlist: String = systemPlist) -> Managed? {
        let forced = keys.filter { defaults.objectIsForced(forKey: $0) }
        if !forced.isEmpty {
            return managed(from: { defaults.object(forKey: $0) }, source: "configuration profile")
        }
        guard let values = rootOwnedPlist(systemPlist), keys.contains(where: { values[$0] != nil }) else { return nil }
        return managed(from: { values[$0] }, source: systemPlist)
    }

    static func managed(from value: (String) -> Any?, source: String) -> Managed {
        var policy = ImagePolicy()
        policy.allowedPrefixes = (value(allowlistKey) as? [String]) ?? (value(allowlistKey) as? String).map { [$0] } ?? []
        policy.requireDigest = (value(requireDigestKey) as? Bool) ?? false
        policy.pullPolicy = (value(pullPolicyKey) as? String).flatMap(ImagePolicy.PullPolicy.init(rawValue:)) ?? .missing
        policy.requireSignature = (value(requireSignatureKey) as? Bool) ?? false
        policy.signatureKey = value(signatureKeyKey) as? String
        return Managed(policy: policy, defaultImage: value(defaultImageKey) as? String, source: source)
    }

    /// The plist's values only when root owns it and nobody else can write it (a user-writable file is not policy).
    static func rootOwnedPlist(_ path: String) -> [String: Any]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue, permissions & 0o022 == 0,
              let data = FileManager.default.contents(atPath: path),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return values
    }
}
