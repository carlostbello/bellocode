import AppKit
import DesignSystem
import Engine
import SwiftUI

/// A job log as a virtualised AppKit table: one fixed-height row per line, only visible rows exist, each row's
/// attributed string is built when it scrolls into view (bounded at `ParsedJobLog.maxLines`). ANSI colours map to the
/// design system's terminal and status tokens; GitLab section headers are emphasised. Text is selectable per line and
/// ⌘C copies the selected lines.
public final class JobLogView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private var log = ParsedJobLog("")

    public override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: .init("line"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.usesAutomaticRowHeights = false
        table.rowHeight = ceil(NSFont.ds(.codeSmall).boundingRectForFont.height) + 2
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.backgroundColor = DS.Color.canvas
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.setAccessibilityLabel("Job log")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = DS.Color.canvas
        DSScroller.install(on: scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Idempotent: the same log keeps the scroll position; a new one scrolls to its end (where failures are).
    public func show(_ log: ParsedJobLog) {
        guard log != self.log else { return }
        self.log = log
        let widest = log.lines.map(\.text.count).max() ?? 0
        let width = max(bounds.width, CGFloat(min(widest, 2_000)) * NSFont.ds(.codeSmall).maximumAdvancement.width + 24)
        table.tableColumns.first?.width = width
        table.reloadData()
        if !log.lines.isEmpty { table.scrollRowToVisible(log.lines.count - 1) }
    }

    public var lineCount: Int { log.lines.count }

    public func numberOfRows(in tableView: NSTableView) -> Int { log.lines.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("logLine")
        let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byClipping
            field.isSelectable = false
            field.drawsBackground = false
            return field
        }()
        field.attributedStringValue = Self.attributed(log.lines[row], number: row + 1 + log.omittedLines)
        return field
    }

    @objc func copy(_ sender: Any?) {
        let rows = table.selectedRowIndexes.isEmpty ? IndexSet(0..<log.lines.count) : table.selectedRowIndexes
        let text = rows.map { log.lines[$0].text }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func colour(_ index: Int?) -> NSColor {
        switch index {
        case 1, 9: DS.Color.dangerText
        case 2, 10: DS.Color.successText
        case 3, 11: DS.Color.warningText
        case 4, 12: DS.Color.infoText
        case 5, 13: DS.Color.ansiMagenta
        case 6, 14: DS.Color.ansiCyan
        case 0, 8: DS.Color.text3
        default: DS.Color.text
        }
    }

    static func attributed(_ line: ParsedJobLog.Line, number: Int) -> NSAttributedString {
        let font = NSFont.ds(.codeSmall)
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let result = NSMutableAttributedString(
            string: String(format: "%5d  ", number), attributes: [.font: font, .foregroundColor: DS.Color.text4])
        let body = NSMutableAttributedString(
            string: line.text, attributes: [.font: line.isSection ? bold : font, .foregroundColor: line.isSection ? DS.Color.text2 : DS.Color.text])
        let scalars = line.text.unicodeScalars.count
        for span in line.spans where span.range.upperBound <= scalars {
            let view = line.text.unicodeScalars
            let start = view.index(view.startIndex, offsetBy: span.range.lowerBound)
            let end = view.index(view.startIndex, offsetBy: span.range.upperBound)
            let range = NSRange(start..<end, in: line.text)
            body.addAttribute(.foregroundColor, value: colour(span.colour), range: range)
            if span.bold { body.addAttribute(.font, value: bold, range: range) }
        }
        result.append(body)
        return result
    }
}

/// SwiftUI host of `JobLogView`; updates are idempotent.
struct JobLogRepresentable: NSViewRepresentable {
    let log: ParsedJobLog

    func makeNSView(context: Context) -> JobLogView { JobLogView(frame: .zero) }
    func updateNSView(_ view: JobLogView, context: Context) { view.show(log) }
}
