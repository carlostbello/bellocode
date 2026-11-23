import Darwin
import Testing

@testable import BelloCore

/// GV06: the app raises its open-file soft limit at launch (launchd starts it at 256).
@Suite("Process limits")
struct ProcessLimitsTests {
    @Test func theOpenFileLimitIsRaisedNeverLowered() {
        var before = rlimit()
        #expect(getrlimit(RLIMIT_NOFILE, &before) == 0)
        let now = ProcessLimits.raiseOpenFileLimit()
        var after = rlimit()
        #expect(getrlimit(RLIMIT_NOFILE, &after) == 0)
        #expect(after.rlim_cur == now)
        #expect(after.rlim_cur >= before.rlim_cur, "never lowered")
        #expect(after.rlim_cur >= min(ProcessLimits.openFiles, after.rlim_max, rlim_t(OPEN_MAX)))
    }
}
