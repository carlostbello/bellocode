import AgentUI
import AppKit
import ComposerKit
import Engine

/// Application lifecycle: builds the runtime (engine + server + the one AuthService), the main menu, the main window,
/// Settings and the first-run window; shuts the AuthService down and stops the engine and the server it owns before
/// the process exits (no orphaned opencode).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private var runtime: AppRuntime?
    private var mainWindowController: MainWindowController?
    private var workspace: WorkspaceController?
    private var services: AppServices?
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: UtilityWindowController?
    private var connectWindow: UtilityWindowController?
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
                let settings = AppSettings(defaults: runtime.defaults)
                settings.apply()
                services = makeServices(settings: settings, auth: runtime.auth)
                Task { await AttachmentFileStore.applicationDefault.cleanUp() }
                // Quick Look copies of pasted content left by a crashed run.
                Task { await PreviewFiles.current.cleanUpAbandoned() }
                showMainWindow()
                NSApp.activate()
                // Cached content first (start() returns once the cache is shown), then the server connects.
                await runtime.engine.start()
                Task { await runtime.auth.refresh() }
                if !settings.hasCompletedOnboarding { await showOnboardingWhenReady() }
            } catch let error as ProjectionStore.OpenError {
                // Transient (locked, I/O, permission, failed migration): the database is untouched; let the user retry.
                let alert = NSAlert()
                alert.messageText = "BelloCode could not open its local data"
                alert.informativeText = "\(error.description) Your drafts and settings are still in it. Close other copies of BelloCode or free disk space, then try again."
                alert.addButton(withTitle: "Try Again")
                alert.addButton(withTitle: "Quit")
                if alert.runModal() == .alertFirstButtonReturn {
                    applicationDidFinishLaunching(notification)
                } else {
                    NSApp.terminate(nil)
                }
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

    /// Shuts the AuthService down, then stops the engine and its server; the child has exited before the app does.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime, !runtime.isStopped else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        workspace?.close()
        Task { @MainActor in
            await runtime.stop()
            await PreviewFiles.current.removeAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func makeServices(settings: AppSettings, auth: AuthService) -> AppServices {
        AppServices(settings: settings, auth: auth) { [weak self] id in self?.openConnect(id) }
    }

    private func showMainWindow() {
        guard let runtime, let services else { return }
        if mainWindowController == nil {
            let workspace = WorkspaceController(
                engine: runtime.engine, stateStore: ShellStateStore(defaults: runtime.defaults))
            self.workspace = workspace
            mainWindowController = MainWindowController(
                workspace: workspace,
                configuration: .init(
                    surfaces: .builtIn(services: services), autosaveSuffix: runtime.autosaveSuffix,
                    sourceLabel: runtime.sourceLabel))
        }
        mainWindowController?.showWindow(nil)
    }

    // MARK: - Settings, onboarding, connect (menu actions reach the delegate through the responder chain)

    @objc func showSettings(_ sender: Any?) { openSettings(pane: nil) }

    @objc func connectProvider(_ sender: Any?) { openConnect(nil) }

    @objc func showWelcome(_ sender: Any?) { showOnboarding() }

    func openSettings(pane: String?) {
        guard let services else { return }
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                settings: services.settings, auth: services.auth, importSource: .userInstall())
        }
        settingsWindow?.show(pane: pane)
    }

    /// "Connect…" from the model picker or the app menu: the provider list (or one provider's sign-in) in a small
    /// window, never modal.
    func openConnect(_ integrationID: String?) {
        guard let auth = runtime?.auth else { return }
        connectWindow?.close()
        let content = AgentUIFactories.providerConnect(auth: auth, integrationID: integrationID, style: AppStyle.agentUI) {
            [weak self] in self?.connectWindow?.close()
        }
        let window = UtilityWindowController(title: "Connect a Provider", content: content, size: NSSize(width: 560, height: 480))
        window.onClose = { [weak self] in self?.connectWindow = nil }
        connectWindow = window
        window.showWindow(nil)
        window.window?.center()
    }

    /// First run: shown beside the main window once the catalog is known (it lists the free models), never blocking
    /// the app; finishing, skipping or closing it marks onboarding done.
    private func showOnboardingWhenReady() async {
        guard let engine = runtime?.engine else { return }
        _ = await waitUntil(timeout: .seconds(8)) { engine.root.catalog.current != nil }
        showOnboarding()
    }

    private func showOnboarding() {
        guard let runtime, let services else { return }
        if let onboardingWindow {
            onboardingWindow.showWindow(nil)
            return
        }
        let content = AgentUIFactories.onboarding(
            auth: runtime.auth, engine: runtime.engine, style: AppStyle.agentUI
        ) { [weak self] _ in
            services.settings.hasCompletedOnboarding = true
            self?.onboardingWindow?.close()
        }
        let window = UtilityWindowController(title: "Welcome to BelloCode", content: content, size: NSSize(width: 560, height: 520))
        window.onClose = { [weak self] in
            services.settings.hasCompletedOnboarding = true
            self?.onboardingWindow = nil
        }
        onboardingWindow = window
        window.showWindow(nil)
        if let main = mainWindowController?.window, let panel = window.window {
            panel.setFrameOrigin(NSPoint(x: main.frame.midX - panel.frame.width / 2, y: main.frame.midY - panel.frame.height / 2))
        }
    }
}
