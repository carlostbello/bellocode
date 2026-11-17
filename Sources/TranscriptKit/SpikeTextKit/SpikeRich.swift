// G1-A spike: a Sendable intermediate representation of styled transcript text.
//
// Parsing and styling produce `SpikeRich` values off the main actor (they are plain values, so task groups can
// build them in parallel). `SpikeMaterializer` turns them into an NSAttributedString; it is nonisolated and runs
// off-main for bulk loads (the result is returned with `sending`) and on-main only for small tail updates.

import AppKit

/// Block decoration drawn by `SpikeBlockFragment` behind a paragraph.
public enum SpikeBlock: UInt8, Sendable {
    case none, roleLabel, user, code, toolHeader, toolBody, reasoningHeader, reasoningBody
    case diffHeader, diffHunk, diffAdd, diffDel, diffContext, table, image
}

/// Where a paragraph sits inside a multi-paragraph block (for rounded corners and padding).
public enum SpikePos: UInt8, Sendable { case only, first, middle, last }

public struct SpikeParaStyle: Hashable, Sendable {
    public var block: SpikeBlock = .none
    public var pos: SpikePos = .only
    public var listDepth: UInt8 = 0
    public var isList = false
    public var heading: UInt8 = 0
    /// Table column widths in monospaced character cells.
    public var columns: [Int] = []

    public init(block: SpikeBlock = .none, pos: SpikePos = .only) { self.block = block; self.pos = pos }
}

public enum SpikeInline: UInt8, Sendable {
    case body, bold, italic, inlineCode, link, heading1, heading2, heading3
    case roleLabel, secondary, reasoning, code, codeKeyword, codeString, codeComment, codeNumber, codeType
    case toolHeader, toolStatusOK, toolStatusBad, toolBody, diffHeader, diffHunk, diffAdd, diffDel, diffContext
    case tableHeader, tableCell, caption
}

public struct SpikeSpan: Sendable {
    public var location: Int
    public var length: Int
    public var value: String
}

public struct SpikeRich: Sendable {
    public private(set) var text = ""
    public private(set) var length = 0 // UTF-16
    public private(set) var runs: [(length: Int, style: SpikeInline)] = []
    public private(set) var paragraphs: [(length: Int, style: SpikeParaStyle)] = []
    public var links: [SpikeSpan] = []
    public var cardHeaders: [SpikeSpan] = []
    public var cardBodies: [SpikeSpan] = []
    public var images: [(location: Int, image: SpikeImage)] = []
    private var paragraphStart = 0

    public init() {}

    public mutating func append(_ string: some StringProtocol, _ style: SpikeInline) {
        let count = string.utf16.count
        guard count > 0 else { return }
        text += string
        length += count
        if let last = runs.last, last.style == style {
            runs[runs.count - 1].length += count
        } else {
            runs.append((count, style))
        }
    }

    public mutating func appendLink(_ label: String, url: String) {
        links.append(SpikeSpan(location: length, length: label.utf16.count, value: url))
        append(label, .link)
    }

    public mutating func appendImage(_ image: SpikeImage) {
        images.append((length, image))
        append("\u{FFFC}", .body)
    }

    /// Ends the current paragraph with a newline and records its paragraph style.
    public mutating func endParagraph(_ style: SpikeParaStyle) {
        append("\n", runs.last?.style ?? .body)
        paragraphs.append((length - paragraphStart, style))
        paragraphStart = length
    }

    public var paragraphCount: Int { paragraphs.count }

    public mutating func updateParagraph(_ index: Int, _ body: (inout SpikeParaStyle) -> Void) {
        body(&paragraphs[index].style)
    }

    public mutating func append(_ other: SpikeRich) {
        let offset = length
        text += other.text
        length += other.length
        runs += other.runs
        paragraphs += other.paragraphs
        paragraphStart = length
        links += other.links.map { SpikeSpan(location: $0.location + offset, length: $0.length, value: $0.value) }
        cardHeaders += other.cardHeaders.map { SpikeSpan(location: $0.location + offset, length: $0.length, value: $0.value) }
        cardBodies += other.cardBodies.map { SpikeSpan(location: $0.location + offset, length: $0.length, value: $0.value) }
        images += other.images.map { ($0.location + offset, $0.image) }
    }
}

// MARK: - Attribute keys

extension NSAttributedString.Key {
    /// NSNumber: `SpikeBlock.rawValue << 8 | SpikePos.rawValue`, read by the layout fragment to draw backgrounds.
    public static let spikeBlock = NSAttributedString.Key("bello.spike.block")
    /// String: the server message ID that owns this text (row identity is the server ID).
    public static let spikeMessage = NSAttributedString.Key("bello.spike.message")
    /// String: card ID on a collapsible card's header paragraph.
    public static let spikeCard = NSAttributedString.Key("bello.spike.card")
    /// String: card ID on an expanded card's body.
    public static let spikeCardBody = NSAttributedString.Key("bello.spike.cardBody")
    /// String: image ID on an image attachment character.
    public static let spikeImage = NSAttributedString.Key("bello.spike.image")
}

public enum SpikeToggleURL {
    public static let scheme = "bello-toggle"
    public static func make(_ id: String) -> URL { URL(string: "\(scheme)://\(id)")! }
}

// MARK: - Theme and materializer

public struct SpikeTheme: Sendable {
    public var bodySize: CGFloat = 13
    public var codeSize: CGFloat = 12
    public var toolSize: CGFloat = 11.5
    public var blockInset: CGFloat = 12
    public init() {}
}

/// Builds attributed strings from `SpikeRich`. Not Sendable (caches AppKit objects); create one per task.
public final class SpikeMaterializer {
    let theme: SpikeTheme
    private let body: NSFont
    private let mono: NSFont
    private let monoBold: NSFont
    private let toolFont: NSFont
    private let monoAdvance: CGFloat
    private var inlineCache: [SpikeInline: [NSAttributedString.Key: Any]] = [:]
    private var paragraphCache: [SpikeParaStyle: NSParagraphStyle] = [:]
    private var blockNumbers: [UInt16: NSNumber] = [:]
    /// Called on the main actor when an image attachment is first drawn (set by the document).
    public var imageRequest: (@MainActor (String) -> Void)?

    public init(theme: SpikeTheme = SpikeTheme()) {
        self.theme = theme
        body = NSFont.systemFont(ofSize: theme.bodySize)
        mono = NSFont.monospacedSystemFont(ofSize: theme.codeSize, weight: .regular)
        monoBold = NSFont.monospacedSystemFont(ofSize: theme.codeSize, weight: .semibold)
        toolFont = NSFont.monospacedSystemFont(ofSize: theme.toolSize, weight: .regular)
        monoAdvance = mono.maximumAdvancement.width
    }

    /// One attributed string for several messages; each message's text carries its ID.
    public func materialize(_ items: [(id: String, rich: SpikeRich)]) -> NSMutableAttributedString {
        var total = ""
        var totalLength = 0
        for item in items { total += item.rich.text; totalLength += item.rich.length }
        let result = NSMutableAttributedString(string: total)
        result.beginEditing()
        var offset = 0
        for item in items {
            apply(item.rich, to: result, at: offset, messageID: item.id)
            offset += item.rich.length
        }
        result.endEditing()
        return result
    }

    public func materialize(_ rich: SpikeRich, messageID: String) -> NSMutableAttributedString {
        materialize([(messageID, rich)])
    }

    private func apply(_ rich: SpikeRich, to string: NSMutableAttributedString, at base: Int, messageID: String) {
        var location = base
        for run in rich.runs {
            string.setAttributes(inlineAttributes(run.style), range: NSRange(location: location, length: run.length))
            location += run.length
        }
        location = base
        for paragraph in rich.paragraphs {
            let range = NSRange(location: location, length: paragraph.length)
            string.addAttribute(.paragraphStyle, value: paragraphStyle(paragraph.style), range: range)
            if paragraph.style.block != .none {
                string.addAttribute(.spikeBlock, value: blockNumber(paragraph.style), range: range)
            }
            if paragraph.style.heading > 0 {
                let size = theme.bodySize + CGFloat(4 - Int(paragraph.style.heading)) * 2 + 1
                string.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .bold), range: range)
            }
            location += paragraph.length
        }
        string.addAttribute(.spikeMessage, value: messageID, range: NSRange(location: base, length: rich.length))
        for link in rich.links {
            if let url = URL(string: link.value) {
                string.addAttribute(.link, value: url, range: NSRange(location: base + link.location, length: link.length))
            }
        }
        for header in rich.cardHeaders {
            let range = NSRange(location: base + header.location, length: header.length)
            string.addAttribute(.spikeCard, value: header.value, range: range)
            // The disclosure line is a link: clicking it toggles the card (no view-backed attachment needed).
            string.addAttribute(.link, value: SpikeToggleURL.make(header.value), range: NSRange(location: range.location, length: max(1, range.length - 1)))
        }
        for card in rich.cardBodies {
            string.addAttribute(.spikeCardBody, value: card.value, range: NSRange(location: base + card.location, length: card.length))
        }
        for item in rich.images {
            let attachment = SpikeImageAttachment(spec: item.image)
            attachment.onFirstDraw = imageRequest
            let range = NSRange(location: base + item.location, length: 1)
            string.addAttribute(.attachment, value: attachment, range: range)
            string.addAttribute(.spikeImage, value: item.image.id, range: range)
        }
    }

    private func blockNumber(_ style: SpikeParaStyle) -> NSNumber {
        let key = UInt16(style.block.rawValue) << 8 | UInt16(style.pos.rawValue)
        if let cached = blockNumbers[key] { return cached }
        let number = NSNumber(value: key)
        blockNumbers[key] = number
        return number
    }

    private func inlineAttributes(_ style: SpikeInline) -> [NSAttributedString.Key: Any] {
        if let cached = inlineCache[style] { return cached }
        var a: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.labelColor]
        switch style {
        case .body: break
        case .bold: a[.font] = NSFont.systemFont(ofSize: theme.bodySize, weight: .semibold)
        case .italic: a[.font] = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
        case .inlineCode:
            a[.font] = NSFont.monospacedSystemFont(ofSize: theme.bodySize - 1, weight: .regular)
            a[.backgroundColor] = NSColor.quaternaryLabelColor
        case .link:
            a[.foregroundColor] = NSColor.linkColor
            a[.underlineStyle] = NSUnderlineStyle.single.rawValue
        case .heading1, .heading2, .heading3: a[.font] = NSFont.systemFont(ofSize: theme.bodySize + 3, weight: .bold)
        case .roleLabel:
            a[.font] = NSFont.systemFont(ofSize: theme.bodySize - 2, weight: .semibold)
            a[.foregroundColor] = NSColor.secondaryLabelColor
        case .secondary, .caption:
            a[.font] = NSFont.systemFont(ofSize: theme.bodySize - 1)
            a[.foregroundColor] = NSColor.secondaryLabelColor
        case .reasoning:
            a[.font] = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
            a[.foregroundColor] = NSColor.secondaryLabelColor
        case .code: a[.font] = mono
        case .codeKeyword: a[.font] = monoBold; a[.foregroundColor] = NSColor.systemPink
        case .codeString: a[.font] = mono; a[.foregroundColor] = NSColor.systemRed
        case .codeComment: a[.font] = mono; a[.foregroundColor] = NSColor.systemGreen
        case .codeNumber: a[.font] = mono; a[.foregroundColor] = NSColor.systemBlue
        case .codeType: a[.font] = mono; a[.foregroundColor] = NSColor.systemPurple
        case .toolHeader: a[.font] = NSFont.systemFont(ofSize: theme.bodySize - 1, weight: .medium)
        case .toolStatusOK:
            a[.font] = NSFont.systemFont(ofSize: theme.bodySize - 1, weight: .medium)
            a[.foregroundColor] = NSColor.systemGreen
        case .toolStatusBad:
            a[.font] = NSFont.systemFont(ofSize: theme.bodySize - 1, weight: .medium)
            a[.foregroundColor] = NSColor.systemRed
        case .toolBody: a[.font] = toolFont; a[.foregroundColor] = NSColor.secondaryLabelColor
        case .diffHeader: a[.font] = monoBold
        case .diffHunk: a[.font] = mono; a[.foregroundColor] = NSColor.systemTeal
        case .diffAdd, .diffDel, .diffContext: a[.font] = mono
        case .tableHeader: a[.font] = monoBold
        case .tableCell: a[.font] = mono
        }
        inlineCache[style] = a
        return a
    }

    private func paragraphStyle(_ style: SpikeParaStyle) -> NSParagraphStyle {
        if let cached = paragraphCache[style] { return cached }
        let p = NSMutableParagraphStyle()
        let inset = theme.blockInset
        let first = style.pos == .first || style.pos == .only
        let last = style.pos == .last || style.pos == .only
        switch style.block {
        case .none:
            p.paragraphSpacing = 6
            p.lineHeightMultiple = 1.08
            if style.isList {
                let indent = 6 + CGFloat(style.listDepth) * 18
                p.firstLineHeadIndent = indent
                p.headIndent = indent + 16
                p.tabStops = [NSTextTab(textAlignment: .left, location: indent + 16)]
                p.paragraphSpacing = 2
            }
            if style.heading > 0 { p.paragraphSpacingBefore = 6 }
        case .roleLabel:
            p.paragraphSpacingBefore = 14
            p.paragraphSpacing = 2
        case .user:
            p.firstLineHeadIndent = inset
            p.headIndent = inset
            p.tailIndent = -inset
            p.paragraphSpacingBefore = first ? 8 : 0
            p.paragraphSpacing = last ? 8 : 6
            if style.isList {
                let indent = inset + 6 + CGFloat(style.listDepth) * 18
                p.firstLineHeadIndent = indent
                p.headIndent = indent + 16
                p.tabStops = [NSTextTab(textAlignment: .left, location: indent + 16)]
            }
        case .code, .toolBody, .reasoningBody, .diffHunk, .diffAdd, .diffDel, .diffContext, .table:
            p.firstLineHeadIndent = inset
            p.headIndent = inset + (style.block == .reasoningBody ? 0 : 2 * monoAdvance)
            p.tailIndent = -inset
            p.paragraphSpacingBefore = first ? 8 : 0
            p.paragraphSpacing = last ? 8 : 0
            if style.block == .reasoningBody { p.paragraphSpacing = last ? 8 : 4 }
            p.lineBreakMode = .byCharWrapping
            if style.block == .table {
                var x = inset
                var stops: [NSTextTab] = []
                for width in style.columns.dropLast() {
                    x += CGFloat(width + 3) * monoAdvance
                    stops.append(NSTextTab(textAlignment: .left, location: x))
                }
                p.tabStops = stops
                p.headIndent = inset
            }
        case .toolHeader, .reasoningHeader, .diffHeader:
            p.firstLineHeadIndent = inset
            p.headIndent = inset + 14
            p.tailIndent = -inset
            p.paragraphSpacingBefore = 8
            p.paragraphSpacing = last ? 8 : 0
        case .image:
            p.firstLineHeadIndent = inset
            p.paragraphSpacingBefore = 6
            p.paragraphSpacing = 6
        }
        paragraphCache[style] = p
        return p
    }
}
