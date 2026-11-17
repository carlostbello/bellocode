import AppKit
import Engine
import Testing

@testable import DiffKit

/// Review M6: the whole diff is reachable and operable through accessibility, not only the drawn rows.
@MainActor @Suite struct DiffAccessibilityTests {
    /// 3,000 lines with a change every 100 lines: many hunks and expandable gaps, far more rows than fit on screen.
    static func longFile() -> DiffFile {
        let old = (1...3_000).map { "line \($0)" }
        var new = old
        for index in stride(from: 50, to: 3_000, by: 100) { new[index] = "changed \(index + 1)" }
        return DiffFile.compute(path: "Sources/Long.swift", old: old.joined(separator: "\n") + "\n", new: new.joined(separator: "\n") + "\n")
    }

    func makeView() -> (DiffContentView, NSScrollView, NSWindow, DiffRows, [DiffFile]) {
        _ = NSApplication.shared
        let files = [Self.longFile()]
        let options = DiffRowOptions()
        var rows = DiffRowBuilder.build(files, options: options)
        if rows.rows.count <= DiffContentView.accessibilityElementLimit / 2 {
            // Repeat the file under other names until the document is large.
            var many: [DiffFile] = []
            for copy in 0..<12 {
                var file = files[0]
                file.path = "Sources/Long\(copy).swift"
                many.append(file)
            }
            rows = DiffRowBuilder.build(many, options: options)
            return finish(many, rows)
        }
        return finish(files, rows)
    }

    private func finish(_ files: [DiffFile], _ rows: DiffRows) -> (DiffContentView, NSScrollView, NSWindow, DiffRows, [DiffFile]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        let view = DiffContentView(theme: DiffTheme.resolve(appearance: NSAppearance(named: .aqua)!))
        scroll.documentView = view
        window.contentView = scroll
        view.setContent(files: files, rows: rows, syntax: [:], layout: .unified)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: view.totalHeight)
        return (view, scroll, window, rows, files)
    }

    @Test func everyRowIsReachableWithoutMaterialisingTheDocument() {
        let (view, _, _, rows, _) = makeView()
        let count = rows.rows.count
        #expect(count > DiffContentView.accessibilityElementLimit / 2, "a document larger than the element bound (\(count) rows)")
        #expect(view.accessibilityArrayAttributeCount(.children) == count)
        #expect((view.accessibilityChildren()?.count ?? 0) <= DiffContentView.accessibilityElementLimit / 2)
        #expect((view.accessibilityVisibleChildren()?.count ?? 0) < 40, "only the drawn rows are visible")
        // The very last rows, far below the viewport.
        let tail = view.accessibilityArrayAttributeValues(.children, index: count - 3, maxCount: 10)
        #expect(tail.count == 3)
        let lastLine = try! #require(rows.rows.lastIndex { $0.kind == .line })
        let element = try! #require(view.accessibilityArrayAttributeValues(.children, index: lastLine, maxCount: 1).first as? DiffRowAccessibilityElement)
        let cell = try! #require(rows.rows[lastLine].cell)
        #expect(element.accessibilityLabel()?.contains("line \(cell.number): \(cell.text)") == true)
        #expect(view.accessibilityIndex(ofChild: element) == lastLine)
        #expect(element.accessibilityParent() as? DiffContentView === view)
        // Every kind is described: file header, hunk header (with change number), changed lines with their kind.
        let labels = view.accessibilityArrayAttributeValues(.children, index: 0, maxCount: 12).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        #expect(labels.first?.hasPrefix("Sources/Long") == true)
        #expect(labels.contains { $0.hasPrefix("Change 1:") })
        #expect(labels.contains { $0.hasPrefix("removed line") } && labels.contains { $0.hasPrefix("added line") })
        // The element cache stays bounded however far a reader goes.
        for start in stride(from: 0, to: count, by: 1_000) { _ = view.accessibilityArrayAttributeValues(.children, index: start, maxCount: 1_000) }
        #expect(view.accessibilityRowElements.count <= DiffContentView.accessibilityElementLimit)
    }

    @Test func focusScrollsAnOffscreenRowIntoView() {
        let (view, _, _, rows, _) = makeView()
        let target = rows.rows.count - 2
        #expect(!view.visibleRect.intersects(view.rowRect(target)))
        let element = view.accessibilityElement(row: target)
        element.setAccessibilityFocused(true)
        #expect(view.visibleRect.contains(view.rowRect(target)))
        #expect(element.accessibilityFrame() != .zero)
    }

    @Test func drawnControlsAreAccessibilityActions() throws {
        let (view, _, _, rows, files) = makeView()
        view.revertableFiles = [0]
        var reverted: [(Int, Int)] = []
        var expanded: [Bool] = []
        var toggled: [Int] = []
        var comments = 0
        view.onRevertHunk = { reverted.append(($0, $1)) }
        view.onExpandGap = { _, all in expanded.append(all) }
        view.onToggleFile = { toggled.append($0) }
        view.onComment = { comments += 1 }

        let hunk = try #require(rows.hunkHeaderRows.first)
        let hunkActions = view.accessibilityElement(row: hunk).accessibilityCustomActions() ?? []
        #expect(hunkActions.map(\.name) == ["Revert Hunk"])
        #expect(hunkActions[0].handler?() == true)
        #expect(reverted.count == 1 && reverted[0].0 == 0 && reverted[0].1 == rows.rows[hunk].hunkIndex)

        let gap = try #require(rows.rows.firstIndex { if case .gap(_, true) = $0.kind { true } else { false } })
        let gapElement = view.accessibilityElement(row: gap)
        #expect(gapElement.accessibilityRole() == .button)
        let gapActions = gapElement.accessibilityCustomActions() ?? []
        #expect(gapActions.map(\.name) == ["Show 20 More Lines", "Show All Lines"])
        #expect(gapActions[1].handler?() == true)
        #expect(expanded == [true])
        // The new rows arrive: the state change is announced once.
        DiffContentView.lastAnnouncement = nil
        view.setContent(files: files, rows: rows, syntax: [:], layout: .unified)
        #expect(DiffContentView.lastAnnouncement == "Showing all unchanged lines")
        DiffContentView.lastAnnouncement = nil
        view.setContent(files: files, rows: rows, syntax: [:], layout: .unified)
        #expect(DiffContentView.lastAnnouncement == nil, "announced once, not on every rebuild")
        #expect(gapElement.accessibilityCustomActions() == nil, "an element of the old rows does nothing")
        #expect(gapElement.accessibilityPerformPress() == false)

        let header = view.accessibilityElement(row: rows.fileHeaderRows[0])
        #expect(header.accessibilityRole() == .button && header.accessibilityPerformPress())
        #expect(toggled == [0])
        view.setContent(files: files, rows: rows, syntax: [:], layout: .unified)
        #expect(DiffContentView.lastAnnouncement == "Long0.swift expanded" || DiffContentView.lastAnnouncement?.hasSuffix("expanded") == true)

        let line = try #require(rows.rows.firstIndex { $0.cell?.kind == .added })
        let lineActions = view.accessibilityElement(row: line).accessibilityCustomActions() ?? []
        #expect(lineActions.map(\.name) == ["Add Comment"])
        #expect(lineActions[0].handler?() == true)
        #expect(comments == 1 && view.selection?.start.row == line)
    }
}
