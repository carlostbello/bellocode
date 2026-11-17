import CoreServices
import Foundation

/// Watches folders with FSEvents and calls `onChange` on the main actor, debounced (`debounce` after the last event).
/// Events inside `.git/objects` and lock files are ignored (they accompany ref and index updates, which are not).
///
/// Ownership: the owner calls `stop()` (or releases the watcher, which stops it). The stream runs on a private
/// serial queue; nothing but the debounce hop touches the main actor.
@MainActor
public final class FileSystemWatcher {
    fileprivate final class Box: Sendable {
        let fire: @Sendable () -> Void
        init(fire: @escaping @Sendable () -> Void) { self.fire = fire }
    }

    public let paths: [String]
    public let debounce: Duration
    private let onChange: @MainActor () -> Void
    private var stream: FSEventStreamRef?
    private var box: Unmanaged<Box>?
    private let queue = DispatchQueue(label: "dev.bellocode.git.watch")
    private var pending: Task<Void, Never>?
    /// Events received (tests and diagnostics).
    public private(set) var eventCount = 0

    public init(paths: [String], debounce: Duration = .milliseconds(250), onChange: @escaping @MainActor () -> Void) {
        self.paths = paths
        self.debounce = debounce
        self.onChange = onChange
    }

    isolated deinit { stop() }

    public var isRunning: Bool { stream != nil }

    public func start() {
        guard stream == nil, !paths.isEmpty else { return }
        let box = Unmanaged.passRetained(Box { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received() } }
        })
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, fileSystemWatcherCallback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags)
        else {
            box.release()
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
        self.box = box
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        // Released on the stream's queue, after any callback already queued there has run.
        if let box { queue.async { box.release() } }
        box = nil
    }

    private func received() {
        guard stream != nil else { return }
        eventCount += 1
        pending?.cancel()
        let delay = debounce
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.stream != nil else { return }
            self.pending = nil
            self.onChange()
        }
    }
}

/// The FSEvents callback, on the stream's queue (nonisolated: it must not inherit the main actor).
private func fileSystemWatcherCallback(
    _ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int, _ paths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>, _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let names = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
    var relevant = false
    for path in names.prefix(count) where !path.contains("/.git/objects/") && !path.hasSuffix(".lock") && !path.contains("/.git/logs/") {
        relevant = true
        break
    }
    guard relevant else { return }
    Unmanaged<FileSystemWatcher.Box>.fromOpaque(info).takeUnretainedValue().fire()
}
