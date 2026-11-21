import Foundation
import Testing

@testable import ContainerKit

/// v1.0.0 review N18: the shared child-process runner completes on every path (TERM refused, cancellation, a leftover
/// process holding the pipe), drains and bounds its output, and only ever signals its own child.
@Suite("Child process runner", .timeLimit(.minutes(3)))
struct ChildProcessTests {
    static func shell(_ script: String, in directory: URL? = nil) -> Process {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["PATH": "/usr/bin:/bin"]
        if let directory { process.currentDirectoryURL = directory }
        return process
    }

    static let fast = ChildProcess.Options(timeout: .seconds(60), killGrace: .milliseconds(300), drainGrace: .milliseconds(300))

    @Test func outputIsDrainedAndTheNewestBytesAreKept() async throws {
        var options = Self.fast
        options.outputLimit = 1_000
        let result = try await ChildProcess.run(Self.shell("i=0; while [ $i -lt 2000 ]; do echo line $i; i=$((i+1)); done; echo err >&2"), options)
        #expect(result.status == 0)
        #expect(result.stdout.count <= 1_000)
        #expect(String(decoding: result.stdout, as: UTF8.self).hasSuffix("line 1999\n"), "the newest bytes are kept")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err\n")
    }

    @Test func aChildThatIgnoresTerminateIsKilledAtTheDeadline() async throws {
        var options = Self.fast
        options.timeout = .milliseconds(200)
        let result = try await ChildProcess.run(Self.shell("trap '' TERM; while :; do /bin/sleep 0.1; done"), options)
        #expect(result.timedOut)
        #expect(result.status != 0)
    }

    @Test func cancellationStopsTheChildAndThrows() async throws {
        let started = URL(filePath: NSTemporaryDirectory()).appending(path: "bc-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: started) }
        let task = Task { try await ChildProcess.run(Self.shell("trap '' TERM; touch '\(started.path)'; while :; do /bin/sleep 0.1; done"), Self.fast) }
        // Barrier: the child is running (it made the file), then cancel.
        while !FileManager.default.fileExists(atPath: started.path) { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func aLeftoverProcessHoldingThePipeDoesNotHoldTheRun() async throws {
        let base = URL(filePath: NSTemporaryDirectory()).appending(path: "bc-child-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // The leftover sleeps past the suite's time limit: without the bounded drain this run would never end in time.
        let result = try await ChildProcess.run(Self.shell("/bin/sleep 600 & echo $! > pid; echo done", in: base), Self.fast)
        #expect(result.status == 0 && String(decoding: result.stdout, as: UTF8.self) == "done\n")
        if let pid = Int32((try? String(contentsOf: base.appending(path: "pid"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
            kill(pid, SIGKILL)  // the leftover this test started
        }
    }

    @Test func aMissingExecutableFailsToLaunch() async {
        let process = Process()
        process.executableURL = URL(filePath: "/nonexistent/bellocode-child")
        await #expect(throws: ChildProcess.LaunchFailed.self) { _ = try await ChildProcess.run(process, Self.fast) }
    }
}
