import AppKit
import BelloCore
import ComposerKit
import Engine
import Foundation
import MockOpenCode
import OpenCodeKit
import TerminalKit
import Testing

@testable import BelloCodeApp

/// The terminal seam in the real main window against MockOpenCode's PTYs: menu commands, the drawer following the
/// displayed thread with per-thread visibility, and "Send Selection to Composer".
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct TerminalShellTests {
    @Test func commandsDrawerPerThreadAndSendToComposer() async throws {
        let shell = try await IntegratedShellTests.Shell.start()
        defer { Task { await shell.stop() } }
        let controller = shell.controller
        let driver = shell.driver
        let threads = shell.threads
        try #require(threads.count >= 2)
        let first = threads[0]
        let second = threads[1]
        let surfaces = try #require(controller.terminals, "the drawer factory provides the window's terminals")

        #expect(await driver.select(.thread(first)))
        driver.settle()
        #expect(controller.commandContext().isEnabled(.newTerminal))
        #expect(!controller.commandContext().isEnabled(.closeTerminal), "nothing to close yet")
        #expect(!controller.isTerminalDrawerVisible)

        // ⌘T: the drawer opens and a terminal starts in the thread's directory.
        driver.perform(.newTerminal)
        #expect(controller.isTerminalDrawerVisible)
        let terminals = try #require(surfaces.terminals)
        #expect(await waitUntil(timeout: .seconds(5)) { terminals.records(in: .drawer).count == 1 })
        let record = try #require(terminals.records(in: .drawer).first)
        #expect(record.startDirectory == shell.controller.container.context?.directory)
        #expect(controller.commandContext().isEnabled(.closeTerminal))
        let pane = try #require(surfaces.workspace?.existingPane(record.id))
        #expect(await waitUntil(timeout: .seconds(5)) { pane.status == .live })
        #expect(await waitUntil(timeout: .seconds(2)) { surfaces.focusIsInTerminal }, "the new terminal takes focus")

        // Send Selection to Composer: a named text block lands in the thread's composer.
        pane.stream.send(Array("echo selection-for-agent\r".utf8))
        let echoed = await waitUntil(timeout: .seconds(5)) {
            pane.terminalView.visibleRowsText(0..<10).joined().components(separatedBy: "selection-for-agent").count >= 3
        }
        #expect(echoed)
        pane.terminalView.selectAll(nil)
        #expect(controller.commandContext().isEnabled(.sendTerminalSelection))
        driver.perform(.sendTerminalSelection)
        let composer = try #require(driver.composer)
        let attachment = try #require(composer.currentDraft().attachments.first)
        #expect(attachment.kind == .text)
        #expect(attachment.name.hasPrefix("Terminal Terminal 1"))
        if case .text(let text) = attachment.content { #expect(text.contains("selection-for-agent")) } else {
            Issue.record("expected a text attachment, got \(attachment.content)")
        }

        // ⌃` hides the drawer; the thread remembers it.
        driver.perform(.toggleTerminal)
        #expect(!controller.isTerminalDrawerVisible)
        #expect(terminals.set.isDrawerOpen == false)

        // Another thread: its own (empty) set; the first thread's PTY keeps running.
        #expect(await driver.select(.thread(second)))
        driver.settle()
        let other = try #require(surfaces.terminals)
        #expect(other !== terminals)
        #expect(other.records(in: .drawer).isEmpty)
        driver.perform(.newTerminal)
        #expect(controller.isTerminalDrawerVisible)
        #expect(await waitUntil(timeout: .seconds(5)) { other.records(in: .drawer).count == 1 })
        #expect(await shell.server.ptyIDs().contains(record.id))

        // Back to the first thread: its drawer was hidden, so it is hidden again; its terminal is still there.
        #expect(await driver.select(.thread(first)))
        #expect(await waitUntil(timeout: .seconds(2)) { !controller.isTerminalDrawerVisible })
        #expect(surfaces.terminals === terminals)
        #expect(terminals.record(record.id)?.state == .running)

        // Close Terminal deletes the PTY on the server.
        driver.perform(.toggleTerminal)
        #expect(controller.isTerminalDrawerVisible)
        driver.perform(.closeTerminal)
        #expect(await waitUntil(timeout: .seconds(5)) { terminals.records(in: .drawer).isEmpty })
        #expect(await waitUntilAsync { await !shell.server.ptyIDs().contains(record.id) })
    }

    @Test func terminalCommandsUseCommandSoTheTerminalKeepsItsKeys() {
        for command in ShellCommand.allCases {
            let shortcut = command.shortcut
            guard !shortcut.key.isEmpty, !shortcut.modifiers.contains(.command) else { continue }
            // Only the drawer toggle is kept while a terminal has focus; F6/⇧F6 go to the program.
            #expect(command.isKeptWhileTerminalFocused == (command == .toggleTerminal), "\(command)")
        }
        for command in [ShellCommand.newTerminal, .closeTerminal, .splitTerminal, .nextTerminal, .previousTerminal, .clearTerminal, .sendTerminalSelection] {
            #expect(command.shortcut.modifiers.contains(.command), "\(command) has a ⌘ shortcut")
        }
        var context = CommandContext()
        #expect(!context.isEnabled(.newTerminal))
        context.terminalAvailable = true
        #expect(context.isEnabled(.newTerminal))
        #expect(!context.isEnabled(.restartTerminal))
        context.terminalSelected = true
        #expect(context.isEnabled(.restartTerminal))
        #expect(!context.isEnabled(.sendTerminalSelection))
        context.terminalHasSelectedText = true
        context.composerVisible = true
        #expect(context.isEnabled(.sendTerminalSelection))
        context.terminalInPanel = true
        #expect(context.title(for: .moveTerminal) == "Move Terminal to Drawer")
        context.terminalSplit = true
        #expect(context.title(for: .splitTerminal) == "Unsplit Terminal")
    }

    @MainActor @Test func terminalPreferencesPersist() {
        let suite = "BelloCodeTerminalSettingsTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.terminalPreferences == TerminalPreferences())
        settings.terminalPreferences.fontSize = 15
        settings.terminalPreferences.allowsClipboardWrites = true
        settings.terminalPreferences.scrollback = 50_000
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.terminalPreferences.fontSize == 15)
        #expect(reloaded.terminalPreferences.allowsClipboardWrites)
        #expect(reloaded.terminalPreferences.scrollback == 50_000)
    }
}

@MainActor
func waitUntilAsync(timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
