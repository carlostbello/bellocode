import Foundation

/// Inline traits of a run of text. Combinable (bold + italic + link).
public struct InlineTraits: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold = InlineTraits(rawValue: 1 << 0)
    public static let italic = InlineTraits(rawValue: 1 << 1)
    public static let code = InlineTraits(rawValue: 1 << 2)
    public static let strike = InlineTraits(rawValue: 1 << 3)
    public static let link = InlineTraits(rawValue: 1 << 4)
    /// An `@file` or `@agent` mention in a prompt (drawn as a chip).
    public static let mention = InlineTraits(rawValue: 1 << 5)
    public static let muted = InlineTraits(rawValue: 1 << 6)
}

/// A styled range of display text. Offsets are UTF-16 so they map 1:1 to NSString and CoreText indices.
public struct StyleRun: Sendable, Hashable {
    public var location: Int
    public var length: Int
    public var traits: InlineTraits
    /// The destination of a link run.
    public var link: String?

    public init(location: Int, length: Int, traits: InlineTraits, link: String? = nil) {
        self.location = location
        self.length = length
        self.traits = traits
        self.link = link
    }

    public var range: Range<Int> { location..<(location + length) }
}

/// Display text with style runs.
public struct StyledText: Sendable, Hashable {
    public var text: String
    public var runs: [StyleRun]
    public let utf16Count: Int

    public init(_ text: String, runs: [StyleRun] = []) {
        self.text = text
        self.runs = runs
        utf16Count = text.utf16.count
    }

    /// The link destination at a UTF-16 offset, if any.
    public func link(at offset: Int) -> (range: Range<Int>, url: String)? {
        for run in runs where run.link != nil && run.range.contains(offset) { return (run.range, run.link!) }
        return nil
    }
}

/// Builds a `StyledText` from appended pieces.
struct StyledTextBuilder {
    private(set) var text = ""
    private(set) var runs: [StyleRun] = []
    private var length = 0

    mutating func append(_ piece: String, traits: InlineTraits = [], link: String? = nil) {
        let count = piece.utf16.count
        guard count > 0 else { return }
        if !traits.isEmpty || link != nil {
            if let last = runs.last, last.traits == traits, last.link == link, last.location + last.length == length {
                runs[runs.count - 1].length += count
            } else {
                runs.append(StyleRun(location: length, length: count, traits: traits, link: link))
            }
        }
        text += piece
        length += count
    }

    var isEmpty: Bool { length == 0 }

    func build() -> StyledText { StyledText(text, runs: runs) }
}

/// Plain prompt text with `@mention` runs.
enum PromptText {
    static func styled(_ text: String) -> StyledText {
        var runs: [StyleRun] = []
        let ns = text as NSString
        var index = 0
        var location = 0
        let length = ns.length
        while index < length {
            let unit = ns.character(at: index)
            let atStart = index == 0 || isSpace(ns.character(at: index - 1))
            if unit == 64, atStart, index + 1 < length, !isSpace(ns.character(at: index + 1)) {  // @
                location = index
                var end = index + 1
                while end < length, !isSpace(ns.character(at: end)) { end += 1 }
                // Trailing punctuation is not part of the mention.
                while end > location + 1, let scalar = Unicode.Scalar(ns.character(at: end - 1)),
                    ".,;:!?)".unicodeScalars.contains(scalar)
                {
                    end -= 1
                }
                runs.append(StyleRun(location: location, length: end - location, traits: .mention))
                index = end
                continue
            }
            index += 1
        }
        return StyledText(text, runs: runs)
    }

    private static func isSpace(_ unit: unichar) -> Bool { unit == 32 || unit == 10 || unit == 9 || unit == 13 }
}
