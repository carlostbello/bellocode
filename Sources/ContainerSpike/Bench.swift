import ContainerKit
import CoreServices
import Darwin
import Foundation
import Synchronization

/// Measurements for the G6 report. Host baselines run the same commands with the Mac's own /bin/sh, git and grep (the
/// developer's machine still has them; a locked-down one would not, which is the point of the container).
@MainActor
enum Bench {
    struct Report: Codable {
        var machine: [String: String] = [:]
        var coldStart: [String: Stats] = [:]
        var execRoundTrip: [String: Stats] = [:]
        var ttyEcho: [String: Stats] = [:]
        var throughput: [String: Double] = [:]
        var fileIO: [String: [String: Double]] = [:]
        var visibility: [String: Double] = [:]
        var watchers: [String: String] = [:]
        var cancellation: [String: String] = [:]
        var concurrency: [String: Double] = [:]
        var sharing: [String: String] = [:]
        var ownership: [String: String] = [:]
    }

    static var report = Report()

    static func run(project: String) async throws {
        let fm = FileManager.default
        try? fm.removeItem(atPath: project)
        try fm.createDirectory(atPath: project, withIntermediateDirectories: true)
        try await Spike.ensureImage()
        let client = Spike.client
        let info = try await client.info()
        report.machine = [
            "host": "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.processorCount) CPUs",
            "engine": "Docker \(info.serverVersion ?? "?") in Rancher Desktop VM (\(info.operatingSystem ?? "?"), \(info.ncpu ?? 0) vCPU, \(String(format: "%.1f", Double(info.memTotal ?? 0) / 1e9)) GB, vz + virtiofs)",
        ]
        let spec = Spike.spec(project: project, ports: [])
        let manager = WorkspaceManager(client: client)

        // 1. Cold start with the image present: create + start + prepare $HOME + first exec.
        var cold: [Double] = [], warm: [Double] = []
        for _ in 0..<5 {
            try await manager.remove(spec, caches: false)
            let start = ContinuousClock.now
            let id = try await manager.ensureRunning(spec, pull: false)
            _ = try await ExecSession.run(client: client, container: id, argv: ["true"], wrap: false)
            cold.append(ms(start))
            try await client.stopContainer(id, timeout: 1)
            let restart = ContinuousClock.now
            _ = try await manager.ensureRunning(spec, pull: false)
            _ = try await ExecSession.run(client: client, container: id, argv: ["true"], wrap: false)
            warm.append(ms(restart))
        }
        report.coldStart = ["createStartFirstExec": Stats(cold), "startStoppedFirstExec": Stats(warm)]
        log("cold start p50 \(Stats(cold).p50) ms")
        let container = try await manager.ensureRunning(spec, pull: false)
        let config = project + "/../bench-exec.json"
        try Spike.writeHelperConfig(spec, container: container, to: config)
        let helper = FileManager.default.currentDirectoryPath + "/.build/release/bellocode-exec"
        let helperDebug = FileManager.default.currentDirectoryPath + "/.build/debug/bellocode-exec"
        let helperPath = fm.isExecutableFile(atPath: helper) ? helper : helperDebug
        let helperEnv = ["BELLOCODE_EXEC_CONFIG": config, "TERM": "dumb"]

        // 2. Exec round trip, 200 runs each.
        var api: [Double] = [], wrapped: [Double] = [], viaHelper: [Double] = [], hostShell: [Double] = []
        for _ in 0..<200 {
            var start = ContinuousClock.now
            _ = try await ExecSession.run(client: client, container: container, argv: ["true"], wrap: false)
            api.append(ms(start))
            start = ContinuousClock.now
            _ = try await ExecSession.run(client: client, container: container, argv: ["/bin/sh", "-c", "true"])
            wrapped.append(ms(start))
            start = ContinuousClock.now
            try host(helperPath, ["-c", "true"], cwd: project, environment: helperEnv)
            viaHelper.append(ms(start))
            start = ContinuousClock.now
            try host("/bin/sh", ["-c", "true"], cwd: project)
            hostShell.append(ms(start))
        }
        report.execRoundTrip = [
            "engineExec_true": Stats(api), "engineExec_wrapped_sh": Stats(wrapped),
            "bellocodeExec_process_-c_true": Stats(viaHelper), "host_/bin/sh_-c_true": Stats(hostShell),
        ]
        log("exec p50 api \(Stats(api).p50) helper \(Stats(viaHelper).p50) host \(Stats(hostShell).p50)")

        // 3. Keystroke → echo through an exec TTY (cat in a terminal: the line discipline echoes).
        report.ttyEcho["containerExecTTY"] = try await ttyEcho(client: client, container: container)
        report.ttyEcho["hostPTY_script_cat"] = try hostTTYEcho()

        // 4. Throughput of large output.
        let seq = "seq 1 2000000"
        var start = ContinuousClock.now
        let seqResult = try await ExecSession.run(client: client, container: container, argv: ["sh", "-c", seq], wrap: false, limit: 64)
        report.throughput["engineExec_nonTTY_ms"] = ms(start)
        start = ContinuousClock.now
        let ttySession = try await ExecSession.start(client: client, container: container, argv: ["sh", "-c", seq], workingDir: nil,
                                                     environment: [:], tty: true, size: (40, 120))
        var ttyBytes = 0
        for try await chunk in ttySession.output() { ttyBytes += chunk.bytes.count }
        report.throughput["engineExec_TTY_ms"] = ms(start)
        start = ContinuousClock.now
        let (_, helperOut, _) = try host(helperPath, ["-c", seq], cwd: project, environment: helperEnv)
        report.throughput["bellocodeExec_ms"] = ms(start)
        start = ContinuousClock.now
        let (_, hostOut, _) = try host("/usr/bin/seq", ["1", "2000000"])
        report.throughput["host_seq_ms"] = ms(start)
        report.throughput["bytes"] = Double(hostOut.count)
        report.throughput["bellocodeExec_bytes_match"] = helperOut.count == hostOut.count ? 1 : 0
        report.throughput["tty_bytes"] = Double(ttyBytes)
        _ = seqResult

        // 5. File I/O over the bind mount versus the host, same tree (a local clone of opencode 2.3.0, ~11k files).
        let source = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ""
        if !source.isEmpty {
            try host("/usr/bin/git", ["clone", "-q", "--no-hardlinks", source, project + "/seed"])
            report.fileIO = try await fileIO(client: client, container: container, project: project)
        }

        // 6. Change visibility and watchers.
        try await visibility(client: client, container: container, project: project)

        // 7. Cancellation latency and leftovers.
        try await cancellation(client: client, container: container)

        // 8. Concurrency: 20 execs at once.
        start = ContinuousClock.now
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let result = try await ExecSession.run(client: client, container: container, argv: ["/bin/sh", "-c", "sleep 0.5; echo \(index)"])
                    return String(decoding: result.stdout, as: UTF8.self) == "\(index)\n" && result.exitCode == 0 ? 1 : 0
                }
            }
            var total = 0
            for try await value in group { total += value }
            return total
        }
        report.concurrency["20_execs_sleep_0.5_wall_ms"] = ms(start)
        report.concurrency["20_execs_correct"] = Double(results)
        start = ContinuousClock.now
        let helperOK = await concurrentHelpers(helperPath: helperPath, project: project, helperEnv: helperEnv)
        report.concurrency["20_helpers_sleep_0.5_wall_ms"] = ms(start)
        report.concurrency["20_helpers_correct"] = Double(helperOK)

        // 9. Which host paths can be mounted, and ownership as seen from the host.
        try await sharing(client: client, container: container, project: project)

        try writeReport("measurements", report)
    }

    static func ttyEcho(client: EngineClient, container: String) async throws -> Stats {
        let session = try await ExecSession.start(client: client, container: container, argv: ["cat"], workingDir: nil,
                                                  environment: [:], tty: true, size: (24, 80))
        defer { session.close() }
        let received = Mutex(Data())
        let reader = Task {
            for try await chunk in session.output() { received.withLock { $0.append(chunk.bytes) } }
        }
        try await Task.sleep(for: .milliseconds(200))
        var samples: [Double] = []
        for index in 0..<200 {
            let byte = UInt8(ascii: "a") + UInt8(index % 26)
            let before = received.withLock { $0.count }
            let start = ContinuousClock.now
            try await session.write(Data([byte]))
            while received.withLock({ $0.count }) <= before {
                if ms(start) > 2000 { break }
                await Task.yield()
            }
            samples.append(ms(start))
            try await Task.sleep(for: .milliseconds(5))
        }
        try await session.write(Data([0x04, 0x04]))
        reader.cancel()
        return Stats(samples)
    }

    /// Host baseline: `script` gives `cat` a pseudo-terminal on the Mac.
    static func hostTTYEcho() throws -> Stats {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/cat"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let fd = output.fileHandleForReading.fileDescriptor
        var samples: [Double] = []
        usleep(200_000)
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Drain anything printed at start.
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while poll(&pfd, 1, 50) > 0 { _ = read(fd, &buffer, buffer.count) }
        for index in 0..<200 {
            let start = ContinuousClock.now
            input.fileHandleForWriting.write(Data([UInt8(ascii: "a") + UInt8(index % 26)]))
            pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 2000) > 0 { _ = read(fd, &buffer, buffer.count) }
            samples.append(ms(start))
            usleep(5000)
        }
        process.terminate()
        return Stats(samples)
    }

    static func fileIO(client: EngineClient, container: String, project: String) async throws -> [String: [String: Double]] {
        // {W} and {M} are per-side directories so the two runs never share state.
        let steps: [(String, String)] = [
            ("git_clone_local_11k_files", "git clone -q --no-hardlinks seed {W}"),
            ("git_status_first", "cd {W} && git status --porcelain | wc -l"),
            ("git_status_again", "cd {W} && git status --porcelain | wc -l"),
            ("grep_recursive_ts", "grep -r -I -c 'Effect.gen' {W} --include='*.ts' | wc -l"),
            ("create_10000_small_files", "mkdir {M} && cd {M} && i=0; while [ $i -lt 10000 ]; do echo $i > f$i; i=$((i+1)); done"),
            ("delete_10000_small_files", "rm -rf {M}"),
            ("remove_clone", "rm -rf {W}"),
        ]
        var results: [String: [String: Double]] = [:]
        for (name, template) in steps {
            let containerCommand = template.replacingOccurrences(of: "{W}", with: "work-c").replacingOccurrences(of: "{M}", with: "many-c")
            let hostCommand = template.replacingOccurrences(of: "{W}", with: "work-h").replacingOccurrences(of: "{M}", with: "many-h")
                .replacingOccurrences(of: "grep ", with: "/usr/bin/grep ")
            var start = ContinuousClock.now
            let inContainer = try await ExecSession.run(client: client, container: container, argv: ["/bin/bash", "-c", containerCommand],
                                                        workingDir: project, limit: 4096)
            let containerMs = ms(start)
            start = ContinuousClock.now
            let (status, _, _) = try host("/bin/sh", ["-c", hostCommand], cwd: project)
            let hostMs = ms(start)
            results[name] = ["container_ms": containerMs, "host_ms": hostMs, "ratio": containerMs / max(hostMs, 0.001),
                             "container_exit": Double(inContainer.exitCode), "host_exit": Double(status)]
            log("\(name): container \(Int(containerMs)) ms (exit \(inContainer.exitCode)), host \(Int(hostMs)) ms (exit \(status))")
        }
        return results
    }

    static func visibility(client: EngineClient, container: String, project: String) async throws {
        let dir = project + "/watch"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Host write → container sees it (poll from inside).
        var samples: [Double] = []
        for index in 0..<10 {
            let name = "h\(index)"
            let poller = Task {
                try await ExecSession.run(client: client, container: container,
                                          argv: ["/bin/sh", "-c", "while [ ! -f \(dir)/\(name) ]; do :; done; echo seen"], limit: 64)
            }
            try await Task.sleep(for: .milliseconds(150))
            let start = ContinuousClock.now
            try Data("x".utf8).write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
            _ = try await poller.value
            samples.append(ms(start))
        }
        report.visibility["host_write_seen_in_container_p50_ms_incl_exec_end"] = Stats(samples).p50

        // Container write → host sees it.
        samples = []
        for index in 0..<10 {
            let path = "\(dir)/c\(index)"
            let start = ContinuousClock.now
            let writer = Task { try await ExecSession.run(client: client, container: container, argv: ["/bin/sh", "-c", "echo x > \(path)"], wrap: false) }
            while !FileManager.default.fileExists(atPath: path) { await Task.yield() }
            samples.append(ms(start))
            _ = try await writer.value
        }
        report.visibility["container_write_seen_on_host_p50_ms_incl_exec_start"] = Stats(samples).p50

        // inotify in the container for host edits.
        let watcher = try await ExecSession.start(client: client, container: container,
                                                  argv: ["inotifywait", "-m", "-q", "-e", "create,modify,delete", dir], workingDir: nil,
                                                  environment: [:], tty: false)
        let events = Mutex(Data())
        let reader = Task { for try await chunk in watcher.output() where chunk.stream == .stdout { events.withLock { $0.append(chunk.bytes) } } }
        try await Task.sleep(for: .milliseconds(500))
        try Data("1".utf8).write(to: URL(fileURLWithPath: dir + "/host-created"))
        try Data("2".utf8).write(to: URL(fileURLWithPath: dir + "/host-created"))
        try FileManager.default.removeItem(atPath: dir + "/host-created")
        try await Task.sleep(for: .seconds(2))
        _ = try await ExecSession.run(client: client, container: container, argv: ["/bin/sh", "-c", "echo y > \(dir)/container-created"], wrap: false)
        try await Task.sleep(for: .seconds(1))
        let seen = events.withLock { String(decoding: $0, as: UTF8.self) }
        report.watchers["inotify_in_container_for_host_writes"] = seen.contains("host-created") ? "events delivered" : "NO events (\(seen.isEmpty ? "none" : "other only"))"
        report.watchers["inotify_in_container_for_container_writes"] = seen.contains("container-created") ? "events delivered" : "NO events"
        watcher.close()
        reader.cancel()
        _ = try await ExecSession.run(client: client, container: container, argv: ["pkill", "-f", "inotifywait"], wrap: false)

        // FSEvents on the host for container edits.
        let latency = try await fsEventsLatency(dir: dir, client: client, container: container)
        report.watchers["fsevents_on_host_for_container_writes"] = latency.map { String(format: "events delivered (%.0f ms incl. exec)", $0) } ?? "NO events within 3 s"
    }

    nonisolated static func concurrentHelpers(helperPath: String, project: String, helperEnv: [String: String]) async -> Int {
        // Real processes, each on its own thread (blocking waits must not occupy the cooperative pool).
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            let ok = Mutex(0)
            let group = DispatchGroup()
            for index in 0..<20 {
                group.enter()
                Thread {
                    if let (status, out, _) = try? host(helperPath, ["-c", "sleep 0.5; echo \(index)"], cwd: project, environment: helperEnv),
                       status == 0, String(decoding: out, as: UTF8.self) == "\(index)\n" { ok.withLock { $0 += 1 } }
                    group.leave()
                }.start()
            }
            group.notify(queue: .global()) { continuation.resume(returning: ok.withLock { $0 }) }
        }
    }

    /// Nonisolated: the FSEvents callback runs on its own queue (a main-actor closure here would trap in Swift 6).
    nonisolated static func fsEventsLatency(dir: String, client: EngineClient, container: String) async throws -> Double? {
        let fsBox = FSBox()
        let box = Unmanaged.passRetained(fsBox)
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            let box = Unmanaged<FSBox>.fromOpaque(info!).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            for index in 0..<count { if let path = array[index] as? String { box.paths.withLock { $0.append(path) } } }
        }
        let stream = FSEventStreamCreate(nil, callback, &context, [dir] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05,
                                         UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))!
        let queue = DispatchQueue(label: "fsevents")
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        try await Task.sleep(for: .milliseconds(300))
        let start = ContinuousClock.now
        _ = try await ExecSession.run(client: client, container: container, argv: ["/bin/sh", "-c", "echo z > \(dir)/from-container"], wrap: false)
        var latency: Double?
        while ms(start) < 3000 {
            if fsBox.paths.withLock({ $0.contains { $0.hasSuffix("from-container") } }) { latency = ms(start); break }
            try await Task.sleep(for: .milliseconds(5))
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        box.release()
        return latency
    }

    nonisolated final class FSBox: Sendable {
        let paths = Mutex<[String]>([])
    }

    static func cancellation(client: EngineClient, container: String) async throws {
        let session = try await ExecSession.start(client: client, container: container,
                                                  argv: ExecWrapper.nonInteractive(["/bin/bash", "-c", "sleep 300 & (sleep 301 &); trap '' TERM; sleep 302"]),
                                                  workingDir: nil, environment: [:], tty: false)
        try await Task.sleep(for: .milliseconds(500))
        let start = ContinuousClock.now
        session.closeStdin()
        for try await _ in session.output() {}
        let code = try await session.exitCode()
        report.cancellation["stream_end_after_cancel_ms"] = String(format: "%.0f", ms(start))
        report.cancellation["exit_code"] = String(code)
        try await Task.sleep(for: .milliseconds(2300))
        let left = try await ExecSession.run(client: client, container: container, argv: ["/bin/sh", "-c", "ps -eo args | grep -c '^sleep 30[0-2]' || true"], wrap: false)
        report.cancellation["processes_left_after_2.3_s (bg job, double-forked, TERM-ignoring parent)"] =
            String(decoding: left.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let escaped = try await ExecSession.start(client: client, container: container,
                                                  argv: ExecWrapper.nonInteractive(["/bin/bash", "-c", "setsid sleep 303 & sleep 304"]),
                                                  workingDir: nil, environment: [:], tty: false)
        try await Task.sleep(for: .milliseconds(300))
        escaped.closeStdin()
        for try await _ in escaped.output() {}
        try await Task.sleep(for: .milliseconds(2300))
        let leftSetsid = try await ExecSession.run(client: client, container: container, argv: ["/bin/sh", "-c", "ps -eo args | grep -c '^sleep 30[34]' || true"], wrap: false)
        report.cancellation["processes_left_when_command_uses_setsid"] = String(decoding: leftSetsid.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await ExecSession.run(client: client, container: container, argv: ["pkill", "-f", "sleep 30"], wrap: false)
    }

    static func sharing(client: EngineClient, container: String, project: String) async throws {
        // Ownership: files created in the container as the mapped user and as root, seen from the host.
        _ = try await ExecSession.run(client: client, container: container, argv: ["/bin/sh", "-c", "echo u > \(project)/as-user"])
        _ = try await ExecSession.run(client: client, container: container, argv: ["/bin/sh", "-c", "echo r > \(project)/as-root; chmod 600 \(project)/as-root"], user: "0:0")
        for name in ["as-user", "as-root"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: "\(project)/\(name)")
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue ?? -1
            let readable = FileManager.default.isReadableFile(atPath: "\(project)/\(name)")
            report.ownership[name] = "host uid \(owner), group \((attributes[.groupOwnerAccountID] as? NSNumber)?.intValue ?? -1), mode \(String((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0, radix: 8)), host can read: \(readable)"
        }
        // Host file with mode 600 read inside the container as the mapped user.
        try Data("secret-ish".utf8).write(to: URL(fileURLWithPath: project + "/host-600"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: project + "/host-600")
        let read = try await ExecSession.run(client: client, container: container, argv: ["cat", project + "/host-600"], wrap: false)
        report.ownership["host_0600_file_read_in_container_as_mapped_uid"] = read.exitCode == 0 ? "readable" : "denied"

        // Paths: which host locations a bind mount can see. A path outside Rancher's shared locations is resolved
        // inside the VM (wrong files or an error), so BelloCode must validate before creating.
        let candidates = [
            ("home", NSHomeDirectory() + "/.bellocode-g6-spike"),
            ("private_tmp", "/private/tmp"),
            ("var_folders", NSTemporaryDirectory()),
            ("Library_not_shared", "/Library/Developer"),
            ("usr_share_not_shared", "/usr/share/man"),
        ]
        for (name, path) in candidates {
            var body = ContainerCreate(image: Spike.imageTag)
            body.entrypoint = ["sh", "-c"]
            body.cmd = ["ls \(path) | head -3 | wc -l"]
            body.labels = Spike.label
            var host = HostConfig()
            host.mounts = [Mount(type: .bind, source: path, target: "/probe", readOnly: true)]
            body.hostConfig = host
            body.cmd = ["ls /probe | wc -l"]
            do {
                let id = try await client.createContainer(name: nil, body)
                try await client.startContainer(id)
                _ = try await client.waitContainer(id)
                var output = Data()
                for try await chunk in try await client.logs(id, follow: false) { output.append(chunk.bytes) }
                let hostCount = (try? FileManager.default.contentsOfDirectory(atPath: path).count) ?? -1
                report.sharing[name] = "\(path): container sees \(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) entries, host has \(hostCount)"
                try await client.removeContainer(id, force: true)
            } catch {
                report.sharing[name] = "\(path): \(error)"
            }
        }
    }
}
