import AppKit
import CoreText
import DesignSystem

/// Cache key of a laid-out thread row: identity, width, expansion and content generation.
struct DiffAnnotationLayoutKey: Hashable {
    var id: String
    var width: Int
    var expanded: Bool
    var generation: Int
}

/// A thread row laid out for one width: its height and, when expanded, each note's wrapped body lines.
struct DiffAnnotationLayout {
    struct NoteLayout {
        var header: CTLine
        var lines: [CTLine]
        var cut: Bool
    }

    var height: CGFloat
    var notes: [NoteLayout]
}

/// Review threads drawn inline (GitLab 2, docs/features/gitlab.md "Inline review"): a `raised` card with a `border`
/// ring inset under its line, a status glyph and word (never colour alone), author, time and a summary; expanded, each
/// note with its author and body (wrapped, at most `maxBodyLines` per note). Layout is cached per width; only visible
/// rows are drawn, so the diff stays virtualised.
extension DiffContentView {
    static let annotationHeaderHeight: CGFloat = 26
    static let annotationMargin: CGFloat = 4
    static let maxBodyLines = 40

    func annotationCardRect(_ rect: CGRect) -> CGRect {
        let left = (layoutMode == .unified ? 2 * gutterWidth : gutterWidth) + 6
        return CGRect(x: left, y: rect.minY + Self.annotationMargin, width: max(80, rect.width - left - 12), height: rect.height - 2 * Self.annotationMargin)
    }

    func annotationLayout(_ index: Int) -> DiffAnnotationLayout {
        let annotation = rows.annotations[index]
        let expanded = rows.expandedAnnotations.contains(annotation.id)
        let cardWidth = max(80, bounds.width - ((layoutMode == .unified ? 2 * gutterWidth : gutterWidth) + 6) - 12)
        let key = DiffAnnotationLayoutKey(id: annotation.id, width: Int(cardWidth), expanded: expanded, generation: generation)
        return annotationCache.value(for: key) {
            let collapsedHeight = Self.annotationHeaderHeight + 2 * Self.annotationMargin + 2
            guard expanded else { return DiffAnnotationLayout(height: collapsedHeight, notes: []) }
            let textWidth = Double(cardWidth - 28)
            let lineHeight = ceil(CTFontGetAscent(theme.proseFont) + CTFontGetDescent(theme.proseFont) + CTFontGetLeading(theme.proseFont)) + 3
            var height = Self.annotationHeaderHeight + 2 * Self.annotationMargin + 4
            var notes: [DiffAnnotationLayout.NoteLayout] = []
            for note in annotation.notes {
                let header = NSMutableAttributedString(string: "@" + note.author, attributes: [.font: theme.uiBoldFont, .foregroundColor: theme.text])
                header.append(NSAttributedString(string: (note.time.isEmpty ? "" : "  " + note.time) + (note.isDraft ? "  · Draft, not sent" : ""), attributes: [.font: theme.metaFont, .foregroundColor: note.isDraft ? theme.warningText : theme.text3]))
                let text = NSAttributedString(string: note.body.isEmpty ? " " : note.body, attributes: [.font: theme.proseFont, .foregroundColor: theme.text])
                let typesetter = CTTypesetterCreateWithAttributedString(text)
                var lines: [CTLine] = []
                var start = 0
                let length = text.length
                var cut = false
                while start < length {
                    if lines.count >= Self.maxBodyLines {
                        cut = true
                        break
                    }
                    var count = CTTypesetterSuggestLineBreak(typesetter, start, max(40, textWidth))
                    if count <= 0 { count = 1 }
                    lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
                    start += count
                }
                notes.append(DiffAnnotationLayout.NoteLayout(header: CTLineCreateWithAttributedString(header), lines: lines, cut: cut))
                height += 20 + CGFloat(lines.count + (cut ? 1 : 0)) * lineHeight + 8
            }
            return DiffAnnotationLayout(height: ceil(height), notes: notes)
        }
    }

    func annotationHeight(_ index: Int) -> CGFloat {
        guard rows.annotations.indices.contains(index) else { return theme.rowHeight }
        return annotationLayout(index).height
    }

    func tone(_ state: DiffAnnotation.State) -> CGColor {
        switch state {
        case .unresolved: theme.warningText
        case .resolved: theme.successText
        case .draft: theme.warningText
        case .comment: theme.infoText
        case .outdated: theme.text3
        }
    }

    func drawAnnotation(_ index: Int, index rowIndex: Int, rect: CGRect, in context: CGContext) {
        guard rows.annotations.indices.contains(index) else { return }
        let annotation = rows.annotations[index]
        let expanded = rows.expandedAnnotations.contains(annotation.id)
        let layout = annotationLayout(index)
        let card = annotationCardRect(rect)
        let path = CGPath(roundedRect: card, cornerWidth: DS.Radius.md, cornerHeight: DS.Radius.md, transform: nil)
        context.setFillColor(theme.cardFill)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(theme.cardBorder)
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), cornerWidth: DS.Radius.md, cornerHeight: DS.Radius.md, transform: nil))
        context.strokePath()
        if currentAnnotationRow == rowIndex {
            context.setFillColor(theme.focusBar)
            context.fill(CGRect(x: card.minX, y: card.minY + 4, width: 2, height: card.height - 8))
        }
        // Header: status glyph, state word, author, time or note, summary when collapsed, chevron.
        let header = CGRect(x: card.minX, y: card.minY, width: card.width, height: Self.annotationHeaderHeight)
        var x = card.minX + 10
        let color = tone(annotation.state.primary)
        if let glyph = DSDraw.symbol(annotation.state.primary.symbolName, pointSize: DS.Size.iconPointMeta) {
            drawSymbol(glyph, in: CGRect(x: x, y: header.minY, width: 14, height: header.height), color: color, context: context)
        }
        x += 20
        let word = uiLine(annotation.state.words, font: theme.uiBoldFont, color: color)
        draw(word, x: x, rect: header, in: context)
        x += CTLineGetTypographicBounds(word, nil, nil, nil) + 10
        let chevronWidth: CGFloat = 22
        let first = annotation.notes.first
        var detail = "@\(first?.author ?? "")"
        if let time = first?.time, !time.isEmpty { detail += " · \(time)" }
        if annotation.notes.count > 1 { detail += " · \(annotation.notes.count) notes" }
        if let note = annotation.note { detail += " · \(note)" }
        if !expanded, let body = first?.body.split(separator: "\n").first { detail += " — " + body }
        let available = card.maxX - chevronWidth - x - 4
        if available > 30 { draw(truncated(detail, font: theme.uiFont, color: theme.text2, width: available), x: x, rect: header, in: context) }
        if let chevron = DSDraw.symbol(expanded ? "chevron.down" : "chevron.right", pointSize: DS.Size.iconPointMeta) {
            drawSymbol(chevron, in: CGRect(x: card.maxX - chevronWidth, y: header.minY, width: 12, height: header.height), color: theme.text3, context: context)
        }
        guard expanded else { return }
        context.setFillColor(theme.border)
        context.fill(CGRect(x: card.minX + 1, y: header.maxY, width: card.width - 2, height: 1))
        let lineHeight = ceil(CTFontGetAscent(theme.proseFont) + CTFontGetDescent(theme.proseFont) + CTFontGetLeading(theme.proseFont)) + 3
        var y = header.maxY + 4
        let textX = card.minX + 14
        for note in layout.notes {
            draw(note.header, x: textX, rect: CGRect(x: textX, y: y, width: card.width, height: 20), in: context)
            y += 20
            for line in note.lines {
                if y > rect.maxY { break }
                draw(line, x: textX, rect: CGRect(x: textX, y: y, width: card.width, height: lineHeight), in: context)
                y += lineHeight
            }
            if note.cut {
                draw(uiLine("… (longer on GitLab)", font: theme.metaFont, color: theme.text3), x: textX, rect: CGRect(x: textX, y: y, width: card.width, height: lineHeight), in: context)
                y += lineHeight
            }
            y += 8
        }
    }
}
