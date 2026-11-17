import Foundation
import Synchronization

/// Owns tasks for a main-actor model so a nonisolated `deinit` (or `close()`) can cancel them. Keyed tasks replace
/// and cancel the previous task with the same key (debounces, reloads).
final class TaskBox: Sendable {
    private let tasks = Mutex<[String: Task<Void, Never>]>([:])

    func set(_ key: String, _ task: Task<Void, Never>) {
        let previous = tasks.withLock { tasks in
            defer { tasks[key] = task }
            return tasks[key]
        }
        previous?.cancel()
    }

    /// Removes and returns the task under `key` without cancelling it (to await it).
    func take(_ key: String) -> Task<Void, Never>? {
        tasks.withLock { $0.removeValue(forKey: key) }
    }

    func remove(_ key: String) {
        _ = tasks.withLock { $0.removeValue(forKey: key) }
    }

    func cancelAll() {
        let all = tasks.withLock { tasks in
            defer { tasks.removeAll() }
            return Array(tasks.values)
        }
        for task in all { task.cancel() }
    }

    deinit { cancelAll() }
}
