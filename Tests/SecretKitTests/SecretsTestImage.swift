import ContainerKit
import Foundation

/// The adversarial suites' workspace image, `bellocode-secrets-test:1`: the shared browser's pinned base
/// (`EgressGatewayImage.base`, so no Docker Hub pull on a Mac that has it) plus the clients the attempts drive: bash and
/// node (from the base), curl with HTTP/2, dig, netcat and python3. Every probe needs its tool: a missing `dig` or `nc`
/// would make an "unreachable" check pass vacuously, so `ensure` verifies them after building.
///
/// Built in memory on first use when absent (Debian packages come from deb.debian.org during the build). Kept between
/// runs like `bellocode-test-ws:1`; remove it with `docker rmi bellocode-secrets-test:1`. Labelled
/// `app.bellocode.test-image=secrets` (not `app.bellocode.test`, which the suites remove).
enum SecretsTestImage {
    static let tag = "bellocode-secrets-test:1"
    static let tools = ["bash", "node", "curl", "dig", "nc", "python3", "base64", "od", "getent"]

    static var dockerfile: String {
        """
        FROM \(EgressGatewayImage.base)
        RUN apt-get update \\
         && apt-get install -y --no-install-recommends curl ca-certificates dnsutils netcat-openbsd python3 \\
         && rm -rf /var/lib/apt/lists/*

        """
    }

    /// Builds the image unless `reference` is already present. A reference other than the default tag (set with
    /// `BELLOCODE_SECRET_IMAGE`) is never built: it must exist.
    static func ensure(_ reference: String, client: EngineClient) async throws {
        if try await client.inspectImage(reference) != nil { return }
        guard reference == tag else { return }
        let context = TarArchive([TarArchive.Entry(path: "Dockerfile", contents: Data(dockerfile.utf8))]).data()
        _ = try await client.buildImage(context: context, tag: tag, labels: ["app.bellocode.test-image": "secrets"])
        guard try await client.inspectImage(tag) != nil else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "built \(tag), but it is not listed"])
        }
    }

    /// The shell line that fails with the names of any missing tools.
    static var toolCheck: String {
        "missing=''; for t in \(tools.joined(separator: " ")); do command -v $t >/dev/null || missing=\"$missing $t\"; done; "
            + "if [ -n \"$missing\" ]; then echo \"missing:$missing\"; exit 1; fi; echo tools-ok"
    }
}
