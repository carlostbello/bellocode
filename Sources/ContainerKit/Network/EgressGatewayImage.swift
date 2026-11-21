import CryptoKit
import Foundation
import Synchronization

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

    /// Image IDs this process built from the inputs above, per Docker daemon socket (app-owned state, v1.0.0 review
    /// A07). A tag and a label are claims anyone with the daemon can make; an image ID is the content address of what
    /// BelloCode built.
    private static let trusted = Mutex<[String: String]>([:])

    /// The ID (`sha256:…`) of the gateway image this process built, building it now if it has not (in this launch,
    /// for this daemon, from these inputs). Gateways are created by this ID, never by the mutable tag: an image someone
    /// else put under the tag, or retagged later, is never run as the gateway, whatever its labels claim.
    public static func ensure(client: EngineClient, extraLabels: [String: String] = [:]) async throws -> String {
        let hash = inputHash
        let key = client.socketPath + "\n" + hash
        if let id = trusted.withLock({ $0[key] }), let image = try await client.inspectImage(id), image.id == id { return id }
        // One build per daemon and inputs at a time: concurrent setups (several scopes, the shared browser) wait for the
        // same build instead of racing to write the same tag.
        let build = building.withLock { building -> Task<String, any Error> in
            if let running = building[key] { return running }
            let task = Task { try await buildTrusted(client: client, hash: hash, extraLabels: extraLabels) }
            building[key] = task
            return task
        }
        do {
            let id = try await build.value
            building.withLock { if $0[key] == build { $0[key] = nil } }
            trusted.withLock { $0[key] = id }
            return id
        } catch {
            building.withLock { if $0[key] == build { $0[key] = nil } }
            throw error
        }
    }

    private static let building = Mutex<[String: Task<String, any Error>]>([:])

    private static func buildTrusted(client: EngineClient, hash: String, extraLabels: [String: String]) async throws -> String {
        var reported: String?
        var lastError: (any Error)?
        // A second attempt covers another process (the helper, a second app instance) writing the same tag meanwhile.
        for attempt in 0..<2 where reported == nil {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(300)) }
            do {
                reported = try await client.buildImage(
                    context: context(), tag: tag,
                    labels: [labelInputs: hash, EgressGateway.labelEgress: "1"].merging(extraLabels) { a, _ in a })
            } catch {
                lastError = error
            }
        }
        if reported == nil, let lastError {
            throw EgressGatewayError("BelloCode could not build its egress gateway image (it needs \(base.split(separator: "@").first ?? "") from Docker Hub once, pinned by digest): \(lastError)")
        }
        // The build's own result names the image; the tag is not consulted (it may already point elsewhere).
        guard let id = reported, id.hasPrefix("sha256:"), let built = try await client.inspectImage(id), built.id == id,
              built.labels?[labelInputs] == hash else {
            throw EgressGatewayError("BelloCode built its egress gateway image, but the daemon did not report that build's image ID, so it is not used.")
        }
        return id
    }
}
