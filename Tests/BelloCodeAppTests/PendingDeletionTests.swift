import AppKit
import BelloCore
import Engine
import Foundation
import Testing

@testable import BelloCodeApp

/// Review M5: deferred deletes are one app-level pending operation shared by every window.
@MainActor @Suite struct PendingDeletionTests {
    final class FakeWindow: PendingDeletionListener {
        let manager = UndoManager()
        lazy var undo = UndoCoordinator(undoManager: { [manager] in manager })
        var hid: [[SessionID]] = []
        var restored: [[SessionID]] = []
        var committed: [[SessionID]] = []
        func pendingDeletionHid(_ ids: [SessionID]) { hid.append(ids) }
        func pendingDeletionRestored(_ ids: [SessionID]) { restored.append(ids) }
        func pendingDeletionCommitted(_ ids: [SessionID]) { committed.append(ids) }
    }

    /// A send that blocks until released, recording each request.
    @MainActor final class BlockingServer {
        var requests: [SessionID] = []
        var failing: Set<SessionID> = []
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var isBlocking = true
        func send(_ id: SessionID) async throws {
            requests.append(id)
            if isBlocking { await withCheckedContinuation { waiters.append($0) } }
            if failing.contains(id) { throw URLError(.cannotConnectToHost) }
        }
        func release() {
            isBlocking = false
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    /// A one-shot barrier: `wait` suspends until `open`.
    actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    /// The timer never fires on its own: tests decide when the Undo window ends.
    static let neverWait: PendingThreadDeletions.Wait = { _ in try await Task.sleep(for: .seconds(100_000)) }

    func make(_ server: BlockingServer) -> PendingThreadDeletions {
        PendingThreadDeletions(wait: Self.neverWait) { id in try await server.send(id) }
    }

    @Test func everyWindowHidesAndUndoFromAnotherWindowRestoresEverywhere() async {
        let server = BlockingServer()
        let deletions = make(server)
        let a = FakeWindow(), b = FakeWindow()
        deletions.register(a)
        deletions.register(b)
        deletions.delete(["s1"], name: "Delete Thread", message: "Deleted", from: a)
        #expect(deletions.hidden == ["s1"])
        #expect(a.hid == [["s1"]] && b.hid == [["s1"]], "both windows leave the thread")
        #expect(a.undo.toasts.current != nil && b.undo.toasts.current != nil, "Undo offered in both windows")
        // Undo from the toast in one window restores everywhere too.
        a.undo.undoFromToast()
        #expect(deletions.hidden.isEmpty && b.undo.toasts.current == nil)
        deletions.delete(["s1"], name: "Delete Thread", message: "Deleted", from: a)
        a.hid.removeAll(); b.hid.removeAll(); a.restored.removeAll(); b.restored.removeAll()
        a.hid = [["s1"]]
        b.manager.undo()  // ⌘Z in the other window
        #expect(deletions.hidden.isEmpty)
        #expect(a.restored == [["s1"]] && b.restored == [["s1"]])
        #expect(a.undo.toasts.current == nil, "the other window's Undo is retired")
        a.manager.undo()
        #expect(a.restored.count == 1, "A's retired entry does nothing")
        deletions.commitAll()
        #expect(server.requests.isEmpty, "nothing reached the server")
        // Redo from B brings the pending delete back, in every window.
        b.manager.redo()
        #expect(deletions.hidden == ["s1"] && deletions.isPending("s1"))
        #expect(a.hid.count == 2)
        server.release()
        _ = await deletions.drain()
        #expect(server.requests == ["s1"])
    }

    @Test func aDeleteIsSentExactlyOnce() async {
        let server = BlockingServer()
        let deletions = make(server)
        let a = FakeWindow()
        deletions.register(a)
        let entry = try! #require(deletions.delete(["s1", "s2"], name: "Delete Threads", message: "Deleted", from: a))
        deletions.commit(entry)
        deletions.commit(entry)
        deletions.commitAll()
        #expect(deletions.delete(["s1"], name: "Delete Thread", message: "Deleted", from: a) == nil, "already being deleted")
        a.manager.undo()  // too late: retired
        #expect(deletions.hidden == ["s1", "s2"], "still hidden while being sent")
        server.release()
        #expect(await deletions.drain().isEmpty)
        #expect(server.requests == ["s1", "s2"])
        #expect(deletions.sentCount == 2)
        #expect(deletions.hidden.isEmpty)
        #expect(a.committed == [["s1", "s2"]])
    }

    @Test func closingAWindowKeepsTheDeletePendingClosingTheLastSendsIt() async {
        let server = BlockingServer()
        server.isBlocking = false
        let deletions = make(server)
        let a = FakeWindow(), b = FakeWindow()
        deletions.register(a)
        deletions.register(b)
        deletions.delete(["s1"], name: "Delete Thread", message: "Deleted", from: a)
        deletions.unregister(a)
        #expect(deletions.isPending("s1"), "B can still undo")
        #expect(server.requests.isEmpty)
        deletions.unregister(b)
        #expect(!deletions.isPending("s1"))
        _ = await deletions.drain()
        #expect(server.requests == ["s1"])
    }

    /// Quit with a blocked delete: `drain` does not return (so the engine is not stopped) until the server answered,
    /// and a failure with no window left is returned for the quit alert.
    @Test func quitWaitsForABlockedDeleteAndReportsFailure() async {
        let server = BlockingServer()
        server.failing = ["s2"]
        let deletions = make(server)
        let a = FakeWindow()
        deletions.register(a)
        deletions.delete(["s1", "s2"], name: "Delete Threads", message: "Deleted", from: a)
        deletions.unregister(a)  // the last window closed during termination
        var drained: [SessionID]?
        let quit = Task { @MainActor in drained = await deletions.drain() }
        await Task.yield()
        #expect(drained == nil, "quit is still waiting")
        #expect(server.requests == ["s1"])
        server.release()
        await quit.value
        #expect(drained == ["s2"])
        #expect(deletions.hidden.isEmpty, "the failed thread shows again")
        #expect(server.requests == ["s1", "s2"])
    }

    /// The timer path: after the Undo window the delete goes out once; a failure is reported in the deleting window.
    @Test func timerCommitsAndFailureIsShownInTheWindow() async {
        let server = BlockingServer()
        server.isBlocking = false
        server.failing = ["s1"]
        let gate = Gate()
        let deletions = PendingThreadDeletions(wait: { _ in await gate.wait() }) { id in try await server.send(id) }
        let a = FakeWindow()
        deletions.register(a)
        deletions.delete(["s1"], name: "Delete Thread", message: "Deleted", from: a)
        await gate.open()
        #expect(await deletions.drain().isEmpty, "reported in the window instead")
        #expect(server.requests == ["s1"])
        #expect(a.undo.toasts.current?.token == nil && a.undo.toasts.current?.message.isEmpty == false)
    }
}
