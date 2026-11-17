import Foundation

/// Incremental Markdown for a text part that is still streaming.
///
/// Two rules keep streaming stable (docs/research/04, section 23.3, T3 Code's approach):
/// 1. **Line buffering** (`displayPrefix`): only complete lines are shown, plus the words of a partial plain paragraph
///    line; a heading is held until something follows it, a bare list marker is never shown, a possible table header
///    is held until the next line says whether it is one, and a partial line inside a code fence waits for its newline.
/// 2. **Prefix-stable re-parse**: every top-level construct before the last one is final (CommonMark closes all open
///    blocks once a later line starts a new top-level block), so it is parsed once and cached. Each update re-parses
///    only from the start of the last top-level block. Link reference definitions can change earlier blocks; when the
///    text has one, every update parses the whole prefix instead.
///
/// `finish(_:)` parses the remaining tail without holds. Its result equals a one-shot parse of the full text (tested at
/// every split point of a corpus), so the final reconcile never moves anything.
public struct MarkdownStream: Sendable {
    /// Final top-level constructs (source offsets are absolute UTF-8 offsets).
    public private(set) var stable: [TopLevelBlock] = []
    /// The constructs after `stable` (usually one: the block being written).
    public private(set) var open: [TopLevelBlock] = []
    /// UTF-8 offset where the unstable region starts.
    public private(set) var stableEnd = 0
    /// The source prefix covered by `stable`, to detect a source that was replaced instead of extended.
    private var stablePrefix = ""
    private var incremental = true
    /// The text the current blocks were parsed from (the line-buffered prefix while streaming).
    public private(set) var displayed = ""

    public init() {}

    public var blocks: [MarkdownBlock] { (stable + open).flatMap(\.blocks) }
    public var stableBlockCount: Int { stable.reduce(0) { $0 + $1.blocks.count } }

    /// Applies the latest source. Returns the number of leading blocks (flattened) that did not change.
    @discardableResult
    public mutating func update(_ source: String) -> Int { apply(source, finished: false) }

    /// Applies the complete source (no line buffering).
    @discardableResult
    public mutating func finish(_ source: String) -> Int { apply(source, finished: true) }

    private mutating func apply(_ source: String, finished: Bool) -> Int {
        if !source.utf8.starts(with: stablePrefix.utf8) { self = MarkdownStream() }
        let display = finished ? source : Self.displayPrefix(source, from: stableEnd)
        displayed = display
        // Only the unstable region is new; earlier text was checked when it arrived.
        if incremental {
            let utf8 = display.utf8
            let from = utf8.index(utf8.startIndex, offsetBy: min(stableEnd, utf8.count))
            if MarkdownParser.hasReferenceDefinitions(Substring(display[from...])) { incremental = false }
        }
        guard incremental else {
            stable = []
            stableEnd = 0
            stablePrefix = ""
            open = MarkdownParser.parse(display)
            return 0
        }
        let unchanged = stableBlockCount
        let utf8 = display.utf8
        guard utf8.count >= stableEnd else { return unchanged }
        let suffix = String(decoding: utf8[utf8.index(utf8.startIndex, offsetBy: stableEnd)...], as: UTF8.self)
        var parsed = MarkdownParser.parse(suffix)
        for index in parsed.indices {
            parsed[index].sourceStart += stableEnd
            parsed[index].sourceEnd += stableEnd
        }
        if parsed.count >= 2 {
            let newStable = parsed[0..<(parsed.count - 1)]
            stable += newStable
            let newEnd = parsed[parsed.count - 1].sourceStart
            stablePrefix = String(decoding: utf8.prefix(newEnd), as: UTF8.self)
            stableEnd = newEnd
            open = [parsed[parsed.count - 1]]
        } else {
            open = parsed
        }
        return unchanged
    }

    // MARK: Line buffering

    /// The prefix of `source` that may be shown while it streams. `start` is a top-level block boundary (outside any
    /// fence), so fence state is tracked from there.
    public static func displayPrefix(_ source: String, from start: Int = 0) -> String {
        let bytes = Array(source.utf8)
        let begin = min(start, bytes.count)
        // Complete lines end at the last newline.
        var completeEnd = begin
        if let last = bytes[begin...].lastIndex(of: 10) { completeEnd = last + 1 }

        // Walk complete lines: fence state, and the last two lines for the hold rules.
        var inFence = false
        var fenceChar: UInt8 = 0
        var fenceLength = 0
        var lastLine: Range<Int>?
        var previousLine: Range<Int>?
        var lineStart = begin
        while lineStart < completeEnd {
            let lineEnd = bytes[lineStart..<completeEnd].firstIndex(of: 10) ?? completeEnd
            let line = lineStart..<lineEnd
            let (char, length) = fence(bytes, line)
            if inFence {
                if char == fenceChar, length >= fenceLength, isBlank(bytes, (line.lowerBound + indent(bytes, line) + length)..<line.upperBound) {
                    inFence = false
                }
            } else if length >= 3 {
                inFence = true
                fenceChar = char
                fenceLength = length
            }
            previousLine = lastLine
            lastLine = line
            lineStart = lineEnd + 1
        }

        var end = completeEnd
        var holding = false
        let hasPartial = completeEnd < bytes.count && !isBlank(bytes, completeEnd..<bytes.count)
        if !inFence, let line = lastLine, !isBlank(bytes, line) {
            let previousHasPipe = previousLine.map { bytes[$0].contains(124) && !isBlank(bytes, $0) } ?? false
            if (isHeading(bytes, line) && !hasPartial) || isBareListMarker(bytes, line)
                || (bytes[line].contains(124) && !previousHasPipe && !isDelimiterRow(bytes, line))
            {
                end = line.lowerBound
                holding = true
            }
        }
        // The words of a partial plain paragraph line.
        if !holding, !inFence, completeEnd < bytes.count {
            let partial = completeEnd..<bytes.count
            if isPlainParagraphStart(bytes, partial), let space = bytes[partial].lastIndex(of: 32), space > partial.lowerBound {
                end = space
            }
        }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    private static func indent(_ bytes: [UInt8], _ line: Range<Int>) -> Int {
        var count = 0
        while line.lowerBound + count < line.upperBound, bytes[line.lowerBound + count] == 32 { count += 1 }
        return count
    }

    private static func isBlank(_ bytes: [UInt8], _ range: Range<Int>) -> Bool {
        bytes[range].allSatisfy { $0 == 32 || $0 == 9 || $0 == 13 }
    }

    /// Fence character and run length at the start of a line (indent ≤ 3), else (0, 0).
    private static func fence(_ bytes: [UInt8], _ line: Range<Int>) -> (UInt8, Int) {
        let lead = indent(bytes, line)
        guard lead <= 3 else { return (0, 0) }
        let start = line.lowerBound + lead
        guard start < line.upperBound, bytes[start] == 96 || bytes[start] == 126 else { return (0, 0) }  // ` ~
        var length = 0
        while start + length < line.upperBound, bytes[start + length] == bytes[start] { length += 1 }
        if length >= 3, bytes[start] == 96, bytes[(start + length)..<line.upperBound].contains(96) { return (0, 0) }
        return length >= 3 ? (bytes[start], length) : (0, 0)
    }

    private static func isHeading(_ bytes: [UInt8], _ line: Range<Int>) -> Bool {
        let lead = indent(bytes, line)
        guard lead <= 3 else { return false }
        var index = line.lowerBound + lead
        var level = 0
        while index < line.upperBound, bytes[index] == 35 { level += 1; index += 1 }  // #
        return (1...6).contains(level) && (index == line.upperBound || bytes[index] == 32 || bytes[index] == 9)
    }

    private static func isBareListMarker(_ bytes: [UInt8], _ line: Range<Int>) -> Bool {
        var index = line.lowerBound + indent(bytes, line)
        guard index < line.upperBound else { return false }
        if bytes[index] == 45 || bytes[index] == 42 || bytes[index] == 43 {  // - * +
            index += 1
        } else {
            let digitsStart = index
            while index < line.upperBound, bytes[index] >= 48, bytes[index] <= 57 { index += 1 }
            guard index > digitsStart, index - digitsStart <= 9, index < line.upperBound,
                bytes[index] == 46 || bytes[index] == 41
            else { return false }
            index += 1
        }
        return isBlank(bytes, index..<line.upperBound)
    }

    private static func isDelimiterRow(_ bytes: [UInt8], _ line: Range<Int>) -> Bool {
        let slice = bytes[line]
        return slice.contains(45) && slice.allSatisfy { $0 == 124 || $0 == 45 || $0 == 58 || $0 == 32 || $0 == 9 || $0 == 13 }
    }

    /// A partial line that can only continue or start a plain paragraph (no block marker that more characters could
    /// turn into a list, heading, quote, fence, table, setext underline, HTML or reference definition).
    private static func isPlainParagraphStart(_ bytes: [UInt8], _ range: Range<Int>) -> Bool {
        let lead = indent(bytes, range)
        guard lead < 4 else { return false }
        let start = range.lowerBound + lead
        guard start < range.upperBound else { return false }
        let first = bytes[start]
        let markers: Set<UInt8> = [35, 124, 45, 42, 43, 62, 96, 126, 61, 60, 91, 95]  // # | - * + > ` ~ = < [ _
        if markers.contains(first) { return false }
        if first >= 48 && first <= 57 { return false }
        return !bytes[range].contains(124)
    }
}
