import ContainerKit
import Foundation
import Synchronization

enum Spike {
    static let socket = NSHomeDirectory() + "/.rd/docker.sock"
    static let client = EngineClient(socketPath: socket)
    static let label = ["bellocode.spike": "1"]
    static let imageTag = "bellocode-spike-workspace:g6"
    static let baseImage = "node:22-bookworm-slim"

    static let dockerfile = """
    FROM \(baseImage)
    RUN apt-get update \\
     && apt-get install -y --no-install-recommends python3 git procps vim-tiny less ca-certificates inotify-tools \\
     && rm -rf /var/lib/apt/lists/*
    LABEL bellocode.spike=1
    """

    static func spec(project: String, extra: [String] = [], ports: [Int] = [8090]) -> WorkspaceSpec {
        WorkspaceSpec(projectRoot: project, extraMounts: extra, image: imageTag, publishedPorts: ports,
                      caches: ["npm": WorkspaceSpec.home + "/.npm"], extraLabels: label)
    }

    static func ensureImage() async throws {
        if try await client.inspectImage(imageTag) != nil { return }
        if try await client.inspectImage(baseImage) == nil {
            log("pulling \(baseImage)")
            try await client.pullImage(baseImage)
        }
        var tar = TarArchive()
        tar.add("Dockerfile", dockerfile)
        log("building \(imageTag) through POST /build")
        let start = Date()
        let id = try await client.buildImage(context: tar.data(), tag: imageTag, labels: label) { message in
            if let stream = message.stream, stream.hasPrefix("Step") { log("  " + stream.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        log("built \(id ?? "?") in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
    }

    /// Writes the helper's config for `spec` and returns its path.
    static func writeHelperConfig(_ spec: WorkspaceSpec, container: String, to path: String) throws {
        let config = ExecHelperConfig(socket: socket, workspaces: [
            .init(roots: [spec.projectRoot] + spec.extraMounts, container: container, user: spec.user, shell: "/bin/bash"),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: URL(fileURLWithPath: path))
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Runs a host process and returns (status, stdout). Used only for host baselines and for driving the helper.
@discardableResult
func host(_ launchPath: String, _ arguments: [String], cwd: String? = nil, environment: [String: String]? = nil,
          stdin: Data? = nil) throws -> (Int32, Data, Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    if let environment { process.environment = environment }
    let out = Pipe(), err = Pipe(), input = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = stdin == nil ? FileHandle.nullDevice : input
    try process.run()
    if let stdin {
        input.fileHandleForWriting.write(stdin)
        try? input.fileHandleForWriting.close()
    }
    let errTask = DispatchQueue.global()
    let errBox = Mutex(Data())
    let group = DispatchGroup()
    group.enter()
    errTask.async {
        let data = err.fileHandleForReading.readDataToEndOfFile()
        errBox.withLock { $0 = data }
        group.leave()
    }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    process.waitUntilExit()
    return (process.terminationStatus, outData, errBox.withLock { $0 })
}

struct Stats: Codable {
    var n: Int
    var p50: Double
    var p95: Double
    var min: Double
    var max: Double
    var mean: Double

    init(_ samples: [Double]) {
        let sorted = samples.sorted()
        n = sorted.count
        func q(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[Swift.min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))] }
        p50 = q(0.5)
        p95 = q(0.95)
        min = sorted.first ?? 0
        max = sorted.last ?? 0
        mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
    }
}

func ms(_ start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

func writeReport(_ name: String, _ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let dir = FileManager.default.currentDirectoryPath + "/docs/spikes/G6"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try encoder.encode(value).write(to: URL(fileURLWithPath: dir + "/\(name).json"))
    log("wrote docs/spikes/G6/\(name).json")
}
