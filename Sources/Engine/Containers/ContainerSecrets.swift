import BelloCore
import Foundation

/// Secrets for commands that run in a container (docs/features/containers.md). The host path (`SecretService`, a
/// one-read named pipe on the Mac) cannot reach a container: a FIFO does not cross Rancher Desktop's file sharing. So
/// for containerised projects a saved secret is delivered by reference, and `secret_exec` runs one command in the
/// project's container with the value in that exec's environment only: sent over the Engine API socket in memory,
/// never written to a file, never in the container's configuration, gone with the command. Output is redacted.
///
/// References here are BelloCode's own (`bcsecretc_…`): one use, one thread, one hour, at most 64 outstanding.
/// Threading: `@MainActor`, owned by `ExtrasHub`.
@MainActor
final class ContainerSecretReferences {
    struct Entry {
        var account: String
        var label: String
        var sessionID: SessionID
        var expires: Date
    }

    static let prefix = "bcsecretc_"
    static let lifetime: TimeInterval = 3_600
    static let limit = 64
    private var entries: [String: Entry] = [:]

    func issue(account: String, label: String, for sessionID: SessionID, now: Date) -> String {
        entries = entries.filter { $0.value.expires > now }
        if entries.count >= Self.limit, let oldest = entries.min(by: { $0.value.expires < $1.value.expires })?.key { entries[oldest] = nil }
        let reference = Self.prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        entries[reference] = Entry(account: account, label: label, sessionID: sessionID, expires: now.addingTimeInterval(Self.lifetime))
        return reference
    }

    /// Consumes a reference (once). Only the thread it was issued to may use it.
    func redeem(_ reference: String, by sessionID: SessionID, now: Date) throws -> Entry {
        guard let entry = entries[reference], entry.expires > now else {
            entries[reference] = nil
            throw ExtrasError("That secretRef is unknown, used or expired. Ask again with request_secret.")
        }
        guard entry.sessionID == sessionID else { throw ExtrasError("That secretRef belongs to another thread.") }
        entries[reference] = nil
        return entry
    }

    static func isContainerReference(_ reference: String) -> Bool { reference.hasPrefix(prefix) }

    var outstanding: Int { entries.count }
}

/// Valid environment variable names for `secret_exec`.
enum SecretVariableName {
    static func validate(_ name: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")
        guard !name.isEmpty, name.count <= 64, name.unicodeScalars.allSatisfy(allowed.contains), name.first?.isNumber == false,
              !ProjectEnvironmentSettings.reservedVariables.contains(name), !name.hasPrefix("BUN_"), !name.hasPrefix("BELLOCODE_")
        else { throw ExtrasError("“\(name)” is not a usable variable name (letters, digits and _; not PATH, HOME or BELLOCODE_*).") }
        return name
    }
}
