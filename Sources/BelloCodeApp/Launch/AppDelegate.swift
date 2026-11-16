import AppKit
import Engine

/// Application lifecycle: builds the runtime (engine + server), the main menu and the main window; stops the engine
/// and the server it owns before the process exits (no orphaned opencode).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private var runtime: AppRuntime?
    private var mainWindowController: MainWindowController?
    private var workspace: WorkspaceController?
    private var isTerminating = false

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        Task { @MainActor in
            do {
                let runtime = try await AppRuntime.make(options: options)
                self.runtime = runtime
                if case .snapshot(let name) = options.mode {
                    let directory = options.snapshotDirectory ?? FileManager.default.currentDirectoryPath + "/build/snapshots"
                    let ok = await SnapshotRunner(runtime: runtime, name: name, directory: URL(filePath: directory)).run()
                    await runtime.stop()
                    exit(ok ? EXIT_SUCCESS : EXIT_FAILURE)
                }
                showMainWindow()
                NSApp.activate()
                // Cached content first (start() returns once the cache is shown), then the server connects.
                await runtime.engine.start()
            } catch {
                let alert = NSAlert()
                alert.messageText = "BelloCode could not start"
                alert.informativeText = String(describing: error)
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Agents keep running with no window open (docs/PLAN.md, section 8.3). Clicking the Dock icon reopens it.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Stops the engine and its server first; the child has exited before the app does.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime, !runtime.isStopped else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        workspace?.close()
        Task { @MainActor in
            await runtime.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func showMainWindow() {
        guard let runtime else { return }
        if mainWindowController == nil {
            let workspace = WorkspaceController(
                engine: runtime.engine, stateStore: ShellStateStore(defaults: runtime.defaults))
            self.workspace = workspace
            mainWindowController = MainWindowController(
                workspace: workspace,
                configuration: .init(autosaveSuffix: runtime.autosaveSuffix, sourceLabel: runtime.sourceLabel))
        }
        mainWindowController?.showWindow(nil)
    }
}
