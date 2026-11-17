import AppKit
import BelloCore
import Engine
import Foundation
import MockOpenCode
import OpenCodeKit
import Testing

@testable import SwiftTerm
@testable import TerminalKit

/// A window that is always key, so first-responder rules apply without activating the test process.
final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

@MainActor
func waitFor(_ message: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    if condition() { return }
    Issue.record("timed out: \(message)")
    throw CancellationError()
}

@MainActor
final class RecordingDelegate: TerminalWorkspaceDelegate {
    var sent: [(String, String)] = []
    var links: [String] = []
    func terminalWorkspace(_ workspace: TerminalWorkspace, sendToComposer text: String, from record: TerminalRecord) {
        sent.append((text, record.id))
    }
    func terminalWorkspace(_ workspace: TerminalWorkspace, open link: TerminalLink) { links.append(link.text) }
}

@MainActor
@Suite("Terminal surfaces (mock PTYs)", .serialized)
struct TerminalSurfaceTests {
    @MainActor
    struct Fixture {
        let server: MockOpenCodeServer
        let client: OpenCodeClient
        let service: TerminalService
        let workspace: TerminalWorkspace
        let drawer: TerminalSurfaceController
        let panel: TerminalSurfaceController
        let window: KeyWindow
        let panelWindow: KeyWindow
        let delegate = RecordingDelegate()

        static func start() async throws -> Fixture {
            let server = MockOpenCodeServer(scenario: .empty(), options: .testing)
            let endpoint = try await server.start()
            let client = OpenCodeClient(
                connection: ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? "")))
            let service = TerminalService(
                store: try ProjectionStore(location: .inMemory), client: { client },
                launch: TerminalLaunch(command: "/bin/zsh", args: ["-l"], environment: [:]))
            let workspace = TerminalWorkspace(service: service)
            let drawer = workspace.makeSurface(.drawer)
            let panel = workspace.makeSurface(.panel)
            func window(_ content: NSView, _ size: NSSize) -> KeyWindow {
                let window = KeyWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = content
                return window
            }
            let fixture = Fixture(
                server: server, client: client, service: service, workspace: workspace, drawer: drawer, panel: panel,
                window: window(drawer.view, NSSize(width: 900, height: 300)), panelWindow: window(panel.view, NSSize(width: 400, height: 300)))
            workspace.delegate = fixture.delegate
            return fixture
        }

        func thread() async throws -> ThreadTerminals {
            let session = try await client.createSession(SessionCreateRequest(directory: "/tmp/mock-project", title: "t"))
            let terminals = service.terminals(for: SessionID(session.id))
            await terminals.waitUntilLoaded()
            return terminals
        }

        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            panelWindow.contentView?.layoutSubtreeIfNeeded()
        }

        func pane(_ id: String) throws -> TerminalPaneController { try #require(workspace.existingPane(id)) }

        func screen(_ id: String) -> String {
            guard let view = workspace.existingPane(id)?.terminalView else { return "" }
            return view.visibleRowsText(0..<view.terminalDimensions.rows).joined(separator: "\n")
        }

        func stop() async {
            workspace.close()
            await service.shutdown()
            await server.stop()
        }
    }

    @Test func showsEmptyThenAttachesTypesAndRenders() async throws {
        let fixture = try await Fixture.start()
        let terminals = try await fixture.thread()
        fixture.drawer.display(terminals, directory: "/tmp/mock-project")
        fixture.layout()
        #expect(fixture.drawer.mountedIDs.isEmpty)
        let record = try #require(await terminals.create(directory: "/tmp/mock-project", size: PTYSize(cols: 100, rows: 20)))
        try await waitFor("mounted") { fixture.drawer.mountedIDs == [record.id] }
        let pane = try fixture.pane(record.id)
        try await waitFor("live") { pane.status == .live }
        try await waitFor("prompt") { fixture.screen(record.id).contains("$ ") }
        pane.stream.send(Array("echo rendered-ok\r".utf8))
        try await waitFor("output in the emulator") { fixture.screen(record.id).contains("rendered-ok\n") || fixture.screen(record.id).components(separatedBy: "rendered-ok").count >= 3 }
        // The PTY follows the emulator's real grid once laid out.
        fixture.layout()
        let dims = pane.terminalView.terminalDimensions
        try await waitFor("grid sent", timeout: .seconds(3)) {
            pane.stream.sentSize == PTYSize(cols: dims.cols, rows: dims.rows)
        }
        await fixture.stop()
    }

    @Test func switchingThreadsKeepsPTYsAndEmulators() async throws {
        let fixture = try await Fixture.start()
        let a = try await fixture.thread()
        let b = try await fixture.thread()
        fixture.drawer.display(a, directory: "/tmp/mock-project")
        let ra = try #require(await a.create(directory: "/tmp/mock-project"))
        try await waitFor("a live") { fixture.workspace.existingPane(ra.id)?.status == .live }
        try await fixture.pane(ra.id).stream.send(Array("echo from-a\r".utf8))
        try await waitFor("a output") { fixture.screen(ra.id).contains("from-a") }
        let paneA = try fixture.pane(ra.id)

        fixture.drawer.display(b, directory: "/tmp/mock-project")
        let rb = try #require(await b.create(directory: "/tmp/mock-project"))
        try await waitFor("b live") { fixture.workspace.existingPane(rb.id)?.status == .live }
        try await waitFor("a detached") { paneA.status == .detached }
        #expect(await fixture.server.ptyAttachmentCount(ra.id) == 0)
        #expect(await fixture.server.ptyIDs() == [ra.id, rb.id], "switching never deletes PTYs")
        await fixture.server.writeToPTY(ra.id, "while-hidden\r\n")

        let start = ContinuousClock.now
        fixture.drawer.display(a, directory: "/tmp/mock-project")
        #expect(fixture.drawer.mountedIDs == [ra.id], "the cached emulator shows at once")
        #expect(ContinuousClock.now - start < .milliseconds(100))
        #expect(try fixture.pane(ra.id) === paneA)
        try await waitFor("gap replayed") { fixture.screen(ra.id).contains("while-hidden") }
        #expect(fixture.screen(ra.id).contains("from-a"), "scrollback kept")
        try await waitFor("b detached") { fixture.workspace.existingPane(rb.id)?.status == .detached }
        await fixture.stop()
    }

    @Test func splitExitedBarAndMoveToPanel() async throws {
        let fixture = try await Fixture.start()
        let terminals = try await fixture.thread()
        fixture.drawer.display(terminals, directory: "/tmp/mock-project")
        fixture.panel.display(terminals, directory: "/tmp/mock-project")
        let first = try #require(await terminals.create(directory: "/tmp/mock-project"))
        let second = try #require(await terminals.create(directory: "/tmp/mock-project"))
        terminals.select(first.id, in: .drawer)
        fixture.drawer.toggleSplit()
        try await waitFor("split") { fixture.drawer.mountedIDs == [first.id, second.id] }
        fixture.drawer.toggleSplit()
        try await waitFor("unsplit") { fixture.drawer.mountedIDs == [first.id] }

        try await waitFor("second live") { fixture.workspace.existingPane(second.id)?.status == .live }
        try fixture.pane(second.id).stream.send(Array("exit 4\r".utf8))
        try await waitFor("exited") { terminals.record(second.id)?.state == .exited(code: 4) }
        terminals.select(second.id, in: .drawer)
        let pane = try fixture.pane(second.id)
        try await waitFor("ended bar") { !pane.endedBar.isHidden }

        terminals.select(first.id, in: .drawer)
        fixture.drawer.moveSelectedToOtherPlace()
        try await waitFor("moved") { fixture.panel.mountedIDs == [first.id] && fixture.drawer.mountedIDs == [second.id] }
        #expect(terminals.record(first.id)?.placement == .panel)
        await fixture.stop()
    }

    @Test func terminalKeepsControlAndFunctionKeys() async throws {
        let fixture = try await Fixture.start()
        let terminals = try await fixture.thread()
        fixture.drawer.display(terminals, directory: "/tmp/mock-project")
        let record = try #require(await terminals.create(directory: "/tmp/mock-project"))
        try await waitFor("mounted") { fixture.drawer.mountedIDs == [record.id] }
        let view = try fixture.pane(record.id).terminalView
        #expect(fixture.window.makeFirstResponder(view))
        func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags, code: UInt16 = 0) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: fixture.window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        let f6 = String(UnicodeScalar(UInt16(NSF6FunctionKey))!)
        #expect(view.claimsKeyEquivalent(key(f6, [], code: 97)), "F6 goes to the program, not region cycling")
        #expect(view.claimsKeyEquivalent(key("c", .control)), "Ctrl-C goes to the program")
        #expect(view.claimsKeyEquivalent(key("b", .option)), "Option combinations go to the program")
        TerminalPaneView.reservedShortcuts = [("`", .control)]
        #expect(!view.claimsKeyEquivalent(key("`", .control)), "Ctrl-` stays the drawer toggle")
        #expect(!view.claimsKeyEquivalent(key("t", .command)), "Command shortcuts reach the menu")
        fixture.window.makeFirstResponder(nil)
        #expect(!view.claimsKeyEquivalent(key("c", .control)), "only a focused terminal claims keys")
        await fixture.stop()
    }

    @Test func pasteConfirmationOnlyForMultilineAtAShellPrompt() async throws {
        let fixture = try await Fixture.start()
        let terminals = try await fixture.thread()
        fixture.drawer.display(terminals, directory: "/tmp/mock-project")
        let record = try #require(await terminals.create(directory: "/tmp/mock-project"))
        let pane = try await { () async throws -> TerminalPaneController in
            try await waitFor("live") { fixture.workspace.existingPane(record.id)?.status == .live }
            return try fixture.pane(record.id)
        }()
        // The mock shell marks its prompt with OSC 133 A/B and has bracketed paste off.
        try await waitFor("prompt") { fixture.screen(record.id).contains("$ ") }
        try await Task.sleep(for: .milliseconds(50))
        #expect(pane.shouldConfirmPaste("one\ntwo"))
        #expect(!pane.shouldConfirmPaste("one line"))
        #expect(!pane.shouldConfirmPaste("one line\n"), "a single line with its newline runs one command, as typed")
        await fixture.server.writeToPTY(record.id, "\u{1B}[?2004h")
        try await waitFor("bracketed paste on") { pane.terminalView.bracketedPasteMode }
        #expect(!pane.shouldConfirmPaste("one\ntwo"), "bracketed paste is safe")
        await fixture.server.writeToPTY(record.id, "\u{1B}[?2004l\u{1B}]133;C\u{7}")
        try await Task.sleep(for: .milliseconds(100))
        #expect(!pane.shouldConfirmPaste("one\ntwo"), "a running program gets its paste as is")
        fixture.workspace.preferences.confirmsMultilinePaste = false
        await fixture.server.writeToPTY(record.id, "\u{1B}]133;A\u{7}")
        try await Task.sleep(for: .milliseconds(100))
        #expect(!pane.shouldConfirmPaste("one\ntwo"), "the setting turns it off")
        await fixture.stop()
    }

    @Test func oscSevenUpdatesDirectoryAndOscFiftyTwoIsBlocked() async throws {
        let fixture = try await Fixture.start()
        let terminals = try await fixture.thread()
        fixture.drawer.display(terminals, directory: "/tmp/mock-project")
        let record = try #require(await terminals.create(directory: "/tmp/mock-project"))
        try await waitFor("live") { fixture.workspace.existingPane(record.id)?.status == .live }
        let pane = try fixture.pane(record.id)
        pane.stream.send(Array("cd /tmp/elsewhere\r".utf8))
        try await waitFor("OSC 7") { terminals.record(record.id)?.currentDirectory == "/tmp/elsewhere" }
        #expect(!fixture.workspace.preferences.allowsClipboardWrites)
        let before = NSPasteboard.general.changeCount
        pane.stream.send(Array("clip secret-from-program\r".utf8))
        try await waitFor("blocked notice") { !pane.statusPill.isHidden && pane.statusPill.label.stringValue.contains("Blocked") }
        #expect(NSPasteboard.general.changeCount == before, "the pasteboard was not written")
        await fixture.stop()
    }

    @Test func findCountsMatchesAndSendSelectionReachesTheComposer() async throws {
        let fixture = try await Fixture.start()
        let terminals = try await fixture.thread()
        fixture.drawer.display(terminals, directory: "/tmp/mock-project")
        let record = try #require(await terminals.create(directory: "/tmp/mock-project"))
        try await waitFor("live") { fixture.workspace.existingPane(record.id)?.status == .live }
        let pane = try fixture.pane(record.id)
        pane.stream.send(Array("echo needle one\r".utf8))
        pane.stream.send(Array("echo needle two\r".utf8))
        try await waitFor("output") { fixture.screen(record.id).components(separatedBy: "needle").count >= 5 }
        pane.showFind(useSelection: false)
        #expect(pane.isFindVisible)
        pane.findBarSet("needle")
        #expect(pane.findBar.count.stringValue.hasSuffix("of 4"))
        pane.hideFind()
        #expect(!pane.isFindVisible)

        pane.terminalView.selectAll(nil)
        let selected = try #require(pane.selectedText)
        #expect(selected.contains("needle two"))
        pane.sendSelectionToComposer()
        #expect(fixture.delegate.sent.count == 1)
        #expect(fixture.delegate.sent.first?.1 == record.id)
        #expect(fixture.delegate.sent.first?.0.contains("needle one") == true)
        await fixture.stop()
    }

    @Test func paneCacheIsBoundedAndSparesShownPanes() async throws {
        let fixture = try await Fixture.start()
        let terminals = try await fixture.thread()
        fixture.drawer.display(terminals, directory: "/tmp/mock-project")
        var ids: [String] = []
        for _ in 0..<(TerminalWorkspace.paneCacheLimit + 3) {
            if let record = await terminals.create(directory: "/tmp/mock-project") { ids.append(record.id) }
        }
        try await waitFor("rendered") { fixture.drawer.mountedIDs == [ids.last!] }
        #expect(fixture.workspace.cachedPaneCount <= TerminalWorkspace.paneCacheLimit)
        #expect(fixture.workspace.existingPane(ids.last!) != nil)
        await fixture.stop()
    }
}
