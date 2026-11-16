import Foundation

/// An accepted completion inside the prompt text: a file mention, a slash command, an agent or a skill.
///
/// Identity is `id` (stable across edits, undo and draft restore), never the token's position. `text` is both what the
/// user sees and the token's plain-text form: copying, sending and history all use it.
public struct ComposerToken: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case file, command, agent, skill, other
    }

    public var id: String
    public var kind: Kind
    /// Shown text and plain-text form, for example `@Sources/App/main.swift` or `/review`.
    public var text: String
    /// The payload the host acts on, for example an absolute file path or a command name.
    public var value: String

    public init(id: String = UUID().uuidString, kind: Kind, text: String, value: String) {
        self.id = id
        self.kind = kind
        self.text = text
        self.value = value
    }
}

/// A token at its position in the draft text (UTF-16 offsets, as `NSString` and `NSTextView` count).
public struct PlacedToken: Hashable, Sendable, Codable {
    public var token: ComposerToken
    public var location: Int
    public var length: Int

    public init(token: ComposerToken, range: NSRange) {
        self.token = token
        location = range.location
        length = range.length
    }

    public var range: NSRange { NSRange(location: location, length: length) }
}

/// Everything the composer holds for one thread: text, tokens, attachments and selection. A plain value, so hosts can
/// store it, and the composer can restore it exactly (including the caret) when the thread is shown again.
public struct ComposerDraft: Hashable, Sendable, Codable {
    public var text: String
    public var tokens: [PlacedToken]
    public var attachments: [ComposerAttachment]
    /// UTF-16 selection; clamped on restore.
    public var selectionLocation: Int
    public var selectionLength: Int

    public init(
        text: String = "", tokens: [PlacedToken] = [], attachments: [ComposerAttachment] = [],
        selection: NSRange? = nil
    ) {
        self.text = text
        self.tokens = tokens
        self.attachments = attachments
        let selection = selection ?? NSRange(location: (text as NSString).length, length: 0)
        selectionLocation = selection.location
        selectionLength = selection.length
    }

    public static let empty = ComposerDraft()

    public var selection: NSRange {
        get { NSRange(location: selectionLocation, length: selectionLength) }
        set {
            selectionLocation = newValue.location
            selectionLength = newValue.length
        }
    }

    /// Nothing worth sending: whitespace-only text and no attachments.
    public var isEmpty: Bool {
        attachments.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Tokens whose text no longer matches the draft at their range are dropped (the text stays).
    public func validated() -> ComposerDraft {
        var copy = self
        let string = text as NSString
        copy.tokens = tokens.filter { placed in
            NSMaxRange(placed.range) <= string.length && string.substring(with: placed.range) == placed.token.text
        }
        let length = string.length
        let location = min(max(0, selectionLocation), length)
        copy.selection = NSRange(location: location, length: min(max(0, selectionLength), length - location))
        return copy
    }

    /// Joins a draft that failed to send with whatever the user typed since, so neither is lost: the failed text
    /// comes first, followed by a blank line and the newer text.
    public static func merging(failed: ComposerDraft, current: ComposerDraft) -> ComposerDraft {
        if current.isEmpty && current.text.isEmpty { return failed }
        if failed.isEmpty { return current }
        let separator = "\n\n"
        let offset = (failed.text as NSString).length + (separator as NSString).length
        let shifted = current.tokens.map { placed in
            PlacedToken(token: placed.token, range: NSRange(location: placed.location + offset, length: placed.length))
        }
        let known = Set(failed.attachments.map(\.id))
        return ComposerDraft(
            text: failed.text + separator + current.text,
            tokens: failed.tokens + shifted,
            attachments: failed.attachments + current.attachments.filter { !known.contains($0.id) },
            selection: NSRange(location: current.selectionLocation + offset, length: current.selectionLength)
        )
    }
}
