import BelloCore
import DiffKit
import Foundation
import Synchronization
import Testing

@testable import BelloCodeApp
@testable import Engine

/// v1.0.1 final-check findings in the shell's git wiring: a failed rewind Undo is shown with its path (NF12), and the
/// Git Actions popover keeps one watch on the commit form however often it opens (NF19).
@Suite("Final check: shell git wiring", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct GitShellFinalCheckTests {
    /// NF12: Undo of a rewind's file restore that fails (a restored file changed since) says so, naming the path.
    @Test func aFailedRewindUndoIsShownWithThePath() async {
        let plan = RewindPlan(sessionID: SessionID(rawValue: "ses_1"), messageID: MessageID(rawValue: "msg_1"), directory: "/r/sub")
        let applied = AppliedRewind(plan: plan, written: [], root: "/r")
        var notices: [String] = []
        await MainWindowController.undoRewindFiles(applied, undo: { _ in throw WorkingCopyError.changedOnDisk("sub/f.txt") }, notice: { notices.append($0) })
        #expect(notices.count == 1)
        #expect(notices.first?.contains("Could not undo the file restore") == true)
        #expect(notices.first?.contains("sub/f.txt") == true)
        notices = []
        await MainWindowController.undoRewindFiles(applied, undo: { _ in }, notice: { notices.append($0) })
        #expect(notices.isEmpty, "a successful Undo needs no notice")
    }

    /// NF19: opening the Git Actions popover N times leaves one live watch: the commit form is shown once.
    @Test func reopeningThePopoverWatchesTheCommitFormOnce() async throws {
        let service = GitService(client: { throw CancellationError() }, store: nil)
        let repository = service.repository(for: FileManager.default.temporaryDirectory.appending(path: "bellocode-nf19-\(UUID().uuidString)").path)
        let host = GitActionHost(
            createMergeRequest: {}, openMergeRequest: {}, generate: nil, confirm: { _, _, _ in false }, notice: { _ in }, publish: {})
        let model = GitActionsModel(repository: repository, host: host)
        let watch = CommitFormWatch()
        var shown = 0
        for _ in 0..<3 { watch.watch(model) { _ in shown += 1 } }
        model.commit = GitCommitModel(repository: repository, generate: nil)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while shown == 0, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        // Let any stale watch run too.
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(shown == 1)
        // Cancelled: a later form is not shown by this watch.
        watch.watch(model) { _ in shown += 1 }
        watch.cancel()
        model.commit = nil
        model.commit = GitCommitModel(repository: repository, generate: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(shown == 1)
    }
}
