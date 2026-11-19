import CryptoKit
import Foundation
import Security
import Synchronization
import os

private let signposter = OSSignposter(subsystem: "app.bellocode.ContainerKit", category: "browser-image")

/// The shared browser image's build context (`Containers/browser`, bundled as `Resources/browser-image`): its files,
/// the pinned versions, and the input hash that names the image (docs/features/shared-browser.md "Image and pinning").
/// Any change to a file, a pin or the extension key's public half changes the hash, so BelloCode builds a new image.
public struct BrowserImageContext: Sendable, Equatable {
    public static let repository = "bellocode-browser"
    public static let labelBrowser = "app.bellocode.browser"
    public static let labelInputs = "app.bellocode.browser-inputs"
    /// Files that make up the context (anything else in the folder is ignored and never sent to the daemon).
    public static let fileNames = ["Dockerfile", "entrypoint.sh", "ctl.sh", "browse-mcp", "policy.json", "view.html", "versions.env",
                                   "seccomp-chromium.json"]

    public var directory: URL
    public var files: [String: Data]
    /// `versions.env` as build arguments (comments and blank lines dropped).
    public var versions: [(key: String, value: String)]

    public static func == (a: Self, b: Self) -> Bool { a.directory == b.directory && a.files == b.files }

    public init(directory: URL) throws {
        self.directory = directory
        var files: [String: Data] = [:]
        for name in Self.fileNames {
            let url = directory.appending(path: name)
            guard let data = FileManager.default.contents(atPath: url.path) else {
                throw ContainerError.notFound("browser image file \(name) in \(directory.path)")
            }
            files[name] = data
        }
        self.files = files
        versions = Self.parseVersions(String(decoding: files["versions.env"] ?? Data(), as: UTF8.self))
    }

    public static func parseVersions(_ text: String) -> [(key: String, value: String)] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { return nil }
            let key = String(trimmed[..<eq]), value = String(trimmed[trimmed.index(after: eq)...])
            guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), !key.isEmpty else { return nil }
            return (key, value)
        }
    }

    public func version(_ key: String) -> String? { versions.first { $0.key == key }?.value }

    /// SHA-256 over every file (name and bytes, in a fixed order) and the extension ID (the key's public half; the
    /// private key never enters the hash).
    public func inputHash(extensionID: String) -> String {
        var hasher = SHA256()
        for name in Self.fileNames {
            hasher.update(data: Data(name.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: files[name] ?? Data())
            hasher.update(data: Data([0]))
        }
        hasher.update(data: Data(extensionID.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func tag(extensionID: String) -> String { "\(Self.repository):\(inputHash(extensionID: extensionID).prefix(16))" }

    /// The seccomp profile for `HostConfig.securityOpt` (`seccomp=<json>`, what the CLI sends for a file), compacted.
    public var seccompProfileJSON: String {
        guard let data = files["seccomp-chromium.json"], let object = try? JSONSerialization.jsonObject(with: data),
              let compact = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: compact, as: UTF8.self)
    }

    /// Whether this build may take the browser context from outside its own bundle (debug builds only, R18).
    public static var allowsDevelopmentSources: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// The context folder. A release build uses only the signed bundle's `Resources/browser-image` (nil when it is
    /// missing, which the browser reports visibly): no environment override and no search of the working directory, so
    /// a leftover development setting can never hand another Dockerfile the installation's packing key (R18). A debug
    /// build (`allowDevelopmentSources`) also honours `BELLOCODE_BROWSER_CONTEXT` and, failing the bundle, the nearest
    /// `Containers/browser` above the executable or the current directory.
    public static func locate(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment,
                              allowDevelopmentSources: Bool = allowsDevelopmentSources) -> URL? {
        let manager = FileManager.default
        func valid(_ url: URL) -> Bool { manager.fileExists(atPath: url.appending(path: "Dockerfile").path) }
        guard allowDevelopmentSources else {
            guard let resources = bundle.resourceURL?.appending(path: "browser-image").standardizedFileURL, valid(resources) else { return nil }
            return resources
        }
        if let path = environment["BELLOCODE_BROWSER_CONTEXT"], valid(URL(filePath: path)) { return URL(filePath: path) }
        if let resources = bundle.resourceURL?.appending(path: "browser-image"), valid(resources) { return resources }
        var starts = [URL(filePath: manager.currentDirectoryPath)]
        if let executable = bundle.executableURL { starts.append(executable.deletingLastPathComponent()) }
        for start in starts {
            var url = start
            for _ in 0..<8 {
                let candidate = url.appending(path: "Containers/browser")
                if valid(candidate) { return candidate }
                url.deleteLastPathComponent()
            }
        }
        return nil
    }
}

/// The installation's extension packing key: an RSA-2048 key BelloCode makes once and keeps in the Keychain. The CRX is
/// signed with it at build time (a BuildKit secret), so the extension ID stays the same across rebuilds and the profile
/// stays paired. Only the public half (the ID) is ever shown or hashed.
public enum BrowserExtensionKey {
    /// A new key as PKCS#8 PEM (`BEGIN PRIVATE KEY`, what `chromium --pack-extension-key` reads).
    public static func generatePEM() throws -> String {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048,
                                         kSecAttrIsPermanent as String: false]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let pkcs1 = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw ContainerError.decoding("could not create the extension key")
        }
        return pem(label: "PRIVATE KEY", der: DER.sequence([DER.integer(0), rsaAlgorithm, DER.octetString(pkcs1)]))
    }

    /// The extension ID Chromium derives from the key: SHA-256 of the SubjectPublicKeyInfo, first 16 bytes as hex
    /// mapped 0-9a-f → a-p.
    public static func extensionID(privateKeyPEM: String) throws -> String {
        let der = try privateKeyDER(pem: privateKeyPEM)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1(fromPKCS8: der) as CFData, attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(key),
              let publicPKCS1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw ContainerError.decoding("the stored extension key is not a valid RSA key")
        }
        return extensionID(subjectPublicKeyInfo: DER.sequence([rsaAlgorithm, DER.bitString(publicPKCS1)]))
    }

    public static func extensionID(subjectPublicKeyInfo: Data) -> String {
        let digest = SHA256.hash(data: subjectPublicKeyInfo).prefix(16)
        let letters = Array("abcdefghijklmnop")
        return digest.map { "\(letters[Int($0 >> 4)])\(letters[Int($0 & 0x0f)])" }.joined()
    }

    static let rsaAlgorithm = DER.sequence([DER.objectIdentifier([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]), DER.null])

    static func pem(label: String, der: Data) -> String {
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----\n"
    }

    static func privateKeyDER(pem: String) throws -> Data {
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else { throw ContainerError.decoding("the stored extension key is not PEM") }
        return der
    }

    /// PKCS#8 PrivateKeyInfo → the inner PKCS#1 key (the OCTET STRING after version and algorithm).
    static func pkcs1(fromPKCS8 der: Data) -> Data {
        var reader = DER.Reader(der)
        guard let outer = reader.next(), outer.tag == 0x30 else { return der }
        var inner = DER.Reader(outer.value)
        _ = inner.next()  // version
        _ = inner.next()  // algorithm
        guard let key = inner.next(), key.tag == 0x04 else { return der }
        return key.value
    }
}

/// Minimal DER (enough for RSA key wrappers).
enum DER {
    static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var n = count
        while n > 0 { bytes.insert(UInt8(n & 0xff), at: 0); n >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    static func tlv(_ tag: UInt8, _ value: Data) -> Data { Data([tag]) + length(value.count) + value }
    static func sequence(_ items: [Data]) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    static func integer(_ value: UInt8) -> Data { tlv(0x02, Data([value])) }
    static func octetString(_ data: Data) -> Data { tlv(0x04, data) }
    static func bitString(_ data: Data) -> Data { tlv(0x03, Data([0]) + data) }
    static func objectIdentifier(_ bytes: [UInt8]) -> Data { tlv(0x06, Data(bytes)) }
    static let null = Data([0x05, 0x00])

    struct Reader {
        let data: Data
        var offset: Int
        init(_ data: Data) { self.data = Data(data); offset = 0 }
        mutating func next() -> (tag: UInt8, value: Data)? {
            guard offset + 2 <= data.count else { return nil }
            let tag = data[offset]
            var length = Int(data[offset + 1])
            offset += 2
            if length & 0x80 != 0 {
                let n = length & 0x7f
                guard n <= 4, offset + n <= data.count else { return nil }
                length = data[offset..<offset + n].reduce(0) { $0 << 8 | Int($1) }
                offset += n
            }
            guard offset + length <= data.count else { return nil }
            defer { offset += length }
            return (tag, data.subdata(in: offset..<offset + length))
        }
    }
}

/// Builds the image with Rancher Desktop's `docker buildx build --load` (images are built locally by policy): argv only,
/// a minimal environment, Rancher's socket, BelloCode's own `DOCKER_CONFIG`. The packing key reaches BuildKit as a secret
/// from this child's environment (`--secret id=extkey,env=…`): never a file, argv, a layer or a log.
public struct BrowserImageBuilder: Sendable {
    public let docker: URL
    public let socketPath: String
    public let configDirectory: URL

    public init(docker: URL, socketPath: String, configDirectory: URL) {
        self.docker = docker
        self.socketPath = socketPath
        self.configDirectory = configDirectory
    }

    /// `~/.rd/bin/docker` when it is executable.
    public static func rancherDocker(home: String = NSHomeDirectory()) -> URL? {
        let url = URL(filePath: home).appending(path: ".rd/bin/docker")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    public struct Result: Sendable, Equatable {
        public var tag: String
        public var status: Int32
        public var seconds: Double
        /// The last lines of output (BuildKit's plain progress; never contains the key).
        public var tail: String
        public var succeeded: Bool { status == 0 }
    }

    public static let keyVariable = "BELLOCODE_BROWSER_EXTENSION_KEY"

    /// The argv for one build (pure; tested).
    public static func arguments(context: BrowserImageContext, tag: String, inputHash: String, extensionID: String, extraLabels: [String: String] = [:]) -> [String] {
        var arguments = ["buildx", "build", "--load", "--progress=plain", "--tag", tag, "--file", context.directory.appending(path: "Dockerfile").path]
        for (key, value) in context.versions { arguments += ["--build-arg", "\(key)=\(value)"] }
        arguments += ["--build-arg", "EXTENSION_ID=\(extensionID)"]
        arguments += ["--secret", "id=extkey,env=\(keyVariable)"]
        let labels = [BrowserImageContext.labelBrowser: "1", BrowserImageContext.labelInputs: inputHash].merging(extraLabels) { a, _ in a }
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) { arguments += ["--label", "\(key)=\(value)"] }
        return arguments + [context.directory.path]
    }

    /// Runs the build to completion (or cancellation). Off the main actor. `progress` receives output lines, bounded.
    @concurrent
    public func build(context: BrowserImageContext, keyPEM: String, extraLabels: [String: String] = [:],
                      progress: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        let state = signposter.beginInterval("build")
        defer { signposter.endInterval("build", state) }
        let extensionID = try BrowserExtensionKey.extensionID(privateKeyPEM: keyPEM)
        let hash = context.inputHash(extensionID: extensionID)
        let tag = context.tag(extensionID: extensionID)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = configDirectory.appending(path: "config.json")
        if !FileManager.default.fileExists(atPath: config.path) { try Data("{}\n".utf8).write(to: config) }
        try ComposeCLI.linkBuildx(beside: docker, into: configDirectory)
        let process = Process()
        process.executableURL = docker
        process.arguments = Self.arguments(context: context, tag: tag, inputHash: hash, extensionID: extensionID, extraLabels: extraLabels)
        process.environment = [
            "PATH": docker.deletingLastPathComponent().path + ":/usr/bin:/bin", "HOME": NSHomeDirectory(),
            "DOCKER_HOST": "unix://" + socketPath, "DOCKER_CONFIG": configDirectory.path, "BUILDKIT_PROGRESS": "plain",
            Self.keyVariable: keyPEM,
        ]
        process.currentDirectoryURL = context.directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let tail = Mutex(Data())
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            tail.withLock { buffer in
                buffer.append(data)
                if buffer.count > 32_768 { buffer = buffer.suffix(16_384) }
            }
            if let progress { for line in String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(4) { progress(String(line.prefix(300))) } }
        }
        let start = ContinuousClock.now
        let status: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(returning: 127)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        let elapsed = ContinuousClock.now - start
        let text = String(decoding: tail.withLock { $0 }, as: UTF8.self)
        let lines = text.split(separator: "\n").suffix(6).joined(separator: "\n")
        return Result(tag: tag, status: status, seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                      tail: String(lines.prefix(1_500)))
    }
}
