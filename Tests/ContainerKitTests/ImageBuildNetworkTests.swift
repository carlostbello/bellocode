import Foundation
import Testing

@testable import ContainerKit

/// The corporate network for image builds: proxy build arguments, the certificates in every stage of a Dockerfile
/// (context or named-context form), and the files and CLI arguments a build passes.
@Suite("Image build network")
struct ImageBuildNetworkTests {
    static let certs = CorporateNetwork(certificateDirectory: "/Users/me/certs", certificateFingerprint: "ab")

    @Test func proxiesBecomeDockersPredefinedBuildArgumentsOnlyWhenSet() {
        #expect(ImageBuildNetwork(Self.certs).buildArgs().isEmpty, "a transparent proxy needs none")
        let network = ImageBuildNetwork(CorporateNetwork(httpProxy: "http://127.0.0.1:3128", httpsProxy: "http://proxy.corp:8080", noProxy: [".corp"]))
        let args = network.buildArgs(noProxyExtra: ["db"])
        #expect(args["HTTPS_PROXY"] == "http://proxy.corp:8080" && args["https_proxy"] == "http://proxy.corp:8080")
        #expect(args["HTTP_PROXY"] == "http://host.docker.internal:3128", "the Mac's loopback is not the build container's")
        #expect(args["NO_PROXY"] == ".corp,localhost,127.0.0.1,::1,db" && args["no_proxy"] == args["NO_PROXY"])
        #expect(network.cliArguments(noProxyExtra: ["db"]).filter { $0 == "--build-arg" }.count == 6)
        #expect(!network.cliArguments().contains("--build-context"), "no certificates, no named context")
    }

    @Test func everyStageGetsTheCertificatesAndNothingElseChanges() {
        let dockerfile = """
            # syntax=docker/dockerfile:1
            ARG NODE=22
            # FROM in a comment is not a stage
            FROM --platform=$BUILDPLATFORM node:${NODE} AS build
            RUN <<EOF
            echo FROM inside a heredoc
            EOF
            RUN npm ci
            from \\
              gcr.io/distroless/nodejs22 AS runtime
            COPY --from=build /app /app
            FROM scratch
            """
        let out = ImageBuildNetwork(Self.certs).instrument(dockerfile: dockerfile)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.filter { $0.hasPrefix("COPY bellocode-ca/ /etc/bellocode/certs/") }.count == 3, "three stages")
        #expect(lines[0] == "# syntax=docker/dockerfile:1", "parser directives stay first")
        let firstStage = lines.firstIndex { $0.hasPrefix("FROM --platform") }!
        #expect(lines[firstStage + 2].hasPrefix("COPY bellocode-ca/ /etc/bellocode/certs/"))
        #expect(lines.contains("echo FROM inside a heredoc"))
        #expect(lines[lines.firstIndex(of: "echo FROM inside a heredoc")! + 1] == "EOF", "nothing inserted inside the heredoc")
        let continued = lines.firstIndex { $0.contains("distroless") }!
        #expect(lines[continued + 2].hasPrefix("COPY bellocode-ca/"), "after the end of a continued FROM")
        #expect(lines.last?.hasPrefix("ENV SSL_CERT_FILE=/etc/bellocode/certs/ca-bundle.pem") == true, "FROM scratch too")
        #expect(out.contains("NODE_EXTRA_CA_CERTS=/etc/bellocode/certs/enterprise-roots.pem"))
        #expect(!out.contains("RUN update-ca"), "no RUN: a stage may have no shell")
        let stripped = lines.filter { !ImageBuildNetwork(Self.certs).stageLines(source: .context).contains($0) }
        #expect(stripped.joined(separator: "\n") == dockerfile, "only additions")
        #expect(ImageBuildNetwork(CorporateNetwork()).instrument(dockerfile: dockerfile) == dockerfile)
    }

    @Test func aNamedContextLeavesTheProjectsContextAlone() {
        let network = ImageBuildNetwork(Self.certs)
        let out = network.instrument(dockerfile: "FROM alpine\nRUN apk add curl", source: .namedContext)
        #expect(out.contains("COPY --from=bellocode-ca / /etc/bellocode/certs/"))
        #expect(out.contains("COPY --from=bellocode-ca /enterprise-roots.pem /usr/local/share/ca-certificates/bellocode-enterprise.crt"))
        #expect(network.cliArguments() == ["--build-context", "bellocode-ca=/Users/me/certs"])
    }

    @Test func contextEntriesCarryTheExportedBundles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bc-build-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("bundle".utf8).write(to: folder.appending(path: CorporateNetwork.bundleName))
        try Data("roots".utf8).write(to: folder.appending(path: CorporateNetwork.enterpriseName))
        let entries = try ImageBuildNetwork(CorporateNetwork(certificateDirectory: folder.path)).contextEntries()
        #expect(entries.map(\.path) == ["bellocode-ca", "bellocode-ca/ca-bundle.pem", "bellocode-ca/enterprise-roots.pem"])
        #expect(entries.last?.contents == Data("roots".utf8))
        #expect(try ImageBuildNetwork(CorporateNetwork()).contextEntries().isEmpty)
    }
}
