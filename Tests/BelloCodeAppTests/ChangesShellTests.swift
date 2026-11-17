import AppKit
import BelloCore
import ComposerKit
import DiffKit
import Engine
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import BelloCodeApp

/// M2-C in the real main window against MockOpenCode: the "Changes" tab follows the displayed thread and shows its
/// turn's changes, the Changes commands validate, and review comments land in the composer as chips.
@MainActor @Suite(.serialized) struct ChangesShellTests {
    @Test func changesCommandValidation() {
        var context = CommandContext()
        #expect(!context.isEnabled(.showChanges) && !context.isEnabled(.revertTurn) && !context.isEnabled(.chooseWorkspace))
        context.changes.available = true
        context.changes.isRepository = true
        context.changes.isDraft = true
        #expect(context.isEnabled(.showChanges) && context.isEnabled(.chooseWorkspace) && context.isEnabled(.chooseBranch))
        #expect(!context.isEnabled(.removeWorktree), "a draft has no worktree to remove")
        context.changes.revertFileTitle = "Discard Uncommitted Changes to a.swift"
        #expect(context.title(for: .revertFile) == "Discard Uncommitted Changes to a.swift…", "the menu states the exact scope")
        context.changes.isSplit = true
        #expect(context.title(for: .toggleDiffLayout) == "Unified Diff")
        #expect(!context.isEnabled(.addReviewComment), "needs a selection and a composer")
        context.changes.hasSelection = true
        context.composerVisible = true
        #expect(context.isEnabled(.addReviewComment))
        #expect(ShellCommand.revertHunk.shortcut.key.isEmpty && ShellCommand.revertTurn.shortcut.key.isEmpty, "reverting is never one keystroke")
    }

    @Test func changesTabFollowsTheThreadAndCommentsReachTheComposer() async throws {
        let shell = try await IntegratedShellTests.Shell.start()
        defer { Task { await shell.stop() } }
        let controller = shell.controller
        let driver = shell.driver
        let threads = shell.threads
        try #require(threads.count >= 2)
        let changes = try #require(controller.changes, "the Changes tab is mounted")
        let patch = PatchFile(
            oldPath: "Sources/App/main.swift", newPath: "Sources/App/main.swift",
            hunks: LineDiff.hunks(old: ["print(1)", "print(2)"], new: ["print(1)", "print(3)"], context: 100)
        ).render()
        await shell.server.setTurnDiff(sessionID: threads[0].rawValue, files: [MockVCSRepository.fileDiff("Sources/App/main.swift", patch: patch)])

        #expect(await driver.select(.thread(threads[0])))
        driver.settle()
        driver.perform(.showChanges)
        #expect(!controller.split.panelItem.isCollapsed && controller.rightPanel.selectedID == "changes")
        let model = try #require(changes.model)
        #expect(model.sessionID == threads[0])
        #expect(await waitUntil(timeout: .seconds(5)) { model.phase == .ready && model.files.map(\.path) == ["Sources/App/main.swift"] })
        #expect(await waitUntil(timeout: .seconds(5)) { changes.panel.diff.rowCount > 0 })
        #expect(controller.commandContext().isEnabled(.nextChange))

        // Another thread: another model; back again: the same model, still loaded (no blank pane).
        #expect(await driver.select(.thread(threads[1])))
        driver.settle()
        #expect(changes.model?.sessionID == threads[1])
        #expect(await driver.select(.thread(threads[0])))
        driver.settle()
        #expect(changes.model === model && !model.files.isEmpty)

        // A review comment on the new line goes into the thread's composer as a named text chip.
        changes.panel.diff.selectLines(path: "Sources/App/main.swift", side: .new, 2...2)
        let target = try #require(changes.panel.diff.commentTarget)
        #expect(target.lines == 2...2 && target.quoted == "print(3)")
        changes.changesPanel(
            changes.panel,
            addComment: DiffReviewComment(path: target.file.path, side: target.side, startLine: 2, endLine: 2, quoted: target.quoted, text: "Why 3?"))
        let composer = try #require(driver.composer)
        let attachment = try #require(composer.currentDraft().attachments.last)
        #expect(attachment.name == "Review Sources/App/main.swift:2.md")
        if case .text(let text) = attachment.content { #expect(text.contains("print(3)") && text.contains("Why 3?")) }
    }
}
