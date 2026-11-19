import CryptoKit
import Foundation

/// The one BelloCode-managed browser container (docs/features/shared-browser.md "Lifecycle"): its name, profile volume,
/// hardening and limits. Pure: `create()` builds the Engine API body and is unit-tested.
public struct BrowserContainerSpec: Sendable, Equatable {
    public static let containerName = "bellocode-browser"
    public static let profileVolume = "bellocode-browser-profile"
    public static let labelRole = "app.bellocode.browser-role"
    /// The egress scope key of the browser (its gateway is `bellocode-egress-gw-browser`).
    public static let scopeKey = "browser"
    /// Ports on the container's loopback.
    public static let viewerPort = 6080
    public static let relayPort = 19988

    public var image: String
    /// `seccomp=<json>`: Docker's default profile plus clone/unshare/setns/chroot (the reviewed delta).
    public var seccompProfile: String
    /// The internal egress network (`bellocode-egress-browser`); nil runs with no network at all (tests).
    public var network: String?
    /// Chromium's proxy (`http://bellocode-proxy:3128`) when on the egress network.
    public var proxy: String?
    /// Host folder with `enterprise-roots.pem` / `egress-ca.pem`, mounted read-only at /etc/bellocode/certs.
    public var certificateDirectory: String?
    public var volume: String
    public var name: String
    public var memoryBytes: Int64
    public var cpus: Double
    public var screen: (width: Int, height: Int)
    public var extraLabels: [String: String]

    public static func == (a: Self, b: Self) -> Bool {
        a.image == b.image && a.seccompProfile == b.seccompProfile && a.network == b.network && a.proxy == b.proxy
            && a.certificateDirectory == b.certificateDirectory && a.volume == b.volume && a.name == b.name
            && a.memoryBytes == b.memoryBytes && a.cpus == b.cpus && a.screen == b.screen && a.extraLabels == b.extraLabels
    }

    public init(image: String, seccompProfile: String, network: String? = nil, proxy: String? = nil, certificateDirectory: String? = nil,
                volume: String = Self.profileVolume, name: String = Self.containerName, memoryBytes: Int64 = 2 << 30, cpus: Double = 2,
                screen: (width: Int, height: Int) = (1280, 800), extraLabels: [String: String] = [:]) {
        self.image = image
        self.seccompProfile = seccompProfile
        self.network = network
        self.proxy = proxy
        self.certificateDirectory = certificateDirectory
        self.volume = volume
        self.name = name
        self.memoryBytes = memoryBytes
        self.cpus = cpus
        self.screen = screen
        self.extraLabels = extraLabels
    }

    public var labels: [String: String] {
        [BrowserImageContext.labelBrowser: "1", Self.labelRole: "browser", WorkspaceSpec.labelWorkspace: "1", "app.bellocode.config": configHash]
            .merging(extraLabels) { a, _ in a }
    }

    /// Identifies the configuration: a different image, network, proxy, certificates folder, limits or screen recreates
    /// the container (the profile volume stays).
    public var configHash: String {
        let text = [image, network ?? "-", proxy ?? "-", certificateDirectory ?? "-", volume, "\(memoryBytes)", "\(cpus)",
                    "\(screen.width)x\(screen.height)", String(seccompProfile.count)].joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public func create() -> ContainerCreate {
        var body = ContainerCreate(image: image)
        body.labels = labels
        body.env = ["BELLOCODE_SCREEN_W=\(screen.width)", "BELLOCODE_SCREEN_H=\(screen.height)"]
            + (proxy.map { ["BELLOCODE_PROXY=\($0)"] } ?? [])
        body.stopSignal = "SIGTERM"
        // Orderly stop: the entrypoint asks Chromium to quit (SIGINT commits the cookie store) and waits for it.
        body.stopTimeout = 30
        body.hostname = "bellocode-browser"
        var host = HostConfig()
        host.privileged = false
        host.readonlyRootfs = true
        host.capDrop = ["ALL"]
        host.securityOpt = ["no-new-privileges:true", "seccomp=\(seccompProfile)"]
        host.nanoCPUs = Int64(cpus * 1_000_000_000)
        host.memory = memoryBytes
        host.pidsLimit = 1024
        host.shmSize = 1 << 30
        // /tmp holds the NSS database (rebuilt each start), the X socket, the bounded HTTP cache and run state.
        host.tmpfs = ["/tmp": "rw,nosuid,nodev,size=512m"]
        var mounts = [Mount(type: .volume, source: volume, target: "/data")]
        if let certificateDirectory { mounts.append(Mount(type: .bind, source: certificateDirectory, target: "/etc/bellocode/certs", readOnly: true)) }
        host.mounts = mounts
        host.networkMode = network ?? "none"
        if network != nil { host.sysctls = ["net.ipv6.conf.all.disable_ipv6": "1"] }
        body.hostConfig = host
        if let network { body.networkingConfig = NetworkingConfig(endpointsConfig: [network: .init(aliases: ["bellocode-browser"])]) }
        return body
    }
}

/// `bellocode-browser-ctl status` (one JSON line).
public struct BrowserRuntimeStatus: Codable, Sendable, Equatable {
    public var sandbox: String
    public var relay: String
    public var `extension`: String
    public var paired: Bool
    public var caCount: Int
    public var chromiumRestarts: Int
    public var profileBytes: Int64
    public var downloadBytes: Int64
    public var cacheBytes: Int64
    public var extensionID: String
    public var chromium: String
    public var browse: String

    public init(sandbox: String = "pending", relay: String = "down", extension: String = "disconnected", paired: Bool = false,
                caCount: Int = 0, chromiumRestarts: Int = 0, profileBytes: Int64 = 0, downloadBytes: Int64 = 0, cacheBytes: Int64 = 0,
                extensionID: String = "", chromium: String = "", browse: String = "") {
        self.sandbox = sandbox
        self.relay = relay
        self.extension = `extension`
        self.paired = paired
        self.caCount = caCount
        self.chromiumRestarts = chromiumRestarts
        self.profileBytes = profileBytes
        self.downloadBytes = downloadBytes
        self.cacheBytes = cacheBytes
        self.extensionID = extensionID
        self.chromium = chromium
        self.browse = browse
    }

    public static func parse(_ text: String) -> BrowserRuntimeStatus? {
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("{") }) else { return nil }
        return try? JSONDecoder().decode(BrowserRuntimeStatus.self, from: Data(line.utf8))
    }

    public var isReady: Bool { sandbox == "ok" && relay == "up" && self.extension == "connected" }
}

/// One file in the browser's download folder (`bellocode-browser-ctl downloads`).
public struct BrowserDownload: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var name: String
    public var bytes: Int64
    public var mtime: Double
    public var id: String { name }

    public static func parseList(_ text: String) -> [BrowserDownload] {
        text.split(separator: "\n").compactMap { try? JSONDecoder().decode(BrowserDownload.self, from: Data($0.utf8)) }
            .sorted { $0.mtime > $1.mtime }
    }
}
