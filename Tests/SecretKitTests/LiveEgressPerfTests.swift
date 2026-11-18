import BelloCore
import ContainerKit
import Foundation
import Testing

@testable import SecretKit

/// Package installs through the egress proxy versus direct (docs/features/secrets.md "Performance"):
/// `BELLOCODE_SECRET_PERF=1 swift test --filter LiveEgressPerf`. Real registries (npm, PyPI) over the Mac's network;
/// fresh caches each time. Writes `build/secrets-perf.md`. Everything is labelled `app.bellocode.test=secrets` and removed.
@Suite("Live egress performance", .serialized, .timeLimit(.minutes(15)),
       .enabled(if: ProcessInfo.processInfo.environment["BELLOCODE_SECRET_PERF"] == "1", "set BELLOCODE_SECRET_PERF=1"))
struct LiveEgressPerfTests {
    let client = EngineClient(socketPath: NSHomeDirectory() + "/.rd/docker.sock")
    static let npm = "cd $(mktemp -d) && npm init -y >/dev/null && npm install --no-audit --no-fund --loglevel=error --cache $(mktemp -d) express@4 lodash@4 typescript@5 react@18 >/dev/null && echo npm-ok"
    static let pip = "python3 -m venv /tmp/v$$ && /tmp/v$$/bin/pip install -q --no-cache-dir --disable-pip-version-check requests flask pydantic && echo pip-ok"

    func timed(_ label: String, _ body: () async throws -> String) async throws -> (String, Double, String) {
        let start = ContinuousClock.now
        let output = try await body()
        let elapsed = ContinuousClock.now - start
        return (label, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, output)
    }

    @Test func installsThroughTheProxy() async throws {
        let image = LiveEgressTests.image
        let scopeKey = "p" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
        let root = NSHomeDirectory() + "/Library/Caches/BelloCode/tests/egress-\(scopeKey)"
        let certs = root + "-certs"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: certs, withIntermediateDirectories: true)
        let proxyCA = try CertificateAuthority(commonName: "Perf egress CA")
        let proxy = EgressProxy(authority: proxyCA)
        let port = try await proxy.start()
        let token = UUID().uuidString
        proxy.setScopes([EgressScope(id: scopeKey, token: token) { _ in true }])
        let gateway = EgressGateway(client: client)
        var spec = WorkspaceSpec(projectRoot: root, image: image, extraLabels: LiveEgressTests.labels)
        let manager = WorkspaceManager(client: client)
        var rows: [(String, Double, String)] = []
        do {
            try await gateway.ensure(EgressGatewaySpec(scopeKey: scopeKey, image: image, proxyPort: Int(port), token: token, extraLabels: LiveEgressTests.labels))
            let anchors = KeychainSystemAnchors.pem()
            try Data((anchors + proxyCA.pem).utf8).write(to: URL(fileURLWithPath: certs + "/" + CorporateNetwork.bundleName))
            try Data(proxyCA.pem.utf8).write(to: URL(fileURLWithPath: certs + "/" + CorporateNetwork.enterpriseName))
            spec.egress = EgressAttachment(network: EgressGateway.networkName(scopeKey), caFingerprint: proxyCA.fingerprint)
            spec.corporateNetwork = CorporateNetwork(certificateDirectory: certs, certificateFingerprint: proxyCA.fingerprint)
            let container = try await manager.ensureRunning(spec, pull: false)
            for (label, script) in [("npm install (4 packages, cold cache)", Self.npm), ("pip install (3 packages, no cache)", Self.pip)] {
                rows.append(try await timed("\(label), direct") { try await dockerRun(image, script) })
                rows.append(try await timed("\(label), through the proxy") {
                    let result = try await ExecSession.run(client: client, container: container, argv: ["/bin/bash", "-c", script],
                                                           workingDir: "/tmp", user: spec.user, timeout: .seconds(600))
                    return String(decoding: result.stdout + result.stderr, as: UTF8.self)
                })
            }
        } catch {
            await cleanup(spec, gateway: gateway, scopeKey: scopeKey, root: root, certs: certs, proxy: proxy)
            throw error
        }
        await cleanup(spec, gateway: gateway, scopeKey: scopeKey, root: root, certs: certs, proxy: proxy)
        for row in rows { #expect(row.2.contains("-ok"), "\(row.0): \(row.2.suffix(400))") }
        var lines = ["| Install | Seconds |", "| --- | --- |"]
        for row in rows { lines.append("| \(row.0) | \(String(format: "%.1f", row.1)) |") }
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: directory.appending(path: "secrets-perf.md"))
    }

    func cleanup(_ spec: WorkspaceSpec, gateway: EgressGateway, scopeKey: String, root: String, certs: String, proxy: EgressProxy) async {
        let manager = WorkspaceManager(client: client)
        if let storage = try? await manager.storage(projectKey: spec.projectKey) { try? await manager.purge(storage) }
        await gateway.remove(scopeKey: scopeKey, network: true)
        proxy.stop()
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: certs)
    }

    /// `docker run --rm` on the default bridge (direct egress), labelled.
    func dockerRun(_ image: String, _ script: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "run", "--rm", "--label", "app.bellocode.test=secrets", image, "/bin/bash", "-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// The Mac's built-in roots as PEM (the containers' full bundle in production comes from the same source).
enum KeychainSystemAnchors {
    static func pem() -> String {
        var anchors: CFArray?
        guard SecTrustCopyAnchorCertificates(&anchors) == errSecSuccess, let list = anchors as? [SecCertificate] else { return "" }
        return list.map { CertificateAuthority.pem(SecCertificateCopyData($0) as Data) }.joined()
    }
}
