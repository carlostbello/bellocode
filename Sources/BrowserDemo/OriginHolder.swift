import Synchronization

/// The fixture origins, known only after both listeners bound their ports.
final class OriginHolder: Sendable {
    private let origins = Mutex(("", ""))
    var same: String { origins.withLock { $0.0 } }
    var cross: String { origins.withLock { $0.1 } }
    func set(same: String, cross: String) { origins.withLock { $0 = (same, cross) } }
}
