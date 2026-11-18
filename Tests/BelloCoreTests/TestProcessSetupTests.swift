import Darwin
import Foundation
import Testing
import TestProcessSetup

/// Every test bundle links `TestProcessSetup` (Tests/Support), which ignores SIGPIPE when the bundle loads: a write to
/// a closed pipe or socket must fail with EPIPE, not kill the test process with signal 13.
@Suite("Test process setup")
struct TestProcessSetupTests {
    @Test func sigpipeIsIgnoredWhenTheBundleLoads() throws {
        #expect(bellocode_test_process_setup_ran() == 1, "the bundle's load-time setup ran")
        // A write to a pipe with no reader reports EPIPE and the process lives on.
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        close(fds[0])
        defer { close(fds[1]) }
        let written = write(fds[1], "x", 1)
        #expect(written == -1 && errno == EPIPE)
    }

    /// Each test target in the manifest depends on the setup target (a new test target must add it too).
    @Test func everyTestTargetLinksTheSetup() throws {
        let manifest = try String(contentsOf: TimerGuardTests.packageRoot.appending(path: "Package.swift"), encoding: .utf8)
        let testTargets = manifest.components(separatedBy: ".testTarget(").dropFirst()
        #expect(!testTargets.isEmpty)
        for target in testTargets {
            let declaration = target.components(separatedBy: "swiftSettings:").first ?? target
            #expect(declaration.contains("\"TestProcessSetup\""), "a test target without TestProcessSetup: \(declaration.prefix(120))")
        }
    }
}
