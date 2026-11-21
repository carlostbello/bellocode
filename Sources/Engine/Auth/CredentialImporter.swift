import Foundation
import OpenCodeKit
import Synchronization

/// An existing opencode install to import credentials from, with the user's explicit consent.
///
/// Uses opencode's supported mechanism: `opencode auth export --standalone` in the source install, piped straight
/// into `opencode auth import --server <BelloCode's server>`. The secrets travel only through a pipe between the two
/// opencode processes; BelloCode never reads, holds, logs or stores them.
///
/// The export runs the *source install's own* `opencode` binary (`executableURL`), so a different opencode version
/// never migrates the user's database. `--standalone` makes it read the data directory without starting or using the
/// user's background service.
public struct CredentialImportSource: Sendable, Hashable {
    /// The source install's `opencode` executable.
    public var executableURL: URL
    /// The environment the export runs with: `HOME` and, for a sandbox, the `XDG_*` directories.
    public var environment: [String: String]
    /// Shown to the user: where the credentials come from.
    public var displayName: String

    public init(executableURL: URL, environment: [String: String], displayName: String) {
        self.executableURL = executableURL
        self.environment = environment
        self.displayName = displayName
    }

    /// The user's own install (default `~/.local/share/opencode`), if an `opencode` executable is found in the usual
    /// places. Only for an explicit user action ("Import from opencode").
    public static func userInstall(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        candidates: [String]? = nil
    ) -> CredentialImportSource? {
        let paths = candidates ?? [
            home.appending(path: ".opencode/bin/opencode").path, "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode",
            home.appending(path: ".local/bin/opencode").path, home.appending(path: ".bun/bin/opencode").path,
        ]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return CredentialImportSource(
            executableURL: URL(filePath: path), environment: ["HOME": home.path], displayName: "opencode (\(path))")
    }

    /// An isolated install rooted at `root` (`config`, `data`, `state`, `cache`, `home` beneath it), as tests use.
    public static func sandbox(root: URL, executableURL: URL) -> CredentialImportSource {
        CredentialImportSource(
            executableURL: executableURL,
            environment: [
                "HOME": root.appending(path: "home").path, "XDG_CONFIG_HOME": root.appending(path: "config").path,
                "XDG_DATA_HOME": root.appending(path: "data").path, "XDG_STATE_HOME": root.appending(path: "state").path,
                "XDG_CACHE_HOME": root.appending(path: "cache").path,
            ],
            displayName: "sandbox")
    }
}

/// One credential the source install holds (non-secret: from `opencode auth list --format json`).
public struct ImportableCredential: Hashable, Sendable, Identifiable {
    public var id: String
    public var integrationID: String
    public var integrationName: String
    public var label: String
    public var method: String
}

public struct CredentialImportResult: Hashable, Sendable {
    public var imported: Int
    public var skipped: Int
}

/// Runs the export/import processes. Every process is owned by the calling task, killed on cancellation or after
/// `timeout`, and never outlives the call.
public struct CredentialImporter: Sendable {
    /// BelloCode's bundled opencode, used as the import client (same version as the server).
    public var bundledExecutableURL: URL
    public var timeout: Duration

    public init(bundledExecutableURL: URL, timeout: Duration = .seconds(60)) {
        self.bundledExecutableURL = bundledExecutableURL
        self.timeout = timeout
    }

    /// What would be imported, without secrets.
    public func preview(_ source: CredentialImportSource) async throws -> [ImportableCredential] {
        let output = try await ProcessRun.run(
            executable: source.executableURL, arguments: ["auth", "list", "--standalone", "--format", "json"],
            environment: Self.baseEnvironment.merging(source.environment) { $1 }, timeout: timeout)
        guard output.status == 0 else { throw EngineError.failed("opencode could not list its accounts (exit \(output.status)).") }
        struct Entry: Decodable {
            struct Connection: Decodable {
                var type: String
                var id: String?
                var label: String?
                var method: String?
            }

            var id: String
            var name: String
            var connections: [Connection]
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: output.stdout) else {
            throw EngineError.failed("opencode listed its accounts in an unexpected format.")
        }
        return entries.flatMap { entry in
            entry.connections.filter { $0.type == "credential" }.compactMap { connection in
                connection.id.map {
                    ImportableCredential(
                        id: $0, integrationID: entry.id, integrationName: entry.name, label: connection.label ?? entry.name,
                        method: connection.method ?? "key")
                }
            }
        }
    }

    /// Pipes `auth export` of `source` into `auth import` against `connection`. Credentials whose ID already exists
    /// are skipped by opencode (import is idempotent).
    public func run(_ source: CredentialImportSource, into connection: ServerConnection) async throws -> CredentialImportResult {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "bellocode-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // The import client gets an empty, throw-away data root and the per-launch server password; nothing else.
        let importEnvironment = Self.baseEnvironment.merging(CredentialImportSource.sandbox(root: scratch, executableURL: bundledExecutableURL).environment) { $1 }
            .merging(connection.credentials.clientEnvironment) { $1 }
        let result = try await ProcessRun.pipe(
            from: (source.executableURL, ["auth", "export", "--standalone"], Self.baseEnvironment.merging(source.environment) { $1 }),
            into: (bundledExecutableURL, ["auth", "import", "--server", connection.baseURL.absoluteString], importEnvironment),
            timeout: timeout)
        guard result.exportStatus == 0 else {
            throw EngineError.failed("opencode could not export its accounts (exit \(result.exportStatus)). Nothing was imported.")
        }
        guard result.importStatus == 0 else {
            let detail = String(decoding: result.importStdout + result.importStderr, as: UTF8.self)
            if detail.contains("rejected the password") { throw EngineError.failed("BelloCode's server refused the import.") }
            throw EngineError.failed("opencode could not import the accounts (exit \(result.importStatus)).")
        }
        // opencode prints the summary on stderr (2.3.0); only the counts are read.
        return Self.parse(String(decoding: result.importStdout + result.importStderr, as: UTF8.self))
    }

    /// Parses "Imported 2 credentials" / "Imported 0 credentials, skipped 2 already present".
    static func parse(_ text: String) -> CredentialImportResult {
        func count(after prefix: String) -> Int {
            guard let range = text.range(of: prefix + #" (\d+)"#, options: .regularExpression) else { return 0 }
            return Int(text[range].dropFirst(prefix.count + 1)) ?? 0
        }
        return CredentialImportResult(imported: count(after: "Imported"), skipped: count(after: "skipped"))
    }

    static let baseEnvironment: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "OPENCODE_DISABLE_AUTOUPDATE": "1", "OPENCODE_DISABLE_MODELS_FETCH": "1",
    ]
}

/// Minimal async process helpers: drained pipes, bounded output, termination on cancellation and timeout.
enum ProcessRun {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
    }

    struct PipeOutput: Sendable {
        var exportStatus: Int32
        var importStatus: Int32
        var importStdout: Data
        var importStderr: Data
    }

    /// Collects a pipe's output (bounded) on its own reader.
    final class Collector: Sendable {
        private let storage = Mutex(Data())
        private let limit: Int

        init(_ handle: FileHandle, limit: Int = 1 << 20) {
            self.limit = limit
            handle.readabilityHandler = { [self] handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                self.append(chunk)
            }
        }

        private func append(_ chunk: Data) {
            storage.withLock { data in
                if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
            }
        }

        /// Stops the handler without reading on (a failed or cancelled run; a leftover writer may hold the pipe).
        func abandon(_ handle: FileHandle) {
            handle.readabilityHandler = nil
        }

        /// Stops the handler and reads whatever is left. Call after the writer exited (the write end is closed).
        func finish(_ handle: FileHandle) -> Data {
            handle.readabilityHandler = nil
            if let rest = try? handle.readToEnd() { append(rest) }
            return storage.withLock { $0 }
        }
    }

    static func makeProcess(_ executable: URL, _ arguments: [String], _ environment: [String: String]) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        return process
    }

    static func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws -> Output {
        let process = makeProcess(executable, arguments, environment)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let collector = Collector(out.fileHandleForReading)
        let status: [Int32]
        do {
            status = try await wait(for: [process], timeout: timeout)
        } catch {
            collector.abandon(out.fileHandleForReading)
            throw error
        }
        return Output(status: status[0], stdout: collector.finish(out.fileHandleForReading))
    }

    static func pipe(
        from export: (URL, [String], [String: String]), into importer: (URL, [String], [String: String]), timeout: Duration
    ) async throws -> PipeOutput {
        let exporter = makeProcess(export.0, export.1, export.2)
        let importing = makeProcess(importer.0, importer.1, importer.2)
        let link = Pipe()
        let out = Pipe()
        let err = Pipe()
        exporter.standardOutput = link
        exporter.standardError = FileHandle.nullDevice
        exporter.standardInput = FileHandle.nullDevice
        importing.standardInput = link
        importing.standardOutput = out
        importing.standardError = err
        let stdout = Collector(out.fileHandleForReading, limit: 64 * 1024)
        let stderr = Collector(err.fileHandleForReading, limit: 64 * 1024)
        let statuses: [Int32]
        do {
            statuses = try await wait(for: [importing, exporter], timeout: timeout) { started in
                // Both processes hold their pipe ends now; close ours so the importer sees EOF when the exporter exits.
                if started { try? link.fileHandleForWriting.close() }
            }
        } catch {
            // Handlers removed and our pipe ends closed on every path (N18).
            stdout.abandon(out.fileHandleForReading)
            stderr.abandon(err.fileHandleForReading)
            try? link.fileHandleForWriting.close()
            try? link.fileHandleForReading.close()
            throw error
        }
        try? link.fileHandleForReading.close()
        return PipeOutput(
            exportStatus: statuses[1], importStatus: statuses[0], importStdout: stdout.finish(out.fileHandleForReading),
            importStderr: stderr.finish(err.fileHandleForReading))
    }

    /// Starts `processes` in order, waits for all to exit; terminates them on cancellation or timeout.
    static func wait(
        for processes: [Process], timeout: Duration, afterLaunch: (Bool) -> Void = { _ in }
    ) async throws -> [Int32] {
        let exits = processes.map { _ in OneShotExit() }
        for (process, exit) in zip(processes, exits) {
            process.terminationHandler = { exit.finish($0.terminationStatus) }
        }
        do {
            for process in processes { try process.run() }
            afterLaunch(true)
        } catch {
            afterLaunch(false)
            for process in processes where process.isRunning { process.terminate() }
            throw EngineError.failed("Could not start opencode (\(processes.first?.executableURL?.lastPathComponent ?? "")).")
        }
        let deadline = ContinuousClock.now + timeout
        do {
            var statuses: [Int32] = []
            for exit in exits {
                statuses.append(try await exit.value(until: deadline))
            }
            return statuses
        } catch {
            for process in processes where process.isRunning { process.terminate() }
            // The grace wait runs in a task of its own: the calling task may be cancelled already, and a wait inside it
            // would end at once (or, before N18, never), so SIGKILL is always reached after at most the grace.
            let grace = ContinuousClock.now + .seconds(3)
            await Task {
                for exit in exits { _ = try? await exit.value(until: grace) }
            }.value
            for process in processes where process.isRunning { kill(process.processIdentifier, SIGKILL) }
            if error is DeadlinePassed { throw EngineError.timedOut }
            throw error
        }
    }
}

struct DeadlinePassed: Error {}

/// A process exit status delivered once to one async waiter, with a deadline.
final class OneShotExit: Sendable {
    private let state = Mutex<(status: Int32?, waiter: CheckedContinuation<Int32, any Error>?)>((nil, nil))

    func finish(_ status: Int32) {
        let waiter = state.withLock { state -> CheckedContinuation<Int32, any Error>? in
            state.status = status
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: status)
    }

    func value(until deadline: ContinuousClock.Instant) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        // Cancellation checked under the lock: a cancel that fired before the waiter was stored (its
                        // handler found nothing to resume) must not leave this continuation waiting forever (N18).
                        let ready = self.state.withLock { state -> Result<Int32, any Error>? in
                            if let status = state.status { return .success(status) }
                            if Task.isCancelled { return .failure(CancellationError()) }
                            state.waiter = continuation
                            return nil
                        }
                        if let ready { continuation.resume(with: ready) }
                    }
                } onCancel: {
                    let waiter = self.state.withLock { state -> CheckedContinuation<Int32, any Error>? in
                        defer { state.waiter = nil }
                        return state.waiter
                    }
                    waiter?.resume(throwing: CancellationError())
                }
            }
            group.addTask {
                try await Task.sleep(until: deadline, clock: .continuous)
                throw DeadlinePassed()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}
