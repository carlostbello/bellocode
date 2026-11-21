import Foundation
import Testing

@testable import Engine

/// v1.0.0 review N18: the credential importer's process runner never deadlocks on cancellation, even when the child
/// ignores SIGTERM (it is killed after the grace), and a timed-out child is killed too.
@Suite("Credential importer process runner", .timeLimit(.minutes(3)))
struct ProcessRunCancellationTests {
    static let stubborn = ["-c", "trap '' TERM; touch \"$0\"; while :; do /bin/sleep 0.1; done"]

    @Test func cancellingAChildThatIgnoresTerminateCompletes() async throws {
        let marker = URL(filePath: NSTemporaryDirectory()).appending(path: "bc-processrun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try await ProcessRun.run(
                executable: URL(filePath: "/bin/sh"), arguments: Self.stubborn + [marker.path], environment: ["PATH": "/usr/bin:/bin"],
                timeout: .seconds(120))
        }
        while !FileManager.default.fileExists(atPath: marker.path) { await Task.yield() }
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
    }

    @Test func aTimedOutChildThatIgnoresTerminateIsKilled() async throws {
        let marker = URL(filePath: NSTemporaryDirectory()).appending(path: "bc-processrun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        await #expect(throws: EngineError.timedOut) {
            _ = try await ProcessRun.run(
                executable: URL(filePath: "/bin/sh"), arguments: Self.stubborn + [marker.path], environment: ["PATH": "/usr/bin:/bin"],
                timeout: .milliseconds(300))
        }
    }
}
