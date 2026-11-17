import AgentUI
import AppKit
import BrowserKit
import BelloCore
import ComposerKit
import Engine

/// Application lifecycle: builds the runtime (engine + server + the one AuthService), the main menu, the main window,
/// Settings and the first-run window; shuts the AuthService down and stops the engine and the server it owns before
/// the process exits (no orphaned opencode).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private var runtime: AppRuntime?
    /// Every main window (⇧⌘N opens another); they share the runtime's engine.
    private(set) var windows: MainWindows?
    private var mainWindowController: MainWindowController? { windows?.current }
    private var services: AppServices?
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: UtilityWindowController?
    private var connectWindow: UtilityWindowController?
    private var isTerminating = false
    /// Notifications for blockers and completions, and the Dock badge (docs/features/navigation.md).
    private(set) var notifier: AttentionNotifier?
    private var statusItem: StatusItemController?
    /// Offscreen sandbox for HTML visuals (M3-B): html_preview, snapshots, PNG export.
    private let visualRenderer = HTMLVisualRenderer()
    private var wakeObserver: (any NSObjectProtocol)?

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        Task { @MainActor in
            do {
                let runtime = try await AppRuntime.make(options: options)
                self.runtime = runtime
                startExtras(runtime)
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
                startAttention(runtime: runtime, settings: settings)
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

    /// M3-B (docs/features/orchestration-extras.md): the visual renderer, and after the Mac wakes, an immediate check
    /// of due scheduled tasks (catch-up policy) and watched merge requests.
    private func startExtras(_ runtime: AppRuntime) {
        guard let extras = runtime.engine.extras else { return }
        extras.visuals.renderer = visualRenderer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak extras] _ in
            MainActor.assumeIsolated {
                guard let extras else { return }
                Task {
                    await extras.schedules.tick()
                    await extras.mergeRequests.pollDue()
                }
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

    /// Carries out pending deletes and waits for them, shuts the AuthService down, then stops the engine and its server;
    /// the child has exited before the app does.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime, !runtime.isStopped else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        windows?.closeAllForTermination()
        Task { @MainActor in
            // Deletes still in their Undo window are sent now, and the engine stops only after their results (M5).
            let failed = await PendingThreadDeletions.shared(for: runtime.engine).drain()
            if !failed.isEmpty {
                let alert = NSAlert()
                alert.messageText = failed.count == 1 ? "A thread could not be deleted" : "\(failed.count) threads could not be deleted"
                alert.informativeText = "They are still there and will show again the next time BelloCode opens."
                alert.runModal()
            }
            await runtime.stop()
            self.visualRenderer.close()
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
        if let windows {
            windows.showPrimary()
            return
        }
        let windows = MainWindows(defaults: runtime.defaults) { id in
            let workspace = WorkspaceController(
                engine: runtime.engine, stateStore: ShellStateStore(defaults: runtime.defaults, key: MainWindows.stateKey(for: id)))
            // The first window keeps the M1 autosave names; others get their own (frame, split dividers).
            let suffix = id == MainWindows.primaryID ? runtime.autosaveSuffix : runtime.autosaveSuffix + "." + id
            return MainWindowController(
                workspace: workspace,
                configuration: .init(surfaces: .builtIn(services: services), autosaveSuffix: suffix, sourceLabel: runtime.sourceLabel))
        }
        self.windows = windows
        windows.restore()
        // The `bellocode_app_open_thread` agent tool (docs/features/orchestration.md): the key window shows the thread
        // (Back returns); it never opens a new window.
        runtime.engine.orchestration?.revealThread = { [weak windows] id in
            guard let windows else { return false }
            let key = NSApp.keyWindow?.windowController as? MainWindowController
            guard let controller = key ?? windows.controllers[MainWindows.primaryID] else { return false }
            controller.workspace.select(.thread(id))
            return true
        }
    }

    /// Starts notifications (inside the app bundle, never for mock data) and the optional menu-bar item.
    private func startAttention(runtime: AppRuntime, settings: AppSettings) {
        let isMock = if case .mock = runtime.source { true } else { false }
        let delivery = isMock ? nil : SystemNotificationDelivery.makeIfAvailable()
        let notifier = AttentionNotifier(engine: runtime.engine, settings: settings, delivery: delivery, defaults: runtime.defaults)
        notifier.frontmostThread = { [weak self] in
            guard let current = self?.windows?.current, current.window?.isKeyWindow == true else { return nil }
            return current.container.displayed?.threadID
        }
        notifier.onOpen = { [weak self] id in
            NSApp.activate()
            self?.openThread(id)
        }
        delivery?.onResponse = { [weak notifier] response in
            Task { await notifier?.handle(response) }
        }
        notifier.start()
        self.notifier = notifier
        let statusItem = StatusItemController(engine: runtime.engine, settings: settings)
        statusItem.onOpen = { [weak self] id in self?.openThread(id) }
        statusItem.start()
        self.statusItem = statusItem
    }

    /// Brings the front main window forward (reopening the first one if every window is closed).
    func showFrontWindow() {
        if let current = windows?.current { current.showWindow(nil) } else { windows?.showPrimary() }
    }

    /// Opens a thread from outside a window (a notification, the menu-bar item): the front window shows it.
    func openThread(_ id: SessionID) {
        showFrontWindow()
        windows?.current?.workspace.select(.thread(id))
        windows?.current?.window?.makeKeyAndOrderFront(nil)
    }

    /// ⇧⌘N: a new main window with its own selection, sharing the engine.
    @objc func newMainWindow(_ sender: Any?) {
        guard windows != nil else { return }
        windows?.openNew()
    }

    /// Opens a selection in a new window; `background` keeps the current window in front (palette ⌘↩).
    func openWindow(selection: ShellSelection, background: Bool, reveal: PendingReveal? = nil) {
        windows?.openNew(selection: selection, background: background, reveal: reveal)
    }

    // MARK: - Settings, onboarding, connect (menu actions reach the delegate through the responder chain)

    @objc func showSettings(_ sender: Any?) { openSettings(pane: nil) }

    /// Window ▸ Scheduled Tasks… (M3-B): Settings on its Scheduled Tasks pane; works with no window open.
    @objc func showScheduledTasks(_ sender: Any?) { openSettings(pane: "schedules") }

    /// Window ▸ Containers… / Project Environment… / Verify Container Isolation (M6-A, docs/features/containers.md).
    @objc func showContainers(_ sender: Any?) { openSettings(pane: "containers") }

    @objc func showEnvironment(_ sender: Any?) {
        if let directory = NSApp.orderedWindows.compactMap({ $0.windowController as? MainWindowController }).first?.currentProjectDirectory {
            EnvironmentSettingsModel.preferredDirectory = directory
            EnvironmentSettingsModel.last?.select(directory)
        }
        openSettings(pane: "environment")
    }

    @objc func verifyIsolation(_ sender: Any?) {
        openSettings(pane: "containers")
        guard let engine = runtime?.engine else { return }
        Task { await engine.environments.verifyIsolation(full: true) }
    }

    @objc func connectProvider(_ sender: Any?) { openConnect(nil) }

    @objc func showWelcome(_ sender: Any?) { showOnboarding() }

    func openSettings(pane: String?) {
        guard let services else { return }
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                settings: services.settings, auth: services.auth, importSource: .userInstall(), engine: runtime?.engine,
                notifier: notifier, openThread: { [weak self] id in self?.openThread(id) })
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
