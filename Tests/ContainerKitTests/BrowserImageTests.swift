import Foundation
import Testing

@testable import ContainerKit

/// The shared browser image (docs/features/shared-browser.md "Image and pinning"): input hash, extension identity,
/// build arguments (the key never in argv) and the hardened container body.
@Suite("Shared browser image")
struct BrowserImageTests {
    static let repoContext = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Containers/browser")

    func copyContext() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bc-browser-ctx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.copyItem(at: Self.repoContext, to: dir)
        return dir
    }

    @Test func contextLoadsWithPinsAndEveryFile() throws {
        let context = try BrowserImageContext(directory: Self.repoContext)
        #expect(context.files.count == BrowserImageContext.fileNames.count)
        #expect(context.version("BROWSE_VERSION") == "0.1.5")
        #expect(context.version("CHROMIUM_VERSION")?.hasPrefix("156.") == true)
        #expect(context.version("BASE_IMAGE")?.contains("@sha256:") == true, "the base is digest-pinned")
        for key in ["CHROMIUM_SHA256", "BROWSE_TGZ_SHA256", "BROWSE_EXT_SHA256", "NOVNC_SHA256"] {
            #expect(context.version(key)?.count == 64, "\(key) is a SHA-256")
        }
        #expect(context.seccompProfileJSON.contains("\"unshare\""))
    }

    @Test func inputHashChangesWithAnyInputAndTheKeyButIsStable() throws {
        let dir = try copyContext()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try BrowserImageContext(directory: dir)
        let id = "abcdefghijklmnopabcdefghijklmnop"
        #expect(a.inputHash(extensionID: id) == (try BrowserImageContext(directory: dir)).inputHash(extensionID: id))
        #expect(a.inputHash(extensionID: id) != a.inputHash(extensionID: "ponmlkjihgfedcbaponmlkjihgfedcba"))
        try (String(contentsOf: dir.appending(path: "policy.json"), encoding: .utf8) + " ").write(to: dir.appending(path: "policy.json"), atomically: true, encoding: .utf8)
        let b = try BrowserImageContext(directory: dir)
        #expect(a.inputHash(extensionID: id) != b.inputHash(extensionID: id))
        #expect(b.tag(extensionID: id).hasPrefix("bellocode-browser:"))
        #expect(b.tag(extensionID: id).count == "bellocode-browser:".count + 16)
    }

    @Test func missingFileIsReported() throws {
        let dir = try copyContext()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.removeItem(at: dir.appending(path: "ctl.sh"))
        #expect(throws: ContainerError.self) { try BrowserImageContext(directory: dir) }
    }

    /// Chromium's ID algorithm on a known key: browse's published manifest key gives its published unpacked ID.
    @Test func extensionIDMatchesChromiumsDerivation() throws {
        let spki = Data(base64Encoded: "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAjWdgsBDUPCHO2u5bq3/Us1sLm+kiehLZBL0HIu3stwivGW+bgCDsD8KAEMFJcY04u3iudffTeEGdEe8pQfL7BSNRvyslszmvJrsoP7bVUKXrnRTw3CUsRjnwbqMoMElwegiCFUXPnqQ9ZeA2NGEhmWMyDXqqZxOo0z2q66GTgz9McbXOBK2QXYBPjUWxud814wSrE1lIQ2G58nQVeZenI3/PXZ4f1SACn6SdkiCR44NZwz89I1ISxftongLDED/1dlnivqJBzAtN1s2i+jWplLtOmLJJkh1LQ2jP3gWvYY1zT2RHJIw874SSrrhFt4Hguvo/L0Ge7ixvGp5tDAP2wwIDAQAB")!
        #expect(BrowserExtensionKey.extensionID(subjectPublicKeyInfo: spki) == "afeafocngkodbmaipcngoamamfmekgfo")
    }

    @Test func generatedKeyIsPKCS8AndGivesAStableID() throws {
        let pem = try BrowserExtensionKey.generatePEM()
        #expect(pem.hasPrefix("-----BEGIN PRIVATE KEY-----\n"))
        let id = try BrowserExtensionKey.extensionID(privateKeyPEM: pem)
        #expect(id.count == 32 && id.allSatisfy { ("a"..."p").contains($0) })
        #expect(try BrowserExtensionKey.extensionID(privateKeyPEM: pem) == id)
        #expect(try BrowserExtensionKey.extensionID(privateKeyPEM: try BrowserExtensionKey.generatePEM()) != id)
    }

    @Test func buildArgumentsCarryPinsAndASecretReferenceButNoKey() throws {
        let context = try BrowserImageContext(directory: Self.repoContext)
        let args = BrowserImageBuilder.arguments(context: context, tag: "bellocode-browser:x", inputHash: "h", extensionID: "abcdefghijklmnopabcdefghijklmnop")
        #expect(args.starts(with: ["buildx", "build", "--load"]))
        #expect(args.contains("id=extkey,env=\(BrowserImageBuilder.keyVariable)"))
        #expect(args.contains("BROWSE_VERSION=0.1.5"))
        #expect(args.contains("EXTENSION_ID=abcdefghijklmnopabcdefghijklmnop"), "the cached pack step is tied to the key's public ID")
        #expect(args.contains("app.bellocode.browser-inputs=h"))
        #expect(!args.joined().contains("PRIVATE KEY"))
        #expect(args.last == context.directory.path)
    }

    @Test func containerIsHardenedAndHoldsNothingButItsProfile() {
        let spec = BrowserContainerSpec(image: "bellocode-browser:x", seccompProfile: "{\"x\":1}", network: "bellocode-egress-browser",
                                        proxy: "http://bellocode-proxy:3128", certificateDirectory: "/tmp/certs")
        let body = spec.create()
        let host = body.hostConfig!
        #expect(host.capDrop == ["ALL"])
        #expect(host.capAdd == nil)
        #expect(host.privileged == false)
        #expect(host.readonlyRootfs == true)
        #expect(host.securityOpt == ["no-new-privileges:true", "seccomp={\"x\":1}"])
        #expect(host.portBindings == nil && body.exposedPorts == nil, "nothing published")
        #expect(host.networkMode == "bellocode-egress-browser")
        #expect(host.mounts?.count == 2)
        #expect(host.mounts?.contains { $0.target == "/data" && $0.source == BrowserContainerSpec.profileVolume } == true)
        #expect(host.mounts?.contains { $0.target == "/etc/bellocode/certs" && $0.readOnly == true } == true)
        #expect(host.mounts?.contains { ($0.source ?? "").contains("docker.sock") } == false)
        #expect(host.tmpfs?["/tmp"] != nil)
        #expect(body.env?.contains("BELLOCODE_PROXY=http://bellocode-proxy:3128") == true)
        #expect(body.stopTimeout == 30, "the orderly stop gets time to commit cookies")
        #expect(body.labels?[BrowserImageContext.labelBrowser] == "1")
        var other = spec
        other.image = "bellocode-browser:y"
        #expect(other.configHash != spec.configHash)
        let offline = BrowserContainerSpec(image: "i", seccompProfile: "{}").create()
        #expect(offline.hostConfig?.networkMode == "none")
    }

    @Test func statusAndDownloadsParse() {
        let line = #"{"sandbox":"ok","relay":"up","extension":"connected","paired":true,"caCount":2,"chromiumRestarts":0,"profileBytes":8182905,"downloadBytes":4096,"cacheBytes":2152629,"extensionID":"edmgncelohfohgbnndopcehdehmeoblj","chromium":"Chromium 156","browse":"0.1.5"}"#
        let status = BrowserRuntimeStatus.parse("noise\n" + line + "\n")
        #expect(status?.isReady == true)
        #expect(status?.caCount == 2)
        #expect(BrowserRuntimeStatus.parse("not json") == nil)
        let list = BrowserDownload.parseList(#"{"name":"a.pdf","bytes":10,"mtime":1}"# + "\n" + #"{"name":"b.zip","bytes":20,"mtime":5}"#)
        #expect(list.map(\.name) == ["b.zip", "a.pdf"])
    }

    @Test func contextIsLocatedFromTheEnvironment() {
        let found = BrowserImageContext.locate(
            bundle: .main, environment: ["BELLOCODE_BROWSER_CONTEXT": Self.repoContext.path], allowDevelopmentSources: true)
        #expect(found?.path == Self.repoContext.path)
    }

    /// R29: the image is arm64 only; an amd64 engine is refused with a clear message before any build.
    @Test func onlyArm64EnginesBuildTheImage() {
        #expect(BrowserImageContext.architectureRefusal(engineArch: "aarch64") == nil)
        #expect(BrowserImageContext.architectureRefusal(engineArch: "arm64") == nil)
        let refusal = BrowserImageContext.architectureRefusal(engineArch: "x86_64")
        #expect(refusal?.contains("arm64 only") == true)
        #expect(BrowserImageContext.architectureRefusal(engineArch: "amd64") != nil)
    }

    /// R18: a release build never takes the context from the environment or the working directory (the test runs
    /// inside the repository, whose `Containers/browser` a development search would find); only the bundle counts.
    @Test func releaseBuildsUseOnlyTheBundledContext() throws {
        #expect(BrowserImageContext.locate(bundle: .main, environment: ["BELLOCODE_BROWSER_CONTEXT": Self.repoContext.path],
                                           allowDevelopmentSources: false) == nil)
        #expect(BrowserImageContext.locate(bundle: .main, environment: [:], allowDevelopmentSources: true) != nil)
        // A bundle that carries the context: release takes exactly that folder.
        let root = FileManager.default.temporaryDirectory.appending(path: "bc-bundle-\(UUID().uuidString)/Test.app")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let resources = root.appending(path: "Contents/Resources/browser-image")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("FROM scratch\n".utf8).write(to: resources.appending(path: "Dockerfile"))
        try Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>t.t</string></dict></plist>".utf8)
            .write(to: root.appending(path: "Contents/Info.plist"))
        let bundle = try #require(Bundle(url: root))
        let found = BrowserImageContext.locate(bundle: bundle, environment: ["BELLOCODE_BROWSER_CONTEXT": Self.repoContext.path],
                                               allowDevelopmentSources: false)
        #expect(found?.resolvingSymlinksInPath().path == resources.resolvingSymlinksInPath().path)
    }
}
