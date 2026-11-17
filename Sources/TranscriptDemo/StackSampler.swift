import Darwin
import Foundation
import QuartzCore

/// Harness-only sampling profiler for the main thread (no Instruments with Command Line Tools). A background thread
/// suspends the main thread about every millisecond, walks its frame-pointer chain into a preallocated ring (nothing
/// is allocated while the main thread is suspended: it may hold the malloc lock) and resumes it. The harness keeps
/// the samples that fall inside slow frames; `writeReport` aggregates them by return address for `atos -p`.
final class StackSampler: @unchecked Sendable {  // Harness tool: all shared state is guarded by `lock`.
    static let depth = 64
    static let capacity = 1024

    private let mainThread: thread_act_t
    private let stackLow: UInt
    private let stackHigh: UInt
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let frames: UnsafeMutablePointer<UInt>
    private let depths: UnsafeMutablePointer<Int>
    private let times: UnsafeMutablePointer<Double>
    private var head = 0
    private var running = false
    private var kept: [[UInt]] = []
    private(set) var keptFrames = 0

    /// Call on the main thread.
    init() {
        mainThread = pthread_mach_thread_np(pthread_self())
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        stackHigh = top
        stackLow = top - UInt(pthread_get_stacksize_np(pthread_self()))
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        frames = .allocate(capacity: Self.capacity * Self.depth)
        depths = .allocate(capacity: Self.capacity)
        depths.initialize(repeating: 0, count: Self.capacity)
        times = .allocate(capacity: Self.capacity)
        times.initialize(repeating: 0, count: Self.capacity)
    }

    func start() {
        running = true
        let thread = Thread { [self] in
            while isRunning() {
                sample()
                usleep(900)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func isRunning() -> Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return running
    }

    func stop() { os_unfair_lock_lock(lock); running = false; os_unfair_lock_unlock(lock) }

    private func sample() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let slot = head % Self.capacity
        let base = frames + slot * Self.depth
        var count = 0
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return }
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &stateCount)
            }
        }
        if result == KERN_SUCCESS {
            let mask: UInt = 0x0000_7FFF_FFFF_FFFF
            base[count] = UInt(state.__pc) & mask
            count += 1
            base[count] = UInt(state.__lr) & mask
            count += 1
            var fp = UInt(state.__fp) & mask
            while count < Self.depth, fp >= stackLow, fp + 16 <= stackHigh, fp & 7 == 0 {
                let pointer = UnsafePointer<UInt>(bitPattern: fp)!
                let next = pointer[0] & mask
                let ret = pointer[1] & mask
                if ret == 0 { break }
                base[count] = ret
                count += 1
                if next <= fp { break }
                fp = next
            }
        }
        thread_resume(mainThread)
        depths[slot] = count
        times[slot] = CACurrentMediaTime()
        head += 1
    }

    /// Keeps the samples taken between `from` and `to` (CACurrentMediaTime) — a slow frame. Main thread.
    func keep(from: Double, to: Double) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        keptFrames += 1
        let start = max(0, head - Self.capacity)
        for index in start..<head {
            let slot = index % Self.capacity
            guard times[slot] >= from, times[slot] <= to, depths[slot] > 0 else { continue }
            kept.append(Array(UnsafeBufferPointer(start: frames + slot * Self.depth, count: depths[slot])))
        }
    }

    /// Writes kept samples: one line per sample, addresses in hex (leaf first). Symbolicate with `atos -p`.
    func writeSamples(to url: URL) {
        os_unfair_lock_lock(lock)
        let samples = kept
        os_unfair_lock_unlock(lock)
        let text = samples.map { $0.map { String($0, radix: 16) }.joined(separator: " ") }.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Samples taken so far (rate check).
    var taken: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return head
    }

    var keptSamples: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return kept.count
    }
}
