import CryptoKit
import Foundation

/// BelloCode's own egress gateway image (R08, docs/reviews/release-1.0-review.md): the relay that holds a scope's
/// gateway token and joins the outbound bridge never runs code from a project's image. The image is built locally from
/// source compiled into the app (this file: a Dockerfile with no `RUN` step and the relay program), on a base pinned by
/// digest, so the runtime is verified by content address and the only program in it besides the base is BelloCode's.
/// The tag names the inputs' hash: a change to the relay or the base builds a new image and recreates the gateways.
public enum EgressGatewayImage {
    public static let repository = "bellocode-egress-gateway"
    public static let labelInputs = "app.bellocode.egress-gateway-inputs"
    /// The shared browser's base (`Containers/browser/versions.env` BASE_IMAGE), pinned by digest: one Docker Hub image
    /// serves both, so a Mac that built shared Chrome needs no further pull, and the layers are shared.
    public static let base = "node:22-bookworm-slim@sha256:e9f565d32859f0cbfb52125eafe8be39390f24dac302dc3cdf566e8ba3ab21ee"

    static var dockerfile: String {
        """
        FROM \(base)
        COPY relay.js /opt/bellocode/relay.js
        USER 65534:65534
        ENTRYPOINT ["node", "/opt/bellocode/relay.js"]

        """
    }

    /// SHA-256 over the Dockerfile and the relay program.
    public static var inputHash: String {
        var hasher = SHA256()
        for part in [dockerfile, EgressGateway.nodeRelay] {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static var tag: String { "\(repository):\(inputHash.prefix(16))" }

    /// The build context (in memory): the Dockerfile and the relay, nothing else.
    public static func context() -> Data {
        TarArchive([
            TarArchive.Entry(path: "Dockerfile", contents: Data(dockerfile.utf8)),
            TarArchive.Entry(path: "relay.js", contents: Data(EgressGateway.nodeRelay.utf8)),
        ]).data()
    }

    /// The image's tag, built first if this installation does not have it (labelled with its inputs' hash; an image of
    /// that name with another hash, made by someone else, is rebuilt over).
    public static func ensure(client: EngineClient, extraLabels: [String: String] = [:]) async throws -> String {
        let hash = inputHash
        if let existing = try await client.inspectImage(tag), existing.labels?[labelInputs] == hash { return tag }
        do {
            _ = try await client.buildImage(
                context: context(), tag: tag,
                labels: [labelInputs: hash, EgressGateway.labelEgress: "1"].merging(extraLabels) { a, _ in a })
        } catch {
            throw EgressGatewayError("BelloCode could not build its egress gateway image (it needs \(base.split(separator: "@").first ?? "") from Docker Hub once, pinned by digest): \(error)")
        }
        guard let built = try await client.inspectImage(tag), built.labels?[labelInputs] == hash else {
            throw EgressGatewayError("BelloCode built its egress gateway image, but the image it finds under \(tag) is not that build.")
        }
        return tag
    }
}
