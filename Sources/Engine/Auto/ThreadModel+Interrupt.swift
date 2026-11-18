import BelloCore
import Foundation

// Attributed interrupts (docs/features/auto-mode.md): another thread's agent stopped this one (plugin
// `thread_interrupt`); its queued work is held until the person resumes it.

extension ThreadModel {
    /// Who stopped this thread and why, while its work is held.
    public var heldInterrupt: InterruptRecord? {
        guard let record = InterruptRecord.from(metadata: session?.metadata), record.held, !(session?.isRunning ?? false) else { return nil }
        return record
    }

    /// The person's Resume: a run starts with a note saying who resumed it, the hold is cleared, and opencode delivers
    /// the queued prompts it parked after the interrupt. Side effects already made are not undone (it is a
    /// continuation, not a rollback).
    @discardableResult
    public func resumeAfterInterrupt() async -> Bool {
        guard let sessionID = session?.id, let record = heldInterrupt else { return false }
        do {
            try await engine?.core.mergeSessionMetadata(sessionID) { raw in
                var object = (raw.flatMap { $0.text.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
                if var value = object[InterruptRecord.metadataKey] as? [String: Any] {
                    value["held"] = false
                    object[InterruptRecord.metadataKey] = value
                }
                return object
            }
            let who = record.byTitle.map { "“\($0)”" } ?? record.by
            try await engine?.core.postSynthetic(
                sessionID,
                text: "[BelloCode resume] The person resumed this thread after \(who) stopped it (\(record.reason)). Continue the interrupted work.",
                resume: true)
            return true
        } catch {
            return false
        }
    }
}
