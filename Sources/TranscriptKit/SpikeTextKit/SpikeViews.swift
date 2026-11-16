// G1-A spike: TextKit 2 view layer. One NSTextView (TextKit 2) in an NSScrollView; block backgrounds are drawn by a
// custom NSTextLayoutFragment, so code blocks, cards, diffs and tables stay plain text in one selection domain.

import AppKit

// MARK: - Layout fragment that draws block backgrounds

final class SpikeBlockFragment: NSTextLayoutFragment {
    let block: SpikeBlock
    let pos: SpikePos

    init(textElement: NSTextElement, range: NSTextRange?, code: UInt16) {
        block = SpikeBlock(rawValue: UInt8(code >> 8)) ?? .none
        pos = SpikePos(rawValue: UInt8(code & 0xFF)) ?? .only
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var isFirst: Bool { pos == .first || pos == .only }
    private var isLast: Bool { pos == .last || pos == .only }

    /// Background rectangle in fragment coordinates, spanning the container width.
    private var backgroundRect: CGRect {
        let frame = layoutFragmentFrame
        let width = textLayoutManager?.textContainer?.size.width ?? frame.width
        var top: CGFloat = 0
        var bottom = frame.height
        if isFirst, let line = textLineFragments.first { top = max(0, line.typographicBounds.minY - 5) }
        if isLast, let line = textLineFragments.last { bottom = min(frame.height, line.typographicBounds.maxY + 5) }
        return CGRect(x: 6 - frame.minX, y: top, width: max(0, width - 12), height: max(0, bottom - top))
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(backgroundRect)
    }

    private var fillColor: CGColor? {
        switch block {
        case .none, .roleLabel, .image: return nil
        case .user: return CGColor(srgbRed: 0.20, green: 0.45, blue: 0.95, alpha: 0.08)
        case .code: return CGColor(gray: 0, alpha: 0.045)
        case .toolHeader: return CGColor(gray: 0, alpha: 0.06)
        case .toolBody: return CGColor(gray: 0, alpha: 0.03)
        case .reasoningHeader: return CGColor(srgbRed: 0.55, green: 0.35, blue: 0.85, alpha: 0.08)
        case .reasoningBody: return CGColor(srgbRed: 0.55, green: 0.35, blue: 0.85, alpha: 0.04)
        case .diffHeader: return CGColor(gray: 0, alpha: 0.07)
        case .diffHunk: return CGColor(srgbRed: 0.1, green: 0.55, blue: 0.6, alpha: 0.10)
        case .diffAdd: return CGColor(srgbRed: 0.1, green: 0.7, blue: 0.2, alpha: 0.15)
        case .diffDel: return CGColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 0.13)
        case .diffContext: return CGColor(gray: 0, alpha: 0.03)
        case .table: return isFirst ? CGColor(gray: 0, alpha: 0.07) : CGColor(gray: 0, alpha: 0.03)
        }
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let color = fillColor {
            let rect = backgroundRect.offsetBy(dx: point.x, dy: point.y)
            let radius: CGFloat = 6
            let path = CGMutablePath()
            let topRadius = isFirst ? radius : 0
            let bottomRadius = isLast ? radius : 0
            // Flipped coordinates: minY is the top edge.
            path.move(to: CGPoint(x: rect.minX + topRadius, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + topRadius), radius: topRadius)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius))
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY), radius: bottomRadius)
            path.addLine(to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY))
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius), radius: bottomRadius)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topRadius))
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + topRadius, y: rect.minY), radius: topRadius)
            path.closeSubpath()
            context.saveGState()
            context.addPath(path)
            context.setFillColor(color)
            context.fillPath()
            context.restoreGState()
        }
        super.draw(at: point, in: context)
    }
}

/// Supplies `SpikeBlockFragment` for paragraphs that carry a block decoration.
final class SpikeLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let code = paragraph.attributedString.attribute(.spikeBlock, at: 0, effectiveRange: nil) as? NSNumber {
            return SpikeBlockFragment(textElement: textElement, range: textElement.elementRange, code: code.uint16Value)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

// MARK: - Image attachment with asynchronous arrival

/// Placeholder until "delivered"; the first draw requests the image, which arrives after a delay and changes height.
public final class SpikeImageAttachment: NSTextAttachment {
    public let spec: SpikeImage
    public private(set) var isDelivered = false
    private var requested = false
    private var deliveredImage: NSImage?
    var onFirstDraw: (@MainActor (String) -> Void)?
    private static let placeholderSize = CGSize(width: 180, height: 28)

    init(spec: SpikeImage) {
        self.spec = spec
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public var requestedForDisplay: Bool { requested }

    @MainActor
    public func deliver() {
        guard !isDelivered else { return }
        let rgb = spec.rgb
        let size = CGSize(width: spec.width, height: spec.height)
        deliveredImage = NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                    blue: CGFloat(rgb & 0xFF) / 255, alpha: 1).setFill()
            rect.fill()
            return true
        }
        isDelivered = true
    }

    private func displaySize(maxWidth: CGFloat) -> CGSize {
        let natural = isDelivered ? CGSize(width: spec.width, height: spec.height) : Self.placeholderSize
        guard natural.width > maxWidth, maxWidth > 20 else { return natural }
        return CGSize(width: maxWidth, height: (natural.height * maxWidth / natural.width).rounded())
    }

    override public func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                          textContainer: NSTextContainer?, proposedLineFragment: CGRect,
                                          position: CGPoint) -> CGRect {
        CGRect(origin: .zero, size: displaySize(maxWidth: proposedLineFragment.width - 30))
    }

    override public func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any],
                               location: any NSTextLocation, textContainer: NSTextContainer?) -> NSImage? {
        if !requested {
            requested = true
            let id = spec.id
            if let request = onFirstDraw { MainActor.assumeIsolated { request(id) } }
        }
        if let deliveredImage { return deliveredImage }
        return placeholder
    }

    private lazy var placeholder: NSImage = NSImage(size: Self.placeholderSize, flipped: false) { rect in
        NSColor(white: 0.85, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        return true
    }
}

// MARK: - Text view and scroll view

public final class SpikeTextView: NSTextView {
    /// Plain-text copy: attachments become "[image …]", collapsed cards copy as their one-line summary.
    override public func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storage = textStorage else { return false }
        let text = SpikePlainText.make(storage, ranges: selectedRanges.map(\.rangeValue))
        pboard.clearContents()
        return pboard.setString(text, forType: .string)
    }

    override public var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
}

public enum SpikePlainText {
    public static func make(_ storage: NSAttributedString, ranges: [NSRange]) -> String {
        var out = ""
        let ns = storage.string as NSString
        for range in ranges where range.length > 0 {
            var cursor = range.location
            storage.enumerateAttribute(.spikeImage, in: range) { value, sub, _ in
                guard let id = value as? String else { return }
                if sub.location > cursor { out += ns.substring(with: NSRange(location: cursor, length: sub.location - cursor)) }
                let attachment = storage.attribute(.attachment, at: sub.location, effectiveRange: nil) as? SpikeImageAttachment
                out += "[image \(id) \(attachment?.spec.width ?? 0)×\(attachment?.spec.height ?? 0)]"
                cursor = sub.upperBound
            }
            if cursor < range.upperBound { out += ns.substring(with: NSRange(location: cursor, length: range.upperBound - cursor)) }
        }
        return out
    }
}

/// Reports user scroll-wheel input (real or synthesised) so the controller can release or rejoin follow mode.
public final class SpikeScrollView: NSScrollView {
    var onUserScroll: ((_ deltaY: CGFloat) -> Void)?

    override public func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onUserScroll?(event.scrollingDeltaY)
    }
}
