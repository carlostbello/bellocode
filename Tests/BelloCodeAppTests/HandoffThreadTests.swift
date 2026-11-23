import AppKit
import BelloCore
import Engine
import Foundation
import Testing

@testable import BelloCodeApp

/// NV01: Git ▸ Move Changes to New Worktree… opens a thread in the new worktree. A worktree is not a project of its
/// own, so a draft there had no surface ("No Thread Selected"); the thread is created there and shown with a composer.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct HandoffThreadTests {
    @Test func aThreadInANewWorktreeIsShownWithItsComposer() async throws {
        let shell = try await IntegratedShellTests.Shell.start()
        defer { Task { await shell.stop() } }
        let worktree = FileManager.default.temporaryDirectory.appending(path: "bellocode-handoff-\(UUID().uuidString)/feat-moved")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree.deletingLastPathComponent()) }
        let path = WorkspaceController.canonicalDirectory(worktree)
        let workspace = shell.controller.workspace
        #expect(workspace.projectItem(directory: path) == nil, "the worktree is not a project")
        let id = try await workspace.startThread(inWorktree: path, title: "feat/moved")
        #expect(workspace.selection == .thread(id))
        let shown = await waitUntil(timeout: .seconds(10)) {
            shell.controller.container.displayed == .thread(id) && shell.controller.container.context?.thread?.sessionID == id
        }
        #expect(shown, "the thread is displayed, not the empty placeholder")
        let directory = await waitUntil(timeout: .seconds(10)) { shell.controller.container.context?.directory == path }
        #expect(directory, "it works in the worktree: \(shell.controller.container.context?.directory ?? "nil")")
    }
}
