import Darwin

/// Process resource limits set once at launch.
public enum ProcessLimits {
    /// The open-file soft limit the app asks for: launchd starts a GUI app at 256, which a deep folder walk (two
    /// descriptors per level while a dev-container context is copied, GV06), the server's pipes, sockets and the
    /// terminal can approach. Never above the hard limit, never lowered.
    public static let openFiles: rlim_t = 8192

    /// Raises the soft `RLIMIT_NOFILE` towards `target` (capped by the hard limit and `OPEN_MAX`). Returns the soft
    /// limit in effect afterwards.
    @discardableResult
    public static func raiseOpenFileLimit(to target: rlim_t = openFiles) -> rlim_t {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 0 }
        let wanted = min(target, limit.rlim_max, rlim_t(OPEN_MAX))
        guard wanted > limit.rlim_cur else { return limit.rlim_cur }
        var raised = limit
        raised.rlim_cur = wanted
        guard setrlimit(RLIMIT_NOFILE, &raised) == 0 else { return limit.rlim_cur }
        return wanted
    }
}
