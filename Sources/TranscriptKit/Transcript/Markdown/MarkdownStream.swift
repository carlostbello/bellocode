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
///
/// Work per update is proportional to the new bytes and the open block, not the whole message (A28): the source is
/// not copied, the line buffer scans from the stable boundary, and "was the source extended or replaced?" is checked on
/// the newly stable bytes plus fixed-size windows of the old stable prefix while streaming (deltas only append), then
/// in full once by `finish`. `scannedBytes` counts the bytes each update examined (tests).
public struct MarkdownStream: Sendable {
    /// Final top-level constructs (source offsets are absolute UTF-8 offsets).
    public private(set) var stable: [TopLevelBlock] = []
    /// The constructs after `stable` (usually one: the block being written).
    public private(set) var open: [TopLevelBlock] = []
    /// UTF-8 offset where the unstable region starts.
    public private(set) var stableEnd = 0
    /// The source the stable blocks were parsed from (shared storage, never copied), to detect a source that was
    /// replaced instead of extended.
    private var stableSource = ""
    /// False once the text has a link reference definition (every update then parses the whole prefix).
    private var incremental = true
    /// The latest source and the length of its line-buffered prefix that the current blocks were parsed from.
    private var source = ""
    public private(set) var displayedUTF8Count = 0
    /// Bytes examined by updates so far (prefix checks, line buffering, parsing).
    public private(set) var scannedBytes = 0
    /// Bytes compared at each end of the old stable prefix by a streaming update's replacement check.
    static let checkWindow = 256

    public init() {}

    /// The text the current blocks were parsed from (the line-buffered prefix while streaming).
    public var displayed: String { String(decoding: source.utf8.prefix(displayedUTF8Count), as: UTF8.self) }

    public var blocks: [MarkdownBlock] { (stable + open).flatMap(\.blocks) }
    public var stableBlockCount: Int { stable.reduce(0) { $0 + $1.blocks.count } }

    /// Applies the latest source. Returns the number of leading blocks (flattened) that did not change.
    @discardableResult
    public mutating func update(_ source: String) -> Int { apply(source, finished: false) }

    /// Applies the complete source (no line buffering).
    @discardableResult
    public mutating func finish(_ source: String) -> Int { apply(source, finished: true) }

    /// Whether `next` still starts with the stable prefix. Finishing compares it all; a streaming update compares the
    /// windows at both ends of it (a streamed text only grows; a replaced one differs at its start or its end).
    private mutating func extendsStablePrefix(_ next: String, full: Bool) -> Bool {
        guard stableEnd > 0 else { return true }
        let old = stableSource.utf8
        let new = next.utf8
        guard new.count >= stableEnd else { return false }
        if full {
            scannedBytes += stableEnd
            return new.prefix(stableEnd).elementsEqual(old.prefix(stableEnd))
        }
        let window = Self.checkWindow
        let head = min(window, stableEnd)
        let tailStart = max(head, stableEnd - window)
        scannedBytes += head + (stableEnd - tailStart)
        guard new.prefix(head).elementsEqual(old.prefix(head)) else { return false }
        let newTail = new[new.index(new.startIndex, offsetBy: tailStart)..<new.index(new.startIndex, offsetBy: stableEnd)]
        let oldTail = old[old.index(old.startIndex, offsetBy: tailStart)..<old.index(old.startIndex, offsetBy: stableEnd)]
        return newTail.elementsEqual(oldTail)
    }

    private mutating func apply(_ source: String, finished: Bool) -> Int {
        if !extendsStablePrefix(source, full: finished) {
            let scanned = scannedBytes
            self = MarkdownStream()
            scannedBytes = scanned
        }
        self.source = source
        let utf8 = source.utf8
        let end: Int
        if finished {
            end = utf8.count
        } else {
            end = Self.displayEnd(source, from: stableEnd)
            scannedBytes += max(0, utf8.count - stableEnd)
        }
        displayedUTF8Count = end
        // Only the unstable region is new; earlier text was checked when it arrived.
        let from = utf8.index(utf8.startIndex, offsetBy: min(stableEnd, end))
        let to = utf8.index(utf8.startIndex, offsetBy: end)
        if incremental, MarkdownParser.hasReferenceDefinitions(Substring(source[from..<to])) { incremental = false }
        guard incremental else {
            stable = []
            stableEnd = 0
            stableSource = ""
            scannedBytes += end
            open = MarkdownParser.parse(String(decoding: utf8.prefix(end), as: UTF8.self))
            return 0
        }
        let unchanged = stableBlockCount
        guard end >= stableEnd else { return unchanged }
        let suffix = String(decoding: utf8[from..<to], as: UTF8.self)
        scannedBytes += end - stableEnd
        var parsed = MarkdownParser.parse(suffix)
        for index in parsed.indices {
            parsed[index].sourceStart += stableEnd
            parsed[index].sourceEnd += stableEnd
        }
        if parsed.count >= 2 {
            let newStable = parsed[0..<(parsed.count - 1)]
            stable += newStable
            stableEnd = parsed[parsed.count - 1].sourceStart
            stableSource = source
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
        String(decoding: source.utf8.prefix(displayEnd(source, from: start)), as: UTF8.self)
    }

    /// The UTF-8 length of `displayPrefix(source, from: start)`. Reads only the bytes from `start` on.
    static func displayEnd(_ source: String, from start: Int) -> Int {
        let utf8 = source.utf8
        let begin = min(start, utf8.count)
        // Offsets below stay absolute: the scanned bytes are indexed from `begin`.
        let window = Array(utf8[utf8.index(utf8.startIndex, offsetBy: begin)...])
        return begin + displayEnd(window)
    }

    /// The line-buffered length of `bytes` (a region starting at a top-level block boundary).
    private static func displayEnd(_ bytes: [UInt8]) -> Int {
        let begin = 0
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
        return end
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
