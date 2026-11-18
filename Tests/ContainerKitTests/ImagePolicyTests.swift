import Foundation
import Testing

@testable import ContainerKit

@Suite("Image policy")
struct ImagePolicyTests {
    let digest = "sha256:" + String(repeating: "0123456789abcdef", count: 4)

    @Test func referencesNormaliseLikeDocker() {
        #expect(ImageReference.normalize("node:22") == "docker.io/library/node:22")
        #expect(ImageReference.normalize("bitnami/redis") == "docker.io/bitnami/redis")
        #expect(ImageReference.normalize("index.docker.io/library/node") == "docker.io/library/node")
        #expect(ImageReference.normalize("registry.acme.internal:5000/dev/base:1") == "registry.acme.internal:5000/dev/base:1")
        #expect(ImageReference.normalize("localhost/x") == "localhost/x")
        #expect(ImageReference.registry(of: "postgres:16") == "docker.io")
        #expect(ImageReference.registry(of: "ghcr.io/a/b") == "ghcr.io")
    }

    @Test func allowlistMatchesRegistriesAndPrefixesAtBoundaries() {
        let policy = ImagePolicy(allowedPrefixes: ["registry.acme.internal", "docker.io/library/postgres", "ghcr.io/acme/"])
        #expect(policy.refusal(for: "registry.acme.internal/dev/node:22") == nil)
        #expect(policy.refusal(for: "postgres:16") == nil)
        #expect(policy.refusal(for: "postgres@\(digest)") == nil)
        #expect(policy.refusal(for: "ghcr.io/acme/tools:1") == nil)
        #expect(policy.refusal(for: "postgresql:16") != nil, "a prefix matches at a boundary only")
        #expect(policy.refusal(for: "registry.acme.internal.evil.com/x") != nil)
        #expect(policy.refusal(for: "ghcr.io/acmeco/tools") != nil)
        let refusal = policy.refusal(for: "node:22") ?? ""
        #expect(refusal.contains("node:22 is not allowed by the image policy") && refusal.contains("registry.acme.internal"))
        #expect(ImagePolicy.open.refusal(for: "anything/at:all") == nil)
        #expect(ImagePolicy(allowedPrefixes: ["library/node"]).refusal(for: "node:22") == nil, "short Docker Hub prefixes normalise too")
    }

    @Test func digestAndSignatureRequirements() {
        let pinned = ImagePolicy(requireDigest: true)
        #expect(pinned.refusal(for: "node@\(digest)") == nil)
        #expect(pinned.refusal(for: "node:22")?.contains("pinned by digest") == true)
        #expect(pinned.refusal(for: "node@sha256:abc") != nil, "a short digest is not a pin")
        // Without a verifier a signature requirement refuses every image (never weakened to "unverified").
        let signed = ImagePolicy(requireSignature: true, signatureKey: "-----BEGIN PUBLIC KEY-----")
        #expect(signed.refusal(for: "node@\(digest)")?.contains("cannot check") == true)
        struct Verifier: ImageSignatureVerifier { func verify(digestReference: String, publicKey: String) async throws {} }
        #expect(signed.refusal(for: "node@\(digest)", verifier: Verifier()) == nil)
    }

    @Test func policyDecodesOlderAndPartialDocuments() throws {
        let decoded = try JSONDecoder().decode(ImagePolicy.self, from: Data(#"{"allowedPrefixes":["a.io"]}"#.utf8))
        #expect(decoded == ImagePolicy(allowedPrefixes: ["a.io"]))
        #expect(try JSONDecoder().decode(ImagePolicy.self, from: JSONEncoder().encode(ImagePolicy(requireDigest: true, pullPolicy: .never))).pullPolicy == .never)
    }

    @Test func managedValuesAndTheirSources() throws {
        let values: [String: Any] = [
            ManagedImagePolicy.allowlistKey: ["registry.acme.internal"], ManagedImagePolicy.requireDigestKey: true,
            ManagedImagePolicy.pullPolicyKey: "always", ManagedImagePolicy.defaultImageKey: "registry.acme.internal/dev/base@\(digest)",
        ]
        let managed = ManagedImagePolicy.managed(from: { values[$0] }, source: "test")
        #expect(managed.policy == ImagePolicy(allowedPrefixes: ["registry.acme.internal"], requireDigest: true, pullPolicy: .always))
        #expect(managed.defaultImage == "registry.acme.internal/dev/base@\(digest)")
        // A plist the user can write is not policy (only a root-owned, non-writable one is).
        let path = FileManager.default.temporaryDirectory.appending(path: "policy-\(UUID().uuidString).plist").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: URL(filePath: path))
        #expect(ManagedImagePolicy.rootOwnedPlist(path) == nil)
        let defaults = try #require(UserDefaults(suiteName: "bellocode.test.\(UUID().uuidString)"))
        defaults.set(["x.io"], forKey: ManagedImagePolicy.allowlistKey)
        #expect(ManagedImagePolicy.read(defaults: defaults, systemPlist: path) == nil, "a key the user set is not forced: not managed")
    }
}
