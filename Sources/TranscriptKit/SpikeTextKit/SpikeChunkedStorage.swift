// G1-A spike: a chunked NSTextStorage. The stock NSConcreteTextStorage keeps attributes in one run-length array, so
// inserting N runs at offset k memmoves every run after k, N times: prepending 100 messages to a 10,000-message
// transcript (484k runs) took 391 ms on the main thread, and replacing the whole content took 53 s. Here each chunk
// (one per message) owns its attributes; edits touch one chunk, and the chunk index is a prefix-sum array.
//
// The character string is a single NSMutableString (front inserts are one memmove of the UTF-16 buffer).

import AppKit

public final class SpikeChunkedStorage: NSTextStorage {
    private let backing = NSMutableString()
    private var chunks: [NSMutableAttributedString] = []
    /// starts[i] = UTF-16 offset of chunk i; valid for i < startsValid.
    private var starts: [Int] = []
    private var startsValid = 0

    override public init() { super.init() }
    required init?(coder: NSCoder) { fatalError("not used") }
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        fatalError("not used")
    }

    public var chunkCount: Int { chunks.count }

    // MARK: Primitives

    /// Swift bridges NSMutableString to String by copying the UTF-16 buffer, so the bridged value is cached until
    /// the next character edit (one ~1–2 ms copy per edit for 7.8M characters). A production storage written in
    /// Objective-C would return the mutable string directly.
    private var cachedString: String?
    override public var string: String {
        if let cachedString { return cachedString }
        let value = backing.copy() as! String
        cachedString = value
        return value
    }
    override public var length: Int { backing.length }
    /// Fix fonts/paragraph styles/attachments on access (TextKit asks for the ranges it lays out), not on insert.
    override public var fixesAttributesLazily: Bool { true }

    private func revalidateStarts(through index: Int) {
        guard startsValid <= index else { return }
        if starts.count != chunks.count { starts = Array(repeating: 0, count: chunks.count) }
        var location = startsValid == 0 ? 0 : starts[startsValid - 1] + chunks[startsValid - 1].length
        for i in startsValid..<chunks.count {
            starts[i] = location
            location += chunks[i].length
        }
        startsValid = chunks.count
    }

    /// The chunk containing `location` (for location == length, the last chunk).
    private func chunkIndex(at location: Int) -> Int {
        revalidateStarts(through: chunks.count - 1)
        var low = 0, high = chunks.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low // the last chunk starting at or before `location`, so empty chunks are skipped
    }

    /// NSTextStorage.fixAttributes asks for the longest effective range of NSGlyphInfo across the whole document
    /// on every edit. The generic implementation walks every attribute run through `attributes(at:)` (488k Swift
    /// dictionary bridges, ~470 ms). This walks chunks instead and lets each chunk answer natively.
    override public func attribute(_ attrName: NSAttributedString.Key, at location: Int,
                                   longestEffectiveRange range: NSRangePointer?, in rangeLimit: NSRange) -> Any? {
        guard !chunks.isEmpty else { range?.pointee = NSRange(location: location, length: 0); return nil }
        let index = chunkIndex(at: location)
        let start = starts[index]
        func localLimit(_ i: Int) -> NSRange {
            let chunkRange = NSRange(location: starts[i], length: chunks[i].length)
            let clipped = NSIntersectionRange(chunkRange, rangeLimit)
            return NSRange(location: clipped.location - starts[i], length: clipped.length)
        }
        var local = NSRange()
        let value = chunks[index].attribute(attrName, at: location - start, longestEffectiveRange: &local, in: localLimit(index))
        guard let range else { return value }
        var lower = local.location + start
        var upper = local.upperBound + start
        func same(_ other: Any?) -> Bool {
            switch (value, other) {
            case (nil, nil): return true
            case let (a?, b?): return (a as AnyObject).isEqual(b)
            default: return false
            }
        }
        // Extend backwards across chunk boundaries while the value continues.
        var i = index
        while lower == starts[i], lower > rangeLimit.location, i > 0 {
            i -= 1
            guard chunks[i].length > 0 else { continue }
            var r = NSRange()
            let lim = localLimit(i)
            let v = chunks[i].attribute(attrName, at: lim.upperBound - 1, longestEffectiveRange: &r, in: lim)
            guard same(v) else { break }
            lower = r.location + starts[i]
        }
        i = index
        while upper == starts[i] + chunks[i].length, upper < rangeLimit.upperBound, i < chunks.count - 1 {
            i += 1
            guard chunks[i].length > 0 else { continue }
            var r = NSRange()
            let lim = localLimit(i)
            let v = chunks[i].attribute(attrName, at: lim.location, longestEffectiveRange: &r, in: lim)
            guard same(v) else { break }
            upper = r.upperBound + starts[i]
        }
        range.pointee = NSRange(location: lower, length: upper - lower)
        return value
    }

    override public func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        guard !chunks.isEmpty else { range?.pointee = NSRange(location: 0, length: 0); return [:] }
        let index = chunkIndex(at: location)
        let start = starts[index]
        var local = NSRange()
        let attributes = chunks[index].attributes(at: location - start, effectiveRange: &local)
        range?.pointee = NSRange(location: local.location + start, length: local.length)
        return attributes
    }

    override public func replaceCharacters(in range: NSRange, with attrString: NSAttributedString) {
        replace(range, attributed: attrString, plain: nil)
    }

    override public func replaceCharacters(in range: NSRange, with str: String) {
        replace(range, attributed: nil, plain: str)
    }

    override public func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        guard range.length > 0 else { return }
        beginEditing()
        var location = range.location
        while location < range.upperBound {
            let index = chunkIndex(at: location)
            let start = starts[index]
            let end = min(range.upperBound, start + chunks[index].length)
            chunks[index].setAttributes(attrs, range: NSRange(location: location - start, length: end - location))
            location = end
        }
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    // MARK: Editing

    private func replace(_ range: NSRange, attributed: NSAttributedString?, plain: String?) {
        let newLength = attributed?.length ?? (plain! as NSString).length
        beginEditing()
        if chunks.isEmpty {
            let chunk = attributed.map { NSMutableAttributedString(attributedString: $0) }
                ?? NSMutableAttributedString(string: plain!)
            chunks = [chunk]
            startsValid = 0
        } else {
            let first = chunkIndex(at: range.location)
            let last = range.length > 0 ? chunkIndex(at: range.upperBound - 1) : first
            if first == last {
                let local = NSRange(location: range.location - starts[first], length: range.length)
                if let attributed { chunks[first].replaceCharacters(in: local, with: attributed) }
                else { chunks[first].replaceCharacters(in: local, with: plain!) }
            } else {
                // Spanning edit: merge the affected chunks into one (rare: only generic NSTextStorage callers).
                let merged = NSMutableAttributedString()
                for i in first...last { merged.append(chunks[i]) }
                let local = NSRange(location: range.location - starts[first], length: range.length)
                if let attributed { merged.replaceCharacters(in: local, with: attributed) }
                else { merged.replaceCharacters(in: local, with: plain!) }
                chunks.replaceSubrange(first...last, with: [merged])
            }
            startsValid = min(startsValid, first + 1)
        }
        cachedString = nil
        if let attributed { backing.replaceCharacters(in: range, with: attributed.string) }
        else { backing.replaceCharacters(in: range, with: plain!) }
        edited([.editedCharacters, .editedAttributes], range: range, changeInLength: newLength - range.length)
        endEditing()
    }

    // MARK: Chunk-level API (the transcript's message boundaries)

    public func chunkRange(_ index: Int) -> NSRange {
        revalidateStarts(through: index)
        return NSRange(location: starts[index], length: chunks[index].length)
    }

    /// Inserts whole chunks before chunk `index` (index == chunkCount appends). One edit notification.
    public func insertChunks(_ new: [NSAttributedString], at index: Int) {
        guard !new.isEmpty else { return }
        let location = index < chunks.count ? chunkRange(index).location : length
        var total = 0
        let text = NSMutableString()
        for chunk in new { text.append(chunk.string); total += chunk.length }
        beginEditing()
        chunks.insert(contentsOf: new.map { NSMutableAttributedString(attributedString: $0) }, at: index)
        startsValid = min(startsValid, index)
        cachedString = nil
        backing.insert(text as String, at: location)
        edited([.editedCharacters, .editedAttributes], range: NSRange(location: location, length: 0), changeInLength: total)
        endEditing()
    }

    /// Replaces a range inside chunk `index` (local coordinates). One edit notification.
    public func replace(inChunk index: Int, localRange: NSRange, with replacement: NSAttributedString) {
        let start = chunkRange(index).location
        beginEditing()
        chunks[index].replaceCharacters(in: localRange, with: replacement)
        startsValid = min(startsValid, index + 1)
        let range = NSRange(location: start + localRange.location, length: localRange.length)
        cachedString = nil
        backing.replaceCharacters(in: range, with: replacement.string)
        edited([.editedCharacters, .editedAttributes], range: range, changeInLength: replacement.length - localRange.length)
        endEditing()
    }
}
