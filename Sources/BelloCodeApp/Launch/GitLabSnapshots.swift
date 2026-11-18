import AppKit
import BelloCore
import Engine
import MockOpenCode
import OpenCodeKit
import OrchestrationUI

/// `--snapshot gitlab` (docs/features/gitlab.md): the merge-request panel overview, the pipeline with a failed job and
/// its excerpt, the job log, a babysit wake in the transcript, the create-MR form, the sidebar and header chips and
/// Settings ▸ GitLab, in light and dark, on the in-process fake GitLab (a self-managed instance with a path prefix).
extension SnapshotRunner {
    func runGitLab() async -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log("FAIL cannot create \(directory.path): \(error)")
            return false
        }
        let engine = runtime.engine
        guard let extras = engine.extras, let server = engine.configuration.forgeTransport as? FakeGitLabServer else { return false }
        let settings = AppSettings(defaults: nil)
        let services = AppServices(settings: settings, auth: runtime.auth)
        let workspace = WorkspaceController(engine: engine, stateStore: ShellStateStore(defaults: nil))
        let controller = MainWindowController(
            workspace: workspace,
            configuration: .init(surfaces: .builtIn(services: services), autosaveSuffix: nil, sourceLabel: runtime.sourceLabel))
        guard let window = controller.window else { return false }
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        controller.showWindow(nil)
        let driver = ShellDriver(controller: controller)
        var written: [String] = []
        func shoot(_ state: String) async {
            guard only.isEmpty || only.contains(state) else { return }
            written += await render(driver, state: state)
        }
        await engine.start()
        guard await waitUntil(timeout: .seconds(20), { engine.root.connection == .live && !engine.root.projects.isEmpty }) else {
            log("FAIL mock never became live")
            return false
        }
        _ = await waitUntil(timeout: .seconds(5)) {
            engine.root.projects.allSatisfy { workspace.projectModel($0).map { !$0.sessionIDs.isEmpty } ?? false }
        }
        guard let project = engine.root.projects.first, let threads = workspace.projectModel(project)?.sessionIDs, threads.count >= 3 else {
            log("FAIL the mock scenario has too few threads")
            return false
        }
        for id in threads { try? await engine.markViewed(id) }
        let mergeRequests = extras.mergeRequests
        _ = try? await mergeRequests.saveInstance(baseURL: MockGitLab.instance.baseURL, token: nil)
        await mergeRequests.setSettings(GitLabInstanceSettings(writesEnabled: true), for: MockGitLab.instance.baseURL)
        _ = await mergeRequests.refreshInstanceStatus(MockGitLab.instance)

        // A thread with two linked MRs; !128 is babysat. A second thread links !131 (sidebar chips on two rows).
        let thread = threads[0]
        _ = await driver.select(.thread(thread))
        _ = await waitUntil(timeout: .seconds(5)) { workspace.threadModel(thread).phase == .ready }
        _ = try? await mergeRequests.link([MockGitLab.ref], to: thread, source: .output)
        _ = try? await mergeRequests.link([MockGitLab.secondRef], to: thread, source: .branch)
        _ = try? await mergeRequests.link([MockGitLab.secondRef], to: threads[1], source: .branch)
        try? await mergeRequests.setWatching(MockGitLab.ref, for: thread, true)
        await mergeRequests.waitForFetches()
        await mergeRequests.pollDue()
        _ = await waitUntil(timeout: .seconds(5)) { mergeRequests.watch(thread, MockGitLab.ref.url)?.baseline != nil }
        driver.perform(.showMergeRequests)
        let panel = controller.mergeRequests?.model
        driver.settle(10)
        await mergeRequests.loadWakeLog(thread, MockGitLab.ref.url)
        driver.settle(6)
        await shoot("mr-panel")

        // The pipeline fails; the babysitter wakes the thread once (2 s mock poll) with the failing job's excerpt.
        MockGitLab.finish(server)
        _ = await waitUntil(timeout: .seconds(10)) { mergeRequests.watch(thread, MockGitLab.ref.url)?.wakes == 1 }
        _ = await waitUntil(timeout: .seconds(8)) { !workspace.threadModel(thread).isRunning }
        await mergeRequests.loadWakeLog(thread, MockGitLab.ref.url)
        if let snapshot = mergeRequests.snapshots[MockGitLab.ref.url], let job = snapshot.pipeline?.failedJobs.first {
            await panel?.loadExcerpt(MockGitLab.ref, job)
        }
        panel?.failuresOnly = true
        driver.settle(6)
        panel?.scrollTarget = "pipeline"
        driver.settle(10)
        await shoot("pipeline-failed")

        panel?.scrollTarget = "babysit"
        driver.settle(10)
        await shoot("babysit-wake")
        panel?.failuresOnly = false

        if let snapshot = mergeRequests.snapshots[MockGitLab.ref.url], let job = snapshot.pipeline?.failedJobs.first {
            panel?.showLog(MockGitLab.ref, job)
            _ = await waitUntil(timeout: .seconds(5)) { if case .loaded = panel?.log { true } else { false } }
        }
        driver.settle(10)
        await shoot("job-log")
        panel?.closeLog()

        // The create form for a new branch of the same thread (a scripted checkout: the mock project is not a repo).
        panel?.makeCreateContext = { id in
            CreateMergeRequestContext(
                sessionID: id, directory: project.directory,
                checkout: { CheckoutState(branch: "parser/error-recovery", remote: "git@code.example.test:platform/rocket.git", upstream: "origin/parser/error-recovery", ahead: 0) },
                push: {}, commits: { _ in ["Recover from a missing closing parenthesis", "Report the expected token in parse errors"] },
                generate: { prompt in try await engine.generateText(in: id, prompt: prompt) })
        }
        panel?.expanded = ""
        panel?.openCreate()
        if let form = panel?.create {
            _ = await waitUntil(timeout: .seconds(5)) { form.phase == .ready && !form.generating }
            form.reviewerQuery = "lee"
            await form.addPerson(reviewer: true)
        }
        driver.settle(10)
        await shoot("create-mr")
        panel?.create = nil

        // Sidebar and header chips, panel closed.
        controller.split.setCollapsed(controller.split.panelItem, true)
        driver.settle(10)
        await shoot("chips")
        controller.split.setCollapsed(controller.split.panelItem, false)

        let settingsWindow = SettingsWindowController(
            settings: settings, auth: nil, importSource: nil, engine: engine, notifier: nil, openThread: { _ in })
        settingsWindow.show(pane: "gitlab")
        settingsWindow.window?.setFrameOrigin(NSPoint(x: 60, y: 60))
        try? await Task.sleep(for: .milliseconds(300))
        if only.isEmpty || only.contains("settings") { written += await renderWindow(settingsWindow.window, state: "settings") }
        settingsWindow.close()

        workspace.close()
        controller.close()
        for path in written { log("wrote \(path)") }
        log(written.isEmpty ? "FAIL nothing written" : "PASS \(written.count) images")
        return !written.isEmpty
    }
}
