import Foundation
import Synchronization

/// Runs one child process to completion with the guarantees every BelloCode subprocess helper needs (N18):
/// - both pipes are drained as data arrives, each bounded (the newest bytes kept), and a read handler is removed at
///   EOF (an EOF handler left installed re-fires at full CPU on macOS);
/// - a deadline or the calling task's cancellation sends SIGTERM, then SIGKILL to our own child if it has not exited
///   after `killGrace`, and completion does not wait for an unkillable child past a second grace;
/// - once the child exited, pipes still held open by a process it left behind are drained for at most `drainGrace`;
/// - nothing blocks a thread (no `readDataToEndOfFile`, no `waitUntilExit`); every timer sleeps on `ContinuousClock`.
///
/// Only the child launched here is signalled, and only while it has not been reaped.
public enum ChildProcess {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data
        /// Stopped because the deadline passed.
        public var timedOut: Bool
    }

    public struct LaunchFailed: Error, Sendable {}

    public struct Options: Sendable {
        public var timeout: Duration
        /// Bytes kept per stream (the newest).
        public var outputLimit: Int
        /// Standard error goes to the same buffer as standard output.
        public var mergeOutput: Bool
        public var killGrace: Duration
        public var drainGrace: Duration
        /// Written to standard input (then closed) off the calling task; nil: /dev/null.
        public var input: Data?

        public init(
            timeout: Duration, outputLimit: Int = 1 << 20, mergeOutput: Bool = false, killGrace: Duration = .seconds(3),
            drainGrace: Duration = .seconds(1), input: Data? = nil
        ) {
            self.timeout = timeout
            self.outputLimit = outputLimit
            self.mergeOutput = mergeOutput
            self.killGrace = killGrace
            self.drainGrace = drainGrace
            self.input = input
        }
    }

    /// Runs `process` (executable, arguments, environment and directory already set; its standard streams are set
    /// here). Throws `CancellationError` when the calling task was cancelled (after the child was stopped) and
    /// `LaunchFailed` when it could not start. `onOutput` sees each chunk as it arrives (any thread).
    public static func run(
        _ process: Process, _ options: Options, onOutput: (@Sendable (Data) -> Void)? = nil
    ) async throws -> Result {
        let out = Pipe()
        let err = options.mergeOutput ? out : Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdin = options.input.map { _ in Pipe() }
        if let stdin { _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) }
        process.standardInput = stdin ?? FileHandle.nullDevice
        let run = Run(process: process, limit: options.outputLimit, merged: options.mergeOutput, options: options)
        let readers = options.mergeOutput ? [out.fileHandleForReading] : [out.fileHandleForReading, err.fileHandleForReading]
        run.readers = readers
        defer { run.finish() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, any Error>) in
                run.setContinuation(continuation)
                for (index, reader) in readers.enumerated() {
                    reader.readabilityHandler = { handle in
                        let data = handle.availableData
                        if data.isEmpty { handle.readabilityHandler = nil }
                        if !data.isEmpty { onOutput?(data) }
                        run.append(data, stream: index)
                    }
                }
                process.terminationHandler = { process in run.terminated(process.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    for reader in readers { reader.readabilityHandler = nil }
                    run.fail(LaunchFailed())
                    return
                }
                run.launched()
                if let stdin, let input = options.input {
                    let writer = stdin.fileHandleForWriting
                    DispatchQueue.global(qos: .utility).async {
                        try? writer.write(contentsOf: input)
                        try? writer.close()
                    }
                }
            }
        } onCancel: {
            run.cancel()
        }
    }

    /// The state of one run. Every transition happens under the lock; continuations resume outside it.
    final class Run: Sendable {
        struct State {
            var buffers = [Data(), Data()]
            var done = [false, false]
            var status: Int32?
            var timedOut = false
            var cancelled = false
            var launched = false
            var stopping = false
            var finished = false
            var continuation: CheckedContinuation<Result, any Error>?
            var readers: [FileHandle] = []
            var timers: [Task<Void, Never>] = []
        }

        let process: Process
        let limit: Int
        let options: Options
        let state: Mutex<State>

        init(process: Process, limit: Int, merged: Bool, options: Options) {
            self.process = process
            self.limit = limit
            self.options = options
            var initial = State()
            if merged { initial.done[1] = true }
            state = Mutex(initial)
        }

        var readers: [FileHandle] {
            get { state.withLock { $0.readers } }
            set { state.withLock { $0.readers = newValue } }
        }

        func setContinuation(_ continuation: CheckedContinuation<Result, any Error>) {
            state.withLock { $0.continuation = continuation }
        }

        private func after(_ delay: Duration, _ action: @escaping @Sendable () -> Void) {
            let task = Task {
                do { try await Task.sleep(for: delay, clock: .continuous) } catch { return }
                action()
            }
            state.withLock { $0.timers.append(task) }
        }

        func launched() {
            let cancelled = state.withLock { state -> Bool in
                state.launched = true
                return state.cancelled
            }
            if cancelled { stop() } else {
                after(options.timeout) { [self] in
                    let stop = state.withLock { state -> Bool in
                        guard !state.finished, state.status == nil else { return false }
                        state.timedOut = true
                        return true
                    }
                    if stop { self.stop() }
                }
            }
        }

        func append(_ data: Data, stream: Int) {
            let resume = state.withLock { state -> Resume? in
                if data.isEmpty {
                    state.done[stream] = true
                } else {
                    state.buffers[stream].append(data)
                    if state.buffers[stream].count > limit * 2 { state.buffers[stream] = state.buffers[stream].suffix(limit) }
                }
                return completion(&state)
            }
            resume?()
        }

        func terminated(_ status: Int32) {
            let (resume, waiting) = state.withLock { state -> (Resume?, Bool) in
                state.status = status
                let resume = completion(&state)
                return (resume, resume == nil && !state.finished)
            }
            resume?()
            if waiting {
                // A process the child left behind may hold a pipe open: stop waiting for EOF after a grace.
                after(options.drainGrace) { [self] in forceComplete(status: nil) }
            }
        }

        func fail(_ error: any Error) {
            let continuation = state.withLock { state -> CheckedContinuation<Result, any Error>? in
                guard !state.finished else { return nil }
                state.finished = true
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume(throwing: error)
        }

        func cancel() {
            let launched = state.withLock { state -> Bool in
                state.cancelled = true
                return state.launched
            }
            if launched { stop() }
        }

        /// SIGTERM now; SIGKILL after `killGrace` if our child is still running; completion after another grace.
        func stop() {
            let first = state.withLock { state -> Bool in
                guard !state.stopping, !state.finished, state.status == nil else { return false }
                state.stopping = true
                return true
            }
            guard first else { return }
            if process.isRunning { process.terminate() }
            after(options.killGrace) { [self] in
                let pid = state.withLock { $0.status == nil && process.isRunning ? process.processIdentifier : 0 }
                if pid > 0 { kill(pid, SIGKILL) }
                after(options.killGrace) { [self] in forceComplete(status: -1) }
            }
        }

        private func forceComplete(status: Int32?) {
            let resume = state.withLock { state -> Resume? in
                if state.status == nil, let status { state.status = status }
                state.done = [true, true]
                return completion(&state)
            }
            clearReaders()
            resume?()
        }

        private func clearReaders() {
            // Clearing a handler cancels its read source; the descriptor closes with the pipe (closing it here could
            // race a handler already inside `availableData`).
            for reader in readers { reader.readabilityHandler = nil }
        }

        func finish() {
            let timers = state.withLock { state -> [Task<Void, Never>] in
                defer { state.timers = [] }
                return state.timers
            }
            for timer in timers { timer.cancel() }
            clearReaders()
        }

        typealias Resume = () -> Void

        private func completion(_ state: inout State) -> Resume? {
            guard !state.finished, state.done[0], state.done[1], let status = state.status, let continuation = state.continuation else {
                return nil
            }
            state.finished = true
            state.continuation = nil
            let limit = self.limit
            let result: Swift.Result<Result, any Error> = state.cancelled
                ? .failure(CancellationError())
                : .success(Result(
                    status: status, stdout: Data(state.buffers[0].suffix(limit)), stderr: Data(state.buffers[1].suffix(limit)),
                    timedOut: state.timedOut))
            return { continuation.resume(with: result) }
        }
    }
}
