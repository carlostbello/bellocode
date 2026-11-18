import AppKit
import BelloCore
import ContainerKit
import DesignSystem
import DiffKit
import Engine
import SwiftUI

/// `--snapshot git` (docs/features/git-parity.md): the git actions menu, the branch picker creating a branch, the
/// commit-and-push form, the rewind confirmation, the clone-from-GitLab form and the behind/ahead and conflict states,
/// light and dark, on throwaway repositories (never the person's own) and the in-process fake GitLab.
extension SnapshotRunner {
    func runGit() async -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log("FAIL cannot create \(directory.path): \(error)")
            return false
        }
        let engine = runtime.engine
        await engine.start()
        guard await waitUntil(timeout: .seconds(20), { engine.root.connection == .live }) else {
            log("FAIL mock never became live")
            return false
        }
        _ = try? await engine.extras.mergeRequests.saveInstance(baseURL: MockGitLab.instance.baseURL, token: nil)
        var written: [String] = []
        let world: GitSnapshotWorld
        do {
            world = try await GitSnapshotWorld.make(instance: MockGitLab.instance)
        } catch {
            log("FAIL repositories: \(error)")
            return false
        }
        defer { world.remove() }
        let git = engine.git
        func shoot(_ state: String, _ view: some View) async {
            guard only.isEmpty || only.contains(state) else { return }
            written += await renderFloating(view, state: state)
        }
        func model(_ directory: String) async -> GitActionsModel {
            let repository = git.repository(for: directory)
            _ = await waitUntil(timeout: .seconds(5)) { repository.status != nil && repository.phase == .ready }
            let model = GitActionsModel(repository: repository, host: GitActionHost(
                createMergeRequest: {}, openMergeRequest: {}, generate: { _ in "Add the launch checklist" }, confirm: { _, _, _ in false },
                notice: { _ in }, publish: {}))
            await model.reload()
            repository.refresh()
            _ = await waitUntil(timeout: .seconds(5)) { !repository.isRefreshing }
            return model
        }

        // 1. Feature branch with changes and an unpushed commit: Commit, Push and Create MR is suggested.
        let feature = await model(world.feature)
        await shoot("actions-menu", GitActionsMenuView(model: feature, close: {}))

        // 2. Branch picker in local mode, typing a new name: "Create branch … and switch to it".
        let draft = WorkspaceDraft(git: git, projectDirectory: world.feature, projectID: nil)
        draft.load()
        draft.repository.loadBranches(force: true)
        _ = await waitUntil(timeout: .seconds(5)) { !draft.repository.branches.isEmpty }
        await shoot("branch-create", BranchPickerView(draft: draft, close: {}, query: "feat/onboarding-copy"))

        // 3. Commit and push with a generated message.
        await feature.perform(.commitPushAndCreateMergeRequest)
        if let form = feature.commit {
            await form.generateMessage()
            await shoot("commit-push", GitCommitView(form: form, actions: feature, close: {}))
        }

        // 4. Behind and ahead (diverged after a fetch): Sync is offered only as Pull with Rebase.
        _ = try? await world.runner.run(["fetch", "-q", "origin"], in: world.diverged, writableRoots: [world.base])
        let diverged = await model(world.diverged)
        await shoot("behind-ahead", GitActionsMenuView(model: diverged, close: {}))

        // 5. A merge stopped on conflicts: only Abort is offered, with the reason on every other action.
        let conflicted = await model(world.conflicted)
        await shoot("conflict", GitActionsMenuView(model: conflicted, close: {}))

        // 6. Rewind confirmation with "Revert files too" planned from a real checkpoint.
        let session = SessionID(rawValue: "ses_snapshot")
        let message = MessageID(rawValue: "msg_snapshot")
        let rewind = RewindModel(
            prompt: "Add a launch checklist to the README and link it from the docs index.",
            plan: { revert in
                var plan = RewindPlan(sessionID: session, messageID: message, directory: world.feature)
                if revert, let checkpoint = await GitCheckpoints.resolve(world.checkpointRef, directory: world.feature, runner: world.runner) {
                    plan.files = try await GitCheckpoints.planRestore(
                        directory: world.feature, checkpoint: checkpoint, undoRef: world.checkpointRef + "-undo", runner: world.runner)
                }
                return plan
            },
            perform: { _ in })
        await rewind.setRevertFiles(true)
        await shoot("rewind", RewindView(model: rewind, close: { _ in }))

        // 7. Clone from GitLab with the person's projects listed.
        let clone = GitCloneModel(instances: [MockGitLab.instance], search: { _, _ in [] }, start: { _, _ in })
        let now = Date()
        clone.setProjects([
            GitLabProjectSummary(id: 1, path: "platform/rocket", name: "rocket", description: "Launch control service", httpURL: MockGitLab.instance.baseURL + "/platform/rocket.git", webURL: "", defaultBranch: "main", lastActivity: now.addingTimeInterval(-3_600)),
            GitLabProjectSummary(id: 2, path: "platform/atlas", name: "atlas", description: "Maps and tiles", httpURL: MockGitLab.instance.baseURL + "/platform/atlas.git", webURL: "", defaultBranch: "main", lastActivity: now.addingTimeInterval(-86_400 * 2)),
            GitLabProjectSummary(id: 3, path: "team/handbook", name: "handbook", description: nil, httpURL: MockGitLab.instance.baseURL + "/team/handbook.git", webURL: "", defaultBranch: "main", lastActivity: now.addingTimeInterval(-86_400 * 9)),
        ])
        clone.selected = clone.projects.first
        clone.destination = "~/BelloCode/code.example.test/platform/rocket"
        await shoot("clone", GitCloneView(model: clone, close: { _ in }))

        for path in written { log("wrote \(path)") }
        log(written.isEmpty ? "FAIL nothing written" : "PASS \(written.count) images")
        return !written.isEmpty
    }

    /// Renders a SwiftUI surface as it appears floating (popover/panel surface: raised fill, border, radius 10) in
    /// light and dark.
    func renderFloating(_ view: some View, state: String) async -> [String] {
        let content = view
            .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).fill(SwiftUI.Color.ds.raised))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).stroke(SwiftUI.Color.ds.borderStrong, lineWidth: 1))
            .padding(24)
            .background(SwiftUI.Color.ds.canvas)
        let host = NSHostingController(rootView: AnyView(content))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.borderless]
        window.setFrameOrigin(NSPoint(x: 60, y: 60))
        window.orderFront(nil)
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(30)) }
        var paths: [String] = []
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearanceName)
            window.appearance = NSAppearance(named: appearanceName)
            window.setContentSize(host.view.fittingSize)
            window.displayIfNeeded()
            for _ in 0..<8 { try? await Task.sleep(for: .milliseconds(30)) }
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            SnapshotRunner.draw(view, into: bitmap)
            let mode = appearanceName == .darkAqua ? "dark" : "light"
            let file = directory.appending(path: "\(name)-\(state)-\(mode).png")
            guard let data = bitmap.representation(using: .png, properties: [:]), (try? data.write(to: file)) != nil else { continue }
            paths.append(file.path)
        }
        NSApp.appearance = nil
        window.orderOut(nil)
        return paths
    }
}

/// Throwaway repositories for the git snapshots: a bare origin, a feature branch with changes and an unpushed commit,
/// a diverged checkout, and a merge stopped on a conflict. Plain local paths; never the person's repositories.
struct GitSnapshotWorld {
    let base: String
    let runner: GitRunner
    let feature: String
    let diverged: String
    let conflicted: String
    let checkpointRef = GitCheckpoints.ref(session: SessionID(rawValue: "ses_snapshot"), message: MessageID(rawValue: "msg_snapshot"))

    static func make(instance: GitLabInstance) async throws -> GitSnapshotWorld {
        let base = HostGit.canonical(FileManager.default.temporaryDirectory.appending(path: "bellocode-git-snapshots-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        var environment = GitRunner.defaultEnvironment()
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        for (key, value) in ["GIT_AUTHOR_NAME": "Mara Lind", "GIT_AUTHOR_EMAIL": "mara@example.test", "GIT_COMMITTER_NAME": "Mara Lind", "GIT_COMMITTER_EMAIL": "mara@example.test"] {
            environment[key] = value
        }
        let runner = GitRunner(environment: environment, writableRoots: [base], allowsLocalRemotes: true)
        func git(_ arguments: [String], in directory: String) async throws { _ = try await runner.run(arguments, in: directory, writableRoots: [base]) }
        func write(_ path: String, _ text: String) throws {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(filePath: path))
        }
        let origin = base + "/origin.git"
        try await git(["init", "-q", "--bare", "-b", "main", origin], in: base)
        let seed = base + "/seed"
        try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
        try await git(["init", "-q", "-b", "main"], in: seed)
        try write(seed + "/README.md", "# Rocket\n\nLaunch control.\n")
        try write(seed + "/docs/index.md", "# Docs\n")
        try await git(["add", "-A"], in: seed)
        try await git(["commit", "-q", "-m", "Initial commit"], in: seed)
        try await git(["remote", "add", "origin", origin], in: seed)
        try await git(["push", "-q", "-u", "origin", "main"], in: seed)
        // Feature: a branch with one unpushed commit and uncommitted changes; origin points at the GitLab instance's
        // HTTPS URL for display (pushes in the snapshot are never sent).
        let feature = base + "/rocket"
        try await git(["clone", "-q", origin, feature], in: base)
        try await git(["switch", "-q", "-c", "feat/launch-checklist"], in: feature)
        _ = try await GitCheckpoints.capture(directory: feature, ref: GitCheckpoints.ref(session: SessionID(rawValue: "ses_snapshot"), message: MessageID(rawValue: "msg_snapshot")), runner: runner)
        try write(feature + "/CHECKLIST.md", "# Launch checklist\n\n- [ ] Fuel\n- [ ] Weather\n")
        try await git(["add", "-A"], in: feature)
        try await git(["commit", "-q", "-m", "Add the launch checklist"], in: feature)
        try await git(["push", "-q", "-u", "origin", "feat/launch-checklist"], in: feature)
        try write(feature + "/README.md", "# Rocket\n\nLaunch control. See CHECKLIST.md.\n")
        try write(feature + "/docs/index.md", "# Docs\n\n- [Launch checklist](../CHECKLIST.md)\n")
        try write(feature + "/docs/weather.md", "# Weather limits\n")
        try await git(["config", "remote.origin.pushurl", instance.baseURL + "/platform/rocket.git"], in: feature)
        // Diverged: one local commit, two new ones on origin.
        let diverged = base + "/diverged"
        try await git(["clone", "-q", origin, diverged], in: base)
        for index in 1...2 {
            try write(seed + "/notes-\(index).md", "note \(index)\n")
            try await git(["add", "-A"], in: seed)
            try await git(["commit", "-q", "-m", "Upstream change \(index)"], in: seed)
        }
        try await git(["push", "-q", "origin", "main"], in: seed)
        try write(diverged + "/local.md", "local\n")
        try await git(["add", "-A"], in: diverged)
        try await git(["commit", "-q", "-m", "Local change"], in: diverged)
        // Conflicted: a merge stopped on README.md.
        let conflicted = base + "/conflicted"
        try await git(["clone", "-q", origin, conflicted], in: base)
        try await git(["switch", "-q", "-c", "theirs", "origin/main~2"], in: conflicted)
        try write(conflicted + "/README.md", "# Rocket\n\nTheirs.\n")
        try await git(["commit", "-q", "-am", "Theirs"], in: conflicted)
        try await git(["switch", "-q", "main"], in: conflicted)
        try write(conflicted + "/README.md", "# Rocket\n\nOurs.\n")
        try await git(["commit", "-q", "-am", "Ours"], in: conflicted)
        _ = try await runner.run(["merge", "theirs"], in: conflicted, allowFailure: true)
        return GitSnapshotWorld(base: base, runner: runner, feature: feature, diverged: diverged, conflicted: conflicted)
    }

    func remove() { try? FileManager.default.removeItem(atPath: base) }
}
