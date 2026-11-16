import Foundation

extension NSAttributedString.Key {
    /// Marks a run of composer text as one atomic token. Value: `TokenAttribute`.
    public static let composerToken = NSAttributedString.Key("BelloCode.composerToken")
    /// Colour of the rounded background drawn behind a token. Value: `NSColor`.
    static let composerTokenBackground = NSAttributedString.Key("BelloCode.composerTokenBackground")
}

/// The attribute value carried by a token's characters. Immutable; equal only to the same token, so two adjacent
/// tokens never merge into one run.
public final class TokenAttribute: NSObject, Sendable {
    public let token: ComposerToken

    public init(_ token: ComposerToken) {
        self.token = token
    }

    public override func isEqual(_ object: Any?) -> Bool {
        (object as? TokenAttribute)?.token == token
    }

    public override var hash: Int { token.hashValue }
}

/// Pure functions over attributed text that keep tokens atomic. Shared by the text view and the tests.
public enum TokenText {
    /// Tokens and their ranges, in text order.
    public static func placedTokens(in text: NSAttributedString) -> [PlacedToken] {
        var result: [PlacedToken] = []
        text.enumerateAttribute(.composerToken, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let attribute = value as? TokenAttribute { result.append(PlacedToken(token: attribute.token, range: range)) }
        }
        return result
    }

    /// Builds attributed text for a draft: `base` everywhere, plus `decoration(token)` on each valid token range.
    public static func attributedText(
        for draft: ComposerDraft, base: [NSAttributedString.Key: Any],
        decoration: (ComposerToken) -> [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let valid = draft.validated()
        let result = NSMutableAttributedString(string: valid.text, attributes: base)
        for placed in valid.tokens {
            result.addAttributes(decoration(placed.token), range: placed.range)
            result.addAttribute(.composerToken, value: TokenAttribute(placed.token), range: placed.range)
        }
        return result
    }

    /// One token as attributed text, ready to insert.
    public static func attributedToken(
        _ token: ComposerToken, base: [NSAttributedString.Key: Any], decoration: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        var attributes = base
        attributes.merge(decoration) { $1 }
        attributes[.composerToken] = TokenAttribute(token)
        return NSAttributedString(string: token.text, attributes: attributes)
    }

    /// The range an edit of `range` must actually replace so that no token is left half-edited: any token the range
    /// overlaps (or, for a non-empty range, touches from inside) is included whole. An insertion point is unchanged.
    public static func expandedEditRange(_ range: NSRange, in text: NSAttributedString) -> NSRange {
        guard range.length > 0 else { return range }
        var result = range
        for placed in placedTokens(in: text) {
            let token = placed.range
            let overlaps = range.location < NSMaxRange(token) && token.location < NSMaxRange(range)
            if overlaps { result = NSUnionRange(result, token) }
        }
        return result
    }

    /// Keeps the caret out of token interiors and makes selections cover whole tokens. Moving right lands after the
    /// token, moving left before it.
    public static func snappedSelection(from old: NSRange, to new: NSRange, in text: NSAttributedString) -> NSRange {
        let tokens = placedTokens(in: text).map(\.range)
        guard !tokens.isEmpty else { return new }
        if new.length == 0 {
            guard let token = tokens.first(where: { $0.location < new.location && new.location < NSMaxRange($0) }) else {
                return new
            }
            let movingRight = new.location >= old.location
            return NSRange(location: movingRight ? NSMaxRange(token) : token.location, length: 0)
        }
        var result = new
        for token in tokens {
            let overlaps = new.location < NSMaxRange(token) && token.location < NSMaxRange(new)
            if overlaps { result = NSUnionRange(result, token) }
        }
        return result
    }

    /// Token runs whose characters no longer read as their token (for example after an input method or a
    /// programmatic edit inside one). The caller removes the token attribute there, leaving plain text.
    public static func brokenTokenRanges(in text: NSAttributedString) -> [NSRange] {
        var broken: [NSRange] = []
        let string = text.string as NSString
        text.enumerateAttribute(.composerToken, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let attribute = value as? TokenAttribute else { return }
            if string.substring(with: range) != attribute.token.text { broken.append(range) }
        }
        return broken
    }

    /// The draft value for attributed text.
    public static func draft(
        from text: NSAttributedString, attachments: [ComposerAttachment], selection: NSRange
    ) -> ComposerDraft {
        ComposerDraft(text: text.string, tokens: placedTokens(in: text), attachments: attachments, selection: selection)
    }
}
