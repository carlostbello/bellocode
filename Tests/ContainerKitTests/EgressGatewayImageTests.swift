import Foundation
import Testing

@testable import ContainerKit

/// R08 (docs/reviews/release-1.0-review.md): the trusted egress gateway runs BelloCode's own relay image, built from
/// source in the app on a base pinned by digest, never the project's workspace image.
@Suite("Egress gateway image")
struct EgressGatewayImageTests {
    @Test func workspaceGatewaysNeverRunTheProjectImage() {
        let spec = EgressGatewaySpec(scopeKey: "p1234", proxyPort: 49_152, token: "tok")
        let body = EgressGateway.createBody(spec)
        #expect(body.image == EgressGatewayImage.tag)
        #expect(body.image.hasPrefix(EgressGatewayImage.repository + ":"))
        #expect(body.entrypoint == nil, "the image's own entrypoint: BelloCode's relay")
        let env = body.env ?? []
        #expect(!env.contains { $0.hasPrefix("BC_NODE=") || $0.hasPrefix("BC_PY=") }, "no program text through the environment")
        #expect(env.contains("BC_TOKEN=tok"))
        #expect(body.user == "65534:65534")
        #expect(body.hostConfig?.readonlyRootfs == true && body.hostConfig?.capDrop == ["ALL"] && body.hostConfig?.privileged == false)
        #expect(body.hostConfig?.networkMode == EgressGateway.networkName("p1234"), "internal network only until the relay listens")
    }

    @Test func imageIsBuiltFromBelloCodeSourceOnAPinnedBase() throws {
        let base = EgressGatewayImage.base
        let digest = try #require(base.split(separator: "@").last)
        #expect(digest.hasPrefix("sha256:") && digest.dropFirst("sha256:".count).count == 64
                && digest.dropFirst("sha256:".count).allSatisfy(\.isHexDigit), "base pinned by digest: \(base)")
        // Same base as the shared browser, so no second Docker Hub pull.
        let versions = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Containers/browser/versions.env")
        let browserBase = try String(contentsOf: versions, encoding: .utf8).split(separator: "\n")
            .first { $0.hasPrefix("BASE_IMAGE=") }.map { String($0.dropFirst("BASE_IMAGE=".count)) }
        #expect(browserBase == base)
        let dockerfile = EgressGatewayImage.dockerfile
        #expect(dockerfile.hasPrefix("FROM \(base)\n"))
        #expect(!dockerfile.split(separator: "\n").contains { $0.hasPrefix("RUN") }, "no build step fetches or runs anything")
        #expect(dockerfile.contains("USER 65534:65534"))
        // The context is exactly the Dockerfile and BelloCode's relay.
        let tar = EgressGatewayImage.context()
        let names = Self.tarNames(tar)
        #expect(names == ["Dockerfile", "relay.js"])
        #expect(ByteSearchHelper.contains(tar, Data(EgressGateway.nodeRelay.utf8)))
        // The tag follows the inputs.
        #expect(EgressGatewayImage.tag.hasSuffix(String(EgressGatewayImage.inputHash.prefix(16))))
    }

    static func tarNames(_ data: Data) -> [String] {
        var names: [String] = []
        var offset = 0
        let bytes = [UInt8](data)
        while offset + 512 <= bytes.count {
            let header = bytes[offset..<offset + 512]
            guard header.contains(where: { $0 != 0 }) else { break }
            let name = String(decoding: header.prefix(100).prefix { $0 != 0 }, as: UTF8.self)
            let sizeText = String(decoding: header.dropFirst(124).prefix(11), as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
            let size = Int(sizeText, radix: 8) ?? 0
            names.append(name)
            offset += 512 + (size + 511) / 512 * 512
        }
        return names
    }
}

enum ByteSearchHelper {
    static func contains(_ haystack: Data, _ needle: Data) -> Bool { haystack.range(of: needle) != nil }
}
