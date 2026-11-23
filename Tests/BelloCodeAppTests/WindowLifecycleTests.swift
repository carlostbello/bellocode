import AppKit
import BelloCore
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
