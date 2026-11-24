import AppKit
import BelloCore
import ComposerKit
import Engine
import Foundation
import SwiftUI
import Testing

@testable import BelloCodeApp

/// v1.0.1 verification NV08–NV10: what belongs to a window or a thread stays with it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct WindowLifecycleTests {
    /// NV08: closing a main window detaches its terminals and closes its floating Git panel and popover with it.
    @Test func closingAWindowTearsDownItsFloatingPanelsAndTerminals() async throws {
        let shell = try await IntegratedShellTests.Shell.start()
        defer { Task { await shell.stop() } }
        let controller = shell.controller
        controller.showGitPanel(Text("Edit from Here"), title: "Edit from Here")
        let panel = try #require(controller.gitUI.panel)
        #expect(panel.isVisible)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))
        #expect(!panel.isVisible, "the floating panel does not outlive its window")
        #expect(controller.gitUI.panel == nil)
        #expect(controller.terminals?.isClosed == true, "terminal emulators are detached")
        #expect(!controller.palette.isVisible)
    }

    /// NV08: each window's close observer is removed when it closes (no observers pile up as windows come and go).
    @Test func closedWindowsLeaveNoCloseObserverBehind() async throws {
        let defaults = try #require(UserDefaults(suiteName: "bellocode.tests.windows.\(UUID().uuidString)"))
        let windows = MainWindows(defaults: defaults) { id in TestWindows.make(defaults: defaults, id: id) }
        windows.restore(restoresWindows: false)
        #expect(windows.closeObserverCount == 1)
        for _ in 0..<3 {
            let extra = windows.openNew(background: true)
            #expect(windows.closeObserverCount == 2)
            extra.window?.close()
            #expect(await waitUntil(timeout: .seconds(5)) { windows.closeObserverCount == 1 })
        }
        windows.closeAllForTermination()
        for controller in windows.all { controller.close() }
    }

    /// NV09: Edit from Here's floating panel confirmed after the window switched threads puts the prompt into its own
    /// thread's draft, never into the composer of the thread now shown.
    @Test func aRewoundPromptGoesToItsOwnThread() async throws {
        let shell = try await IntegratedShellTests.Shell.start()
        defer { Task { await shell.stop() } }
        let controller = shell.controller
        let threads = shell.threads
        try #require(threads.count >= 2)
        #expect(await shell.driver.select(.thread(threads[0])))
        shell.driver.settle()
        #expect(await waitUntil(timeout: .seconds(5)) { controller.changesComposer != nil })
        let composer = try #require(controller.changesComposer)
        let before = composer.textView.string
        controller.placeRewoundPrompt("rewound prompt for B", thread: threads[1])
        #expect(composer.textView.string == before, "the shown thread's composer is untouched")
        let other = shell.engine.openThread(threads[1])
        defer { other.close() }
        #expect(await waitUntil(timeout: .seconds(5)) { other.isDraftLoaded && other.draft.hasPrefix("rewound prompt for B") }, "\(other.draft)")
        controller.placeRewoundPrompt("rewound prompt for A", thread: threads[0])
        #expect(composer.textView.string.contains("rewound prompt for A"), "the shown thread's own prompt goes to its composer")
    }

    /// AV2-02: a second window already shows the rewound thread. Its loaded composer takes the prompt (in front of its
    /// draft), so its next save keeps it instead of overwriting the thread's draft with the text it showed before.
    @Test func aRewoundPromptReachesTheThreadsComposerInAnotherWindow() async throws {
        let shell = try await IntegratedShellTests.Shell.start()
        defer { Task { await shell.stop() } }
        let threads = shell.threads
        try #require(threads.count >= 2)
        let first = shell.controller
        #expect(await shell.driver.select(.thread(threads[0])))
        shell.driver.settle()
        let workspace = WorkspaceController(engine: shell.engine, stateStore: ShellStateStore(defaults: nil))
        let services = AppServices(settings: AppSettings(defaults: nil), auth: shell.engine.makeAuthService(openURL: { _ in }),
                                   attachmentStore: AttachmentFileStore(directory: shell.attachments))
        let second = MainWindowController(workspace: workspace, configuration: .init(surfaces: .builtIn(services: services), autosaveSuffix: nil))
        defer {
            workspace.close()
            second.close()
        }
        second.showWindow(nil)
        let driver = ShellDriver(controller: second)
        #expect(await driver.select(.thread(threads[1])))
        driver.settle()
        #expect(await waitUntil(timeout: .seconds(5)) { second.changesComposer.map { !$0.controller.awaitingDraft } ?? false })
        let composer = try #require(second.changesComposer)
        composer.focus()
        composer.insert(text: "half-typed")
        composer.controller.flushDraft()

        first.placeRewoundPrompt("rewound prompt for B", thread: threads[1])
        #expect(await waitUntil(timeout: .seconds(5)) { composer.textView.string.hasPrefix("rewound prompt for B") }, "\(composer.textView.string)")
        #expect(composer.textView.string.contains("half-typed"), "what that window showed stays, after the prompt")
        // Its next edit and save keep the prompt in the thread's draft.
        composer.insert(text: "!")
        composer.controller.flushDraft()
        let model = shell.engine.openThread(threads[1])
        defer { model.close() }
        #expect(model.draft.hasPrefix("rewound prompt for B"), "\(model.draft)")
        let firstText = first.changesComposer?.textView.string ?? ""
        #expect(firstText.range(of: "rewound prompt for B") == nil, "the first window's thread is untouched")
    }

    /// R3-01: both windows show the same thread. The first saves newer text and runs Edit from Here at once; the
    /// second, idle, has not caught up and still shows its older copy. The prompt goes in front of the newer draft, both
    /// windows show it, and the idle window never writes its stale copy over the newer text, then or on its next edit.
    @Test func aRewoundPromptNeverSavesAStaleWindowsCopyOverTheNewerDraft() async throws {
        let shell = try await IntegratedShellTests.Shell.start()
        defer { Task { await shell.stop() } }
        let threads = shell.threads
        try #require(!threads.isEmpty)
        let first = shell.controller
        #expect(await shell.driver.select(.thread(threads[0])))
        shell.driver.settle()
        #expect(await waitUntil(timeout: .seconds(5)) { first.changesComposer.map { !$0.controller.awaitingDraft } ?? false })
        let workspace = WorkspaceController(engine: shell.engine, stateStore: ShellStateStore(defaults: nil))
        let services = AppServices(settings: AppSettings(defaults: nil), auth: shell.engine.makeAuthService(openURL: { _ in }),
                                   attachmentStore: AttachmentFileStore(directory: shell.attachments))
        let second = MainWindowController(workspace: workspace, configuration: .init(surfaces: .builtIn(services: services), autosaveSuffix: nil))
        defer {
            workspace.close()
            second.close()
        }
        second.showWindow(nil)
        let driver = ShellDriver(controller: second)
        #expect(await driver.select(.thread(threads[0])))
        driver.settle()
        #expect(await waitUntil(timeout: .seconds(5)) { second.changesComposer.map { !$0.controller.awaitingDraft } ?? false })
        let active = try #require(first.changesComposer)
        let idle = try #require(second.changesComposer)
        let staleText = idle.textView.string
        // The active window saves newer text and confirms Edit from Here with no run-loop turn in between, so the idle
        // window has not observed the save.
        active.insert(text: "newer text from the active window")
        active.controller.flushDraft()
        #expect(idle.textView.string == staleText, "the idle window still shows its older copy")
        first.placeRewoundPrompt("rewound prompt", thread: threads[0])

        let model = shell.engine.openThread(threads[0])
        defer { model.close() }
        #expect(model.draft.contains("rewound prompt"), "\(model.draft)")
        #expect(model.draft.contains("newer text from the active window"), "the newer draft is kept: \(model.draft)")
        #expect(await waitUntil(timeout: .seconds(5)) { idle.textView.string == model.draft }, "\(idle.textView.string)")
        #expect(active.textView.string == model.draft)
        // The idle window's next edit saves on top of the newer draft.
        idle.insert(text: "!")
        idle.controller.flushDraft()
        #expect(model.draft.contains("newer text from the active window") && model.draft.contains("rewound prompt"), "\(model.draft)")
    }

    /// NV10: the blocked-command banner follows the context's directory live: a thread shown before its session
    /// hydrated picks up the session's directory when it arrives.
    @Test func theEnvironmentBannerFollowsALateDirectory() async throws {
        _ = NSApplication.shared
        let engine = try Engine(configuration: EngineConfiguration(server: .dynamic { nil }, store: .inMemory))
        let id = SessionID("ses_banner_late")
        let thread = engine.openThread(id)
        defer { thread.close() }
        let context = ThreadSurfaceContext(engine: engine, directory: "", projectName: "p", thread: thread)
        let banner = ThreadContainerViewController.makeEnvironmentBanner(engine: engine, context: context)
        #expect(banner.currentDirectory == "", "unknown before the session loads")
        // The thread's first (empty) snapshot has landed, so only the change below sets its session.
        #expect(await waitUntil(timeout: .seconds(10)) { thread.phase == .ready })
        var batch = StoreBatch()
        batch.sessions = [Session(id: id, projectID: ProjectID("p"), directory: "/tmp/late-project", created: Timestamp(milliseconds: 0),
                                  updated: Timestamp(milliseconds: 1))]
        try await engine.store.apply(batch)
        #expect(await waitUntil(timeout: .seconds(10)) { thread.session != nil })
        #expect(banner.currentDirectory == "/tmp/late-project")
    }
}
