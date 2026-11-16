// G5 spike: launches the pinned opencode with isolated XDG directories (as Sources/BelloCodeApp/SmokeTest.swift does).
// Never touches ~/.config/opencode or ~/.local/share/opencode. Every child is stopped before the spike exits.

import Darwin
import Foundation
import TerminalKit

struct SpikePaths {
    let root: URL                // package root (cwd)
    let reports: URL             // build/spikes/G5
    let snapshots: URL           // build/snapshots
    let opencode: URL

    init() {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        reports = root.appending(path: "build/spikes/G5")
        snapshots = root.appending(path: "build/snapshots")
        let version = (try? String(contentsOf: root.appending(path: "Scripts/opencode-version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "2.3.0"
        opencode = root.appending(path: "Vendor/opencode/\(version)/opencode")
    }
}

/// One opencode server child. `stdio` mode holds stdin open as the ownership lease (closing it stops the server);
/// `detached` mode starts a server in its own session so it outlives the spike process (restart experiments only).
@MainActor
final class SpikeServer {
    let endpoint: SpikeServerEndpoint
    let pid: pid_t
    let dataRoot: URL
    private let process: Process?
    private let stdin: Pipe?

    private init(endpoint: SpikeServerEndpoint, pid: pid_t, dataRoot: URL, process: Process?, stdin: Pipe?) {
        self.endpoint = endpoint
        self.pid = pid
        self.dataRoot = dataRoot
        self.process = process
        self.stdin = stdin
    }

    static func environment(dataRoot: URL, password: String, handoff: Data?) -> [String: String] {
        var env: [String: String] = [
            "HOME": dataRoot.appending(path: "home").path,
            "XDG_CONFIG_HOME": dataRoot.appending(path: "config").path,
            "XDG_DATA_HOME": dataRoot.appending(path: "data").path,
            "XDG_STATE_HOME": dataRoot.appending(path: "state").path,
            "XDG_CACHE_HOME": dataRoot.appending(path: "cache").path,
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "SHELL": SpikeShell.loginShell(),
            "LANG": "en_US.UTF-8",
            "OPENCODE_PASSWORD": password,
            "OPENCODE_CLIENT": "bellocode-g5-spike",
            "OPENCODE_DISABLE_AUTOUPDATE": "1",
            "OPENCODE_DISABLE_MODELS_FETCH": "1",
            "OPENCODE_DISABLE_CLAUDE_CODE": "1",
        ]
        if let handoff { env["OPENCODE_PTY_HANDOFF"] = String(decoding: handoff, as: UTF8.self) }
        return env
    }

    static func prepare(_ dataRoot: URL) throws {
        for name in ["config", "data", "state", "cache", "home"] {
            try FileManager.default.createDirectory(at: dataRoot.appending(path: name), withIntermediateDirectories: true)
        }
    }

    /// Starts `serve --stdio --port 0` and waits for readiness.
    static func startOwned(paths: SpikePaths, dataRoot: URL, password: String = randomPassword(), handoff: Data? = nil) async throws -> SpikeServer {
        try prepare(dataRoot)
        let process = Process()
        process.executableURL = paths.opencode
        process.arguments = ["serve", "--stdio", "--port", "0"]
        process.currentDirectoryURL = dataRoot
        process.environment = environment(dataRoot: dataRoot, password: password, handoff: handoff)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // Drain stderr for the child's whole life so it can never block on a full pipe.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        try process.run()
        let lineData = try await readLine(stdout.fileHandleForReading, timeout: 20)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        struct Ready: Decodable { let url: URL }
        let ready = try JSONDecoder().decode(Ready.self, from: lineData)
        let server = SpikeServer(
            endpoint: SpikeServerEndpoint(baseURL: ready.url, password: password), pid: process.processIdentifier,
            dataRoot: dataRoot, process: process, stdin: stdin
        )
        try await server.waitReady()
        return server
    }

    /// Starts a server in its own session on a fixed port; returns once ready. Used by the restart experiment.
    static func startDetached(paths: SpikePaths, dataRoot: URL, port: Int, password: String) async throws -> SpikeServer {
        try prepare(dataRoot)
        let log = dataRoot.appending(path: "server.log").path
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_addopen(&actions, 2, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_addchdir_np(&actions, dataRoot.path)
        let argv = [paths.opencode.path, "serve", "--hostname", "127.0.0.1", "--port", String(port)]
        let envp = environment(dataRoot: dataRoot, password: password, handoff: nil).map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = envp.map { strdup($0) } + [nil]
        let status = posix_spawn(&pid, argv[0], &actions, &attributes, cArgs, cEnv)
        cArgs.forEach { free($0) }
        cEnv.forEach { free($0) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
        guard status == 0 else { throw SpikeClientError2("posix_spawn failed \(status)") }
        let server = SpikeServer(
            endpoint: SpikeServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(port)/")!, password: password),
            pid: pid, dataRoot: dataRoot, process: nil, stdin: nil
        )
        try await server.waitReady()
        return server
    }

    /// Re-adopts a detached server started by an earlier spike process (pid verified to be our opencode binary).
    static func adopt(paths: SpikePaths, dataRoot: URL, port: Int, password: String, pid: pid_t) -> SpikeServer? {
        guard executablePath(of: pid) == paths.opencode.resolvingSymlinksInPath().path else { return nil }
        return SpikeServer(
            endpoint: SpikeServerEndpoint(baseURL: URL(string: "http://127.0.0.1:\(port)/")!, password: password),
            pid: pid, dataRoot: dataRoot, process: nil, stdin: nil
        )
    }

    var client: SpikePTYClient { SpikePTYClient(endpoint: endpoint) }

    /// The pty daemon this server spawned, from its registration file (only the pid field is read).
    func daemonPID() -> pid_t? {
        let ptyState = dataRoot.appending(path: "state/opencode/pty")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: ptyState, includingPropertiesForKeys: nil) else { return nil }
        for entry in entries {
            let file = entry.appending(path: "service.json")
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = object["pid"] as? Int, kill(pid_t(pid), 0) == 0 else { continue }
            return pid_t(pid)
        }
        return nil
    }

    func waitReady() async throws {
        let client = client
        for _ in 0..<100 {
            if (try? await client.serverPID()) != nil { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SpikeClientError2("server not ready")
    }

    /// Stops the server: close the stdin lease (owned) or SIGTERM (detached); SIGKILL after 3 s. Only our pid.
    func stop() async {
        if let stdin { try? stdin.fileHandleForWriting.close() } else { kill(pid, SIGTERM) }
        for _ in 0..<60 {
            if !isAlive(pid) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if isAlive(pid) { kill(pid, SIGKILL) }
        process?.waitUntilExit()
    }

    func isAlive(_ pid: pid_t) -> Bool {
        if let process { return process.isRunning }
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { return false }
        return kill(pid, 0) == 0
    }

    static func randomPassword() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<24).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64EncodedString()
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }

    nonisolated private static func readLine(_ handle: FileHandle, timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { throw SpikeClientError2("server closed stdout") }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: 0x0A) { return buffer[..<newline] }
        }
        throw SpikeClientError2("timed out waiting for the ready line")
    }
}

struct SpikeClientError2: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Lists processes whose command line contains `needle` (spike verification of orphans; never kills).
func spikeProcesses(matching needle: String) -> [String] {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-axo", "pid=,ppid=,pgid=,stat=,command="]
    let out = Pipe()
    ps.standardOutput = out
    try? ps.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    ps.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        .filter { $0.contains(needle) && !$0.contains("/bin/ps ") }
}
