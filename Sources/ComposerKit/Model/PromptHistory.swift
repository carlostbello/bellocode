/// Previously sent prompts for Up/Down recall, oldest first, bounded.
///
/// The composer stashes the in-progress draft when browsing starts and restores it when the user moves past the
/// newest entry (`.restoreDraft`). Replacing text with an entry is an undoable edit, so Undo also brings the draft back.
public struct PromptHistory: Hashable, Sendable {
    public enum Step: Hashable, Sendable {
        case entry(String)
        case restoreDraft
    }

    public private(set) var entries: [String]
    /// Index into `entries` while browsing; `nil` otherwise.
    public private(set) var index: Int?
    public let capacity: Int

    public init(entries: [String] = [], capacity: Int = 200) {
        self.capacity = max(1, capacity)
        self.entries = []
        for entry in entries { record(entry) }
        index = nil
    }

    public var isBrowsing: Bool { index != nil }

    /// Adds a sent prompt. Blank prompts and repeats of the newest entry are skipped. Ends browsing.
    public mutating func record(_ text: String) {
        index = nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entries.last != text else { return }
        entries.append(text)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// Older entry. The first call starts browsing (stash the draft before calling). `nil` at the oldest entry.
    public mutating func previous() -> Step? {
        guard !entries.isEmpty else { return nil }
        guard let current = index else {
            index = entries.count - 1
            return .entry(entries[entries.count - 1])
        }
        guard current > 0 else { return nil }
        index = current - 1
        return .entry(entries[current - 1])
    }

    /// Newer entry, or `.restoreDraft` past the newest. `nil` when not browsing.
    public mutating func next() -> Step? {
        guard let current = index else { return nil }
        if current + 1 < entries.count {
            index = current + 1
            return .entry(entries[current + 1])
        }
        index = nil
        return .restoreDraft
    }

    /// The user edited a recalled entry: it is now the draft.
    public mutating func endBrowsing() { index = nil }
}
