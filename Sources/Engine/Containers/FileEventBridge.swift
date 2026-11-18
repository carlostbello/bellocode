import BelloCore
import CoreServices
import Foundation
import Synchronization
import os

/// Bridges host file changes into a workspace container's inotify (docs/features/containers.md). Rancher Desktop's
/// file sharing does not deliver inotify events for edits made on the Mac (the agent's file tools, the user's editor),
/// so hot reload and test watchers in the container would never fire. This watches the workspace folders with
/// FSEvents (file-level), batches changed paths, and hands each batch to `sink`, which touches them inside the
/// container without changing them (`ContainerProbes.touchScript`).
///
/// - Off the main actor: the stream is started and stopped on the main actor, but FSEvents delivers on a private
///   queue where `Collector` batches; one sink task runs at a time (a slow batch delays the next; paths keep
///   accumulating in the bounded set).
/// - Debounced (`debounce` after the first event of a batch) and bounded: at most `maxBatch` paths per batch; beyond
///   that the batch collapses to the changed folders (still bounded), counted in `overflows`, so watchers rescan.
/// - Ignored: `.git/`, dependency and build folders (`excludedComponents`), and events that only changed metadata
///   (the touch itself), so a touch never feeds back into another touch.
@MainActor
public final class FileEventBridge {
    public struct Stats: Sendable, Equatable {
        public var events = 0
        public var batches = 0
        public var paths = 0
        public var overflows = 0
        public var failures = 0
        /// Wall time of the last batch's sink call, in milliseconds.
        public var lastBatchMilliseconds = 0.0
    }

    public nonisolated static let excludedComponents: Set<String> = [
        ".git", "node_modules", ".venv", "venv", "__pycache__", ".mypy_cache", ".pytest_cache", "target", ".next", ".nuxt",
        "dist", "build", ".build", ".cache", ".gradle", ".turbo", "coverage",
    ]

    fileprivate final class Box: Sendable {
        let collector: Collector
        init(_ collector: Collector) { self.collector = collector }
    }

    public let roots: [String]
    private let collector: Collector
    private var stream: FSEventStreamRef?
    private var box: Unmanaged<Box>?

    public init(roots: [String], debounce: Duration = .milliseconds(150), maxBatch: Int = 2_000,
                sink: @escaping @Sendable ([String]) async throws -> Void) {
        self.roots = roots
        // FSEvents reports resolved paths (/private/var/…); the container mounts the folders as the project spells them.
        let aliases = roots.compactMap { root -> (String, String)? in
            // realpath(3): NSString's resolvingSymlinksInPath strips /private, which is the part that differs.
            guard let resolved = realpath(root, nil) else { return nil }
            defer { free(resolved) }
            let real = String(cString: resolved)
            return real == root ? nil : (real, root)
        }
        collector = Collector(debounce: debounce, maxBatch: maxBatch, aliases: aliases, sink: sink)
    }

    /// `path` as the container sees it: a resolved prefix is replaced by the root's own spelling.
    nonisolated static func mounted(_ path: String, aliases: [(real: String, root: String)]) -> String {
        for (real, root) in aliases where path == real || path.hasPrefix(real + "/") { return root + path.dropFirst(real.count) }
        return path
    }

    isolated deinit { stop() }

    public var stats: Stats { collector.stats }
    public var isRunning: Bool { stream != nil }

    public func start() {
        guard !roots.isEmpty, stream == nil, !collector.isStopped else { return }
        let box = Unmanaged.passRetained(Box(collector))
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, fileEventBridgeCallback, &context, roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
        else {
            box.release()
            return
        }
        FSEventStreamSetDispatchQueue(created, collector.queue)
        FSEventStreamStart(created)
        stream = created
        self.box = box
    }

    public func stop() {
        collector.stop()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        // Released on the stream's queue, after any callback already queued there has run.
        if let box { collector.queue.async { box.release() } }
        box = nil
    }

    /// Whether a path's event should reach the container: content or entry changes only, outside excluded folders.
    nonisolated static func isRelevant(_ path: String, flags: FSEventStreamEventFlags) -> Bool {
        let interesting = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
                | kFSEventStreamEventFlagItemModified)
        guard flags & interesting != 0 else { return false }
        return !path.split(separator: "/").contains { excludedComponents.contains(String($0)) }
    }

    /// Created, removed and renamed entries also touch their folder, so directory watchers rescan.
    nonisolated static func touchesFolder(_ flags: FSEventStreamEventFlags) -> Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed) != 0
    }

    /// Batching, off the main actor: events arrive on `queue`; one sink call runs at a time.
    final class Collector: Sendable {
        private struct State {
            var pending: Set<String> = []
            var folders: Set<String> = []
            var scheduled = false
            var running: Task<Void, Never>?
            var stats = Stats()
            var stopped = false
        }

        let queue = DispatchQueue(label: "app.bellocode.containers.file-bridge")
        let debounce: Duration
        let maxBatch: Int
        private let sink: @Sendable ([String]) async throws -> Void
        private let state = Mutex(State())
        /// The trailing-edge flush, on ContinuousClock (an uptime-clock `asyncAfter` may not fire in an idle process).
        private let flushDeadline = ContinuousDeadline()
        private static let signposter = OSSignposter(subsystem: "app.bellocode.engine", category: "file-bridge")

        let aliases: [(real: String, root: String)]

        init(debounce: Duration, maxBatch: Int, aliases: [(String, String)] = [], sink: @escaping @Sendable ([String]) async throws -> Void) {
            self.aliases = aliases.map { (real: $0.0, root: $0.1) }
            self.debounce = debounce
            self.maxBatch = maxBatch
            self.sink = sink
        }

        var stats: Stats { state.withLock { $0.stats } }
        var isStopped: Bool { state.withLock { $0.stopped } }

        func stop() {
            let running = state.withLock { state -> Task<Void, Never>? in
                state.stopped = true
                state.pending.removeAll()
                state.folders.removeAll()
                defer { state.running = nil }
                return state.running
            }
            running?.cancel()
            flushDeadline.cancel()
        }

        func received(_ events: [(String, FSEventStreamEventFlags)]) {
            let schedule = state.withLock { state -> Bool in
                guard !state.stopped else { return false }
                for (resolved, flags) in events {
                    state.stats.events += 1
                    let path = FileEventBridge.mounted(resolved, aliases: aliases)
                    guard FileEventBridge.isRelevant(path, flags: flags) else { continue }
                    if state.pending.count < maxBatch * 4 { state.pending.insert(path) } else { state.stats.overflows += 1 }
                    if FileEventBridge.touchesFolder(flags) { state.folders.insert((path as NSString).deletingLastPathComponent) }
                }
                guard !state.scheduled, !(state.pending.isEmpty && state.folders.isEmpty) else { return false }
                state.scheduled = true
                return true
            }
            if schedule { scheduleFlush() }
        }

        private func scheduleFlush() {
            flushDeadline.schedule(after: debounce) { [weak self] in
                guard let self else { return }
                self.queue.async { self.flush() }
            }
        }

        /// Takes the pending batch and runs the sink (one at a time). Called on `queue`.
        private func flush() {
            let batch = state.withLock { state -> [String]? in
                state.scheduled = false
                guard !state.stopped else { return nil }
                if state.running != nil {
                    // The previous batch is still in the container: try again after it.
                    state.scheduled = true
                    return []
                }
                var paths = Array(state.pending)
                var folders = state.folders
                state.pending.removeAll()
                state.folders.removeAll()
                if paths.count > maxBatch {
                    // Too many to name one by one: touch the folders instead (bounded too).
                    state.stats.overflows += 1
                    for path in paths { folders.insert((path as NSString).deletingLastPathComponent) }
                    paths = []
                }
                let all = (paths.sorted() + folders.sorted()).prefix(maxBatch)
                return all.isEmpty ? nil : Array(all)
            }
            guard let batch else { return }
            if batch.isEmpty {
                scheduleFlush()
                return
            }
            let sink = self.sink
            // Registered as running under the lock before it can finish (a fast batch must not leave a stale handle).
            state.withLock { state in
                guard !state.stopped else { return }
                state.running = Task { [weak self] in
                let interval = Self.signposter.beginInterval("batch")
                let start = ContinuousClock.now
                var failed = false
                do { try await sink(batch) } catch { failed = true }
                Self.signposter.endInterval("batch", interval)
                let elapsed = ContinuousClock.now - start
                guard let self else { return }
                let again = self.state.withLock { state -> Bool in
                    state.running = nil
                    state.stats.batches += 1
                    state.stats.paths += batch.count
                    if failed { state.stats.failures += 1 }
                    state.stats.lastBatchMilliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
                    guard !state.stopped, !state.scheduled, !(state.pending.isEmpty && state.folders.isEmpty) else { return false }
                    state.scheduled = true
                    return true
                }
                if again { self.scheduleFlush() }
                }
            }
        }
    }
}

/// The FSEvents callback, on the bridge's queue (nonisolated).
private func fileEventBridgeCallback(
    _ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int, _ paths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>, _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let names = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
    var events: [(String, FSEventStreamEventFlags)] = []
    events.reserveCapacity(min(count, names.count))
    for index in 0..<min(count, names.count) { events.append((names[index], flags[index])) }
    Unmanaged<FileEventBridge.Box>.fromOpaque(info).takeUnretainedValue().collector.received(events)
}
