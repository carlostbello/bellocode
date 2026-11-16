// G5 SPIKE ONLY. A reference wrapper so a Mutex-protected value can be shared by closures.

import Synchronization

public final class SpikeLocked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    public init(_ value: Value) { mutex = Mutex(value) }

    @discardableResult
    public func withLock<R: Sendable>(_ body: (inout sending Value) throws -> sending R) rethrows -> R {
        try mutex.withLock(body)
    }

    public var value: Value { mutex.withLock { $0 } }
}
