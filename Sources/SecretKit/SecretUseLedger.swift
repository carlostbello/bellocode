import Foundation
import Synchronization

/// Use counts per binding (R12, docs/reviews/release-1.0-review.md), shared by the egress proxy and the brokered HTTP
/// tool so one binding's `maxUses` holds across both. A use is reserved, atomically and all-or-nothing, before the
/// request is dispatched; once dispatch starts a use is never given back (a request that then fails still counts: the
/// value may have left). Only a request refused before anything was sent releases its reservation. Seeded from the persisted counts; the owner persists reservations (for limited bindings, before
/// dispatch).
public final class SecretUseLedger: Sendable {
    private struct Key: Hashable {
        var account: String
        var binding: String
    }

    private let counts = Mutex<[Key: Int]>([:])

    public init() {}

    /// Takes the persisted counts (never lowers a count already reserved in memory).
    public func seed(_ secrets: [ManagedSecret]) {
        counts.withLock { counts in
            for secret in secrets {
                for (binding, used) in secret.uses {
                    let key = Key(account: secret.account, binding: binding)
                    counts[key] = max(counts[key] ?? 0, used)
                }
            }
        }
    }

    public func count(account: String, bindingID: String) -> Int {
        counts.withLock { $0[Key(account: account, binding: bindingID)] ?? 0 }
    }

    /// Gives back uses reserved for a request that was refused before it was sent.
    public func release(_ uses: [SubstitutionUse]) {
        counts.withLock { counts in
            for use in uses {
                let key = Key(account: use.account, binding: use.bindingID)
                if let used = counts[key] { counts[key] = max(0, used - 1) }
            }
        }
    }

    /// Reserves every use or none: each binding must stay within `limit(use)` (nil: unlimited) counting the uses
    /// before it in the same request.
    public func reserve(_ uses: [SubstitutionUse], limit: (SubstitutionUse) -> Int?) -> Bool {
        counts.withLock { counts in
            var next = counts
            for use in uses {
                let key = Key(account: use.account, binding: use.bindingID)
                let used = next[key] ?? 0
                if let maximum = limit(use), used >= maximum { return false }
                next[key] = used + 1
            }
            counts = next
            return true
        }
    }
}
