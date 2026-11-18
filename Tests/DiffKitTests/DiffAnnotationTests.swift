import AppKit
import Engine
import Testing

@testable import DiffKit

/// GitLab 2: review threads inline in the diff. Placement under the exact line (either side, unified and split),
/// fallback to the file (never a guessed line), header indices remapped, heights from the expanded state, keyboard
/// navigation and accessibility, and that a large document with many threads stays within the build budget.
@MainActor @Suite struct DiffAnnotationTests {
    static let file = DiffFile.compute(
        path: "Sources/Parser.swift", old: "import Foundation\nlet a = 1\nfunc f() {}\n// end\n", new: "import Foundation\nlet a = 2\nlet b = 3\nfunc f() {}\n// end\n")
    static let other = DiffFile.compute(path: "README.md", old: "a\n", new: "b\n")

    static func thread(_ id: String, _ placement: DiffAnnotation.Placement, _ state: DiffAnnotation.State = .unresolved, body: String = "Why?") -> DiffAnnotation {
        DiffAnnotation(id: id, placement: placement, state: DiffAnnotationStateSet(state), notes: [.init(author: "mara", time: "2 h ago", body: body)])
    }

    func placed(_ rows: DiffRows) -> [(after: DiffRow, id: String)] {
        rows.rows.indices.compactMap { index in
            guard case .annotation(let a) = rows.rows[index].kind else { return nil }
            var previous = index - 1
            while previous > 0, case .annotation = rows.rows[previous].kind { previous -= 1 }
            return (rows.rows[previous], rows.annotations[a].id)
        }
    }

    @Test func threadsSitUnderTheirLineOnEitherSide() {
        var options = DiffRowOptions()
        options.annotations = [
            Self.thread("added", .line(path: "Sources/Parser.swift", side: .new, line: 3)),
            Self.thread("removed", .line(path: "Sources/Parser.swift", side: .old, line: 2)),
            Self.thread("context-old", .line(path: "Sources/Parser.swift", side: .old, line: 3)),
            Self.thread("outdated", .file(path: "Sources/Parser.swift"), .outdated),
            Self.thread("hidden", .line(path: "Sources/Parser.swift", side: .new, line: 400)),
            Self.thread("elsewhere", .line(path: "Missing.swift", side: .new, line: 1)),
        ]
        for layout in DiffLayout.allCases {
            options.layout = layout
            let rows = DiffRowBuilder.build([Self.file, Self.other], options: options)
            let list = placed(rows)
            let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.after) })
            #expect(byID["elsewhere"] == nil, "threads of files not shown are listed elsewhere")
            #expect(byID["outdated"]?.kind == .fileHeader && byID["hidden"]?.kind == .fileHeader, "never at a guessed line")
            let added = byID["added"]
            #expect([added?.left, added?.right].contains { $0?.side == .new && $0?.number == 3 && $0?.kind == .added }, "\(layout)")
            let removed = byID["removed"]
            #expect([removed?.left, removed?.right].contains { $0?.side == .old && $0?.number == 2 && $0?.kind == .removed })
            // Old line 3 is the unchanged "func f() {}" (new line 4): found through the unified row's other number.
            let context = byID["context-old"]
            #expect([context?.left, context?.right].contains { $0?.kind == .context && $0?.text == "func f() {}" })
            // Header indices follow the inserted rows.
            for (file, header) in rows.fileHeaderRows.enumerated() { #expect(rows.rows[header].kind == .fileHeader && rows.rows[header].fileIndex == file) }
            for header in rows.hunkHeaderRows { #expect(rows.rows[header].kind == .hunkHeader) }
            #expect(Set(rows.rows.map(\.id)).count == rows.rows.count, "row IDs stay unique")
        }
    }

    @Test func collapsedFilesHideTheirThreads() {
        var options = DiffRowOptions()
        options.annotations = [Self.thread("a", .line(path: "Sources/Parser.swift", side: .new, line: 3)), Self.thread("o", .file(path: "Sources/Parser.swift"), .outdated)]
        options.collapsedFiles = ["Sources/Parser.swift"]
        #expect(DiffRowBuilder.build([Self.file], options: options).annotations.isEmpty)
    }

    func controller() async throws -> (DiffViewController, NSWindow) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let diff = DiffViewController()
        window.contentView = diff.view
        diff.view.frame = window.contentLayoutRect
        diff.view.layoutSubtreeIfNeeded()
        return (diff, window)
    }

    func displayed(_ diff: DiffViewController, _ change: () -> Void) async {
        await withCheckedContinuation { continuation in
            diff.onDisplay = {
                diff.onDisplay = nil
                continuation.resume()
            }
            change()
        }
    }

    @Test func expandingAThreadGrowsOnlyItsRowAndKeysMoveBetweenThreads() async throws {
        let (diff, _) = try await controller()
        await displayed(diff) { diff.display([Self.file]) }
        let longBody = (1...12).map { "Line \($0) of a long review comment that wraps in the card." }.joined(separator: "\n")
        await displayed(diff) {
            diff.annotations = [
                Self.thread("one", .line(path: "Sources/Parser.swift", side: .new, line: 2), body: longBody),
                Self.thread("two", .line(path: "Sources/Parser.swift", side: .new, line: 4), .resolved),
            ]
        }
        let collapsed = diff.contentHeight
        #expect(diff.rowCount == DiffRowBuilder.build([Self.file], options: DiffRowOptions()).rows.count + 2)
        diff.nextAnnotation()
        #expect(diff.currentAnnotation?.id == "one")
        await displayed(diff) { diff.toggleAnnotation("one") }
        #expect(diff.expandedAnnotations == ["one"])
        #expect(diff.contentHeight > collapsed + 12 * 15, "the body's lines are laid out")
        #expect(diff.currentAnnotation?.id == "one", "the current thread survives the rebuild")
        diff.nextAnnotation()
        #expect(diff.currentAnnotation?.id == "two")
        diff.nextAnnotation()
        #expect(diff.currentAnnotation?.id == "one", "wraps around")
        // Actions reach the owner, with their titles for accessibility.
        var received: [String] = []
        diff.annotationActions = { _ in [DiffAnnotationAction(id: "reply", title: "Reply…"), DiffAnnotationAction(id: "resolve", title: "Resolve Thread")] }
        diff.onAnnotationAction = { action, annotation in received.append("\(action.id):\(annotation.id)") }
        let row = try #require((0..<diff.rowCount).first { if case .annotation = diff.content.rows.rows[$0].kind { true } else { false } })
        let actions = diff.content.accessibilityActions(row: row).map(\.name)
        #expect(actions == ["Collapse Thread", "Reply…", "Resolve Thread"])
        let label = DiffContentView.accessibilityText(diff.content.rows.rows[row], files: diff.content.files, layout: .unified, annotations: diff.content.rows.annotations)
        #expect(label.hasPrefix("Review thread by @mara, Unresolved"))
        _ = diff.content.accessibilityActions(row: row)[1].handler?()
        #expect(received == ["reply:one"])
    }

    @Test func manyThreadsOnALargeDiffStayWithinTheBuildBudget() async throws {
        let old = (1...20_000).map { "line \($0)" }
        var new = old
        for index in stride(from: 0, to: 20_000, by: 2) { new[index] = "changed \(index)" }
        let file = DiffFile.compute(path: "Big.swift", old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
        var options = DiffRowOptions()
        options.annotations = (0..<300).map { Self.thread("t\($0)", .line(path: "Big.swift", side: .new, line: 1 + $0 * 60)) }
        let start = ContinuousClock.now
        let rows = DiffRowBuilder.build([file], options: options)
        let elapsed = ContinuousClock.now - start
        #expect(rows.annotations.count == 300)
        #expect(elapsed < .seconds(3), "debug build: \(elapsed)")
        // The view lays out only threads; drawing stays per visible row.
        let (diff, _) = try await controller()
        await displayed(diff) {
            diff.annotations = options.annotations
            diff.display([file])
        }
        diff.scroll(toY: diff.contentHeight / 2)
        diff.view.displayIfNeeded()
        #expect(diff.lastDrawDuration < .milliseconds(200))
    }
}
