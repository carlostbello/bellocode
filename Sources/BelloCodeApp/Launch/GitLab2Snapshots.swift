import AppKit
import BelloCore
import DiffKit
import Engine
import OrchestrationUI

/// `--snapshot gitlab2` (docs/features/gitlab.md, GitLab 2): the inline review of MR !128 with a thread expanded and a
/// draft (`review-thread`), the outdated thread (`review-outdated`), the Issues section with an issue selected
/// (`issues`) and the draft Start Thread makes (`start-thread`), the approval explanation on a Premium-capability
/// instance (`approvals`) and the To-dos section (`todos`), in light and dark, on the in-process fake GitLab.
extension SnapshotRunner {
    func runGitLab2() async -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log("FAIL cannot create \(directory.path): \(error)")
            return false
        }
        let engine = runtime.engine
        guard let extras = engine.extras, let server = engine.configuration.forgeTransport as? FakeGitLabServer else { return false }
        MockGitLab.addReview(server)
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
        guard let project = engine.root.projects.first, let threads = workspace.projectModel(project)?.sessionIDs, !threads.isEmpty else {
            log("FAIL the mock scenario has no threads")
            return false
        }
        for id in threads { try? await engine.markViewed(id) }
        let mergeRequests = extras.mergeRequests
        _ = try? await mergeRequests.saveInstance(baseURL: MockGitLab.instance.baseURL, token: nil)
        await mergeRequests.setSettings(GitLabInstanceSettings(writesEnabled: true), for: MockGitLab.instance.baseURL)
        _ = await mergeRequests.refreshInstanceStatus(MockGitLab.instance)
        let thread = threads[0]
        _ = await driver.select(.thread(thread))
        _ = await waitUntil(timeout: .seconds(5)) { workspace.threadModel(thread).phase == .ready }
        _ = try? await mergeRequests.link([MockGitLab.ref], to: thread, source: .output)
        await mergeRequests.waitForFetches()
        driver.perform(.showMergeRequests)
        // A wide right panel for the diff (the person can drag it to 760).
        controller.split.splitView.setPosition(controller.split.splitView.bounds.width - 620, ofDividerAt: 1)
        guard let surfaces = controller.mergeRequests, let panel = surfaces.model else { return false }
        // The project resolves to the mock GitLab project (the mock folder is not a git checkout).
        panel.resolveProject = { _ in ForgeProject(instance: MockGitLab.instance, projectPath: MockGitLab.project) }

        // 1. The review: thread c1a expanded and current, a draft reply on it and a draft comment on another line.
        driver.perform(.reviewMergeRequest)
        guard let review = surfaces.review else {
            log("FAIL the review did not open")
            return false
        }
        _ = await waitUntil(timeout: .seconds(10)) { review.model.state != nil }
        try? await extras.reviews.addReply(MockGitLab.ref, discussionID: "c1a", body: "Thanks, the test covers it now.", resolve: true)
        try? await extras.reviews.addDraft(MockGitLab.ref, path: "Sources/Parser/Precedence.swift", side: .new, first: 60, last: 61, body: "Spacing the powers by 10 leaves room for comparison operators: nice.")
        driver.settle(10)
        review.diff.setExpanded(["c1a"])
        _ = await waitUntil(timeout: .seconds(5)) { review.diff.annotations.count >= 3 }
        driver.settle(10)
        review.diff.reveal(annotation: "c1a")
        driver.settle(10)
        await shoot("review-thread")

        // 2. The outdated thread, expanded at its file with where it was written.
        review.diff.setExpanded(["c0d"])
        driver.settle(10)
        review.diff.reveal(annotation: "c0d")
        review.diff.scroll(toY: 0)
        driver.settle(10)
        await shoot("review-outdated")
        surfaces.closeReview()

        // 3. Issues: assigned to me, #212 selected with its text, related MR and Start Thread.
        driver.perform(.showIssues)
        await panel.loadIssues()
        if let issue = panel.issueList?.issues.first(where: { $0.iid == 212 }) { await panel.selectIssue(issue) }
        driver.settle(10)
        await shoot("issues")

        // 4. Start Thread: the project's draft holds the issue, quoted; the workspace and branch pickers decide where.
        driver.perform(.startThreadFromIssue)
        _ = await waitUntil(timeout: .seconds(5)) { controller.container.context?.isDraft == true }
        driver.settle(12)
        await shoot("start-thread")
        _ = await driver.select(.thread(thread))
        _ = await waitUntil(timeout: .seconds(5)) { workspace.threadModel(thread).phase == .ready }

        // 5. Approvals explained (Premium capability: rules, eligibility, hidden groups, reset on push) and dependencies.
        surfaces.show(section: .mergeRequests)
        panel.expanded = MockGitLab.ref.url
        await panel.loadDetails(MockGitLab.ref)
        driver.settle(10)
        panel.scrollTarget = "approvals"
        driver.settle(10)
        await shoot("approvals")

        // 6. To-dos.
        driver.perform(.showTodos)
        await panel.loadTodos(force: true)
        panel.selectedTodo = 8_003
        driver.settle(10)
        await shoot("todos")

        workspace.close()
        controller.close()
        for path in written { log("wrote \(path)") }
        log(written.isEmpty ? "FAIL nothing written" : "PASS \(written.count) images")
        return !written.isEmpty
    }
}
