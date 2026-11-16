import Foundation
import Synchronization

/// A bounded, thread-safe buffer of the server child's output lines, kept for diagnostics.
///
/// Bytes are appended from pipe callbacks, split into lines (partial lines are carried to the next append) and the
/// oldest lines are discarded beyond `maxLines`; overlong lines are truncated. `redactions` are replaced before a line
/// is stored, so the per-launch password can never land in the buffer. Nothing here is written to the system log.
public final class BoundedLog: Sendable {
    public enum Stream: String, Sendable { case stdout, stderr }

    public struct Line: Sendable, Hashable {
        public let stream: Stream
        public let text: String
    }

    private struct State {
        var lines: [Line] = []
        var start = 0
        var partial: [Stream: [UInt8]] = [:]
        var discarded = 0
    }

    public let maxLines: Int
    public let maxLineBytes: Int
    private let redactions: [String]
    /// Bytes kept per pending line: enough that a secret starting inside the kept prefix is always whole.
    private let pendingCap: Int
    private let state = Mutex(State())

    public init(maxLines: Int = 500, maxLineBytes: Int = 2048, redactions: [String] = []) {
        precondition(maxLines > 0 && maxLineBytes > 0)
        self.maxLines = maxLines
        self.maxLineBytes = maxLineBytes
        self.redactions = redactions.filter { !$0.isEmpty }
        self.pendingCap = maxLineBytes + (self.redactions.map(\.utf8.count).max() ?? 0)
    }

    public func append(_ data: some Sequence<UInt8>, from stream: Stream) {
        state.withLock { state in
            var pending = state.partial[stream] ?? []
            for byte in data {
                if byte == UInt8(ascii: "\n") {
                    store(pending, stream: stream, into: &state)
                    pending.removeAll(keepingCapacity: true)
                } else if pending.count < pendingCap {
                    pending.append(byte)
                }
            }
            state.partial[stream] = pending
        }
    }

    /// Stores any partial last line (call when the stream closes).
    public func flush(_ stream: Stream) {
        state.withLock { state in
            if let pending = state.partial.removeValue(forKey: stream), !pending.isEmpty {
                store(pending, stream: stream, into: &state)
            }
        }
    }

    /// The retained lines, oldest first.
    public var lines: [Line] {
        state.withLock { state in Array(state.lines[state.start...] + state.lines[..<state.start]) }
    }

    /// Number of lines discarded because the buffer was full.
    public var discardedCount: Int { state.withLock { $0.discarded } }

    public var text: String { lines.map(\.text).joined(separator: "\n") }

    private func store(_ bytes: [UInt8], stream: Stream, into state: inout State) {
        // Redact before truncating, so a cut can never leave part of a secret behind.
        var text = String(decoding: bytes, as: UTF8.self)
        for secret in redactions { text = text.replacingOccurrences(of: secret, with: "<redacted>") }
        if text.utf8.count > maxLineBytes { text = String(decoding: text.utf8.prefix(maxLineBytes), as: UTF8.self) }
        if text.hasSuffix("\r") { text.removeLast() }
        let line = Line(stream: stream, text: text)
        if state.lines.count < maxLines {
            state.lines.append(line)
        } else {
            state.lines[state.start] = line
            state.start = (state.start + 1) % maxLines
            state.discarded += 1
        }
    }
}
