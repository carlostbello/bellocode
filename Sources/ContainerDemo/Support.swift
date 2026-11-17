import ContainerKit
import Foundation
import Synchronization

struct DemoError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

enum Demo {
    static let socket = NSHomeDirectory() + "/.rd/docker.sock"
    static let client = EngineClient(socketPath: socket)
    /// Every resource the harness creates carries this label; `cleanup` removes them.
    static let label = ["app.bellocode.test": "1"]

    static func cleanup() async throws {
        for container in try await client.listContainers(labels: ["app.bellocode.test=1"]) {
            try await client.removeContainer(container.id, force: true, volumes: true)
            log("removed container \(container.name)")
        }
        for volume in try await client.listVolumes(labels: ["app.bellocode.test=1"]) {
            try await client.removeVolume(volume, force: true)
            log("removed volume \(volume)")
        }
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Runs a host process and returns (status, stdout, stderr). Host baselines and the helper only.
@discardableResult
func host(_ launchPath: String, _ arguments: [String], cwd: String? = nil, environment: [String: String]? = nil) throws -> (Int32, Data, Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    if let environment { process.environment = environment }
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let errBox = Mutex(Data())
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
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
    var max: Double

    init(_ samples: [Double]) {
        let sorted = samples.sorted()
        n = sorted.count
        func q(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[Swift.min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))] }
        p50 = (q(0.5) * 10).rounded() / 10
        p95 = (q(0.95) * 10).rounded() / 10
        max = ((sorted.last ?? 0) * 10).rounded() / 10
    }
}

func ms(_ start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
