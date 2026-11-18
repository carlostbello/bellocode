import AppKit
import BelloCore
import Engine
import OrchestrationUI
import SwiftUI

/// The window's "Merge Requests" right-panel tab (M3-B, docs/features/orchestration-extras.md), following the displayed
/// thread. Created by `ShellSurfaces.builtIn` (Seams.swift) and bound by `MainWindowController`.
@MainActor
final class MergeRequestSurfaces {
    private(set) var model: MergeRequestPanelModel?
    private let host = NSViewController()
    private(set) var context: ThreadSurfaceContext?
    var showPanel: () -> Void = {}

    init() {
        host.view = NSView()
    }

    func makePanelController() -> NSViewController { host }

    /// Binds to a window's engine. Idempotent.
    func bind(engine: Engine) {
        guard model == nil, let extras = engine.extras else { return }
        let model = MergeRequestPanelModel(service: extras.mergeRequests)
        model.openURL = { [weak self] url, builtIn in
            if builtIn, self?.context?.onOpenInBrowser?(url) == true { return }
            NSWorkspace.shared.open(url)
        }
        model.openSettings = { (NSApp.delegate as? AppDelegate)?.openSettings(pane: "gitlab") }
        model.insertIntoComposer = { [weak self] text in self?.context?.onInsertIntoComposer?(text) }
        model.confirm = { title, detail, button in Self.confirm(title, detail, button) }
        model.makeCreateContext = { [weak self, weak engine] id in
            guard let engine, let directory = self?.context?.directory ?? engine.orchestration?.node(id)?.node.directory else { return nil }
            return Self.createContext(engine: engine, sessionID: id, directory: directory)
        }
        self.model = model
        let hosting = NSHostingController(rootView: MergeRequestPanelView(model: model))
        hosting.sizingOptions = []
        host.addChild(hosting)
        hosting.view.frame = host.view.bounds
        hosting.view.autoresizingMask = [.width, .height]
        host.view.addSubview(hosting.view)
        display(context)
    }

    /// Shows the inline create form for the displayed thread (Changes ▸ Create Merge Request, Thread menu).
    func showCreate() {
        showPanel()
        if model?.create == nil { model?.openCreate() }
    }

    static func confirm(_ title: String, _ detail: String, _ button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The create form's view of a thread: git (the person's own transport) for status, push and commits; the
    /// thread's model for a proposal.
    static func createContext(engine: Engine, sessionID: SessionID, directory: String) -> CreateMergeRequestContext {
        let model = engine.git.repository(for: directory)
        return CreateMergeRequestContext(
            sessionID: sessionID, directory: directory,
            checkout: {
                let repository = model.repository
                guard let status = try? await repository.status() else { return nil }
                let remote = try? await repository.remoteURL()
                return CheckoutState(branch: status.branch, remote: remote ?? nil, upstream: status.upstream, ahead: status.ahead)
            },
            push: {
                try await model.push()
            },
            commits: { target in
                let repository = model.repository
                for range in ["origin/\(target)..HEAD", "\(target)..HEAD"] {
                    if let commits = try? await repository.commits(range, limit: 50) { return commits.reversed().map(\.subject) }
                }
                return []
            },
            generate: { prompt in try await engine.generateText(in: sessionID, prompt: prompt) })
    }

    func display(_ context: ThreadSurfaceContext?) {
        self.context = context
        context?.onShowMergeRequests = { [weak self] in self?.showPanel() }
        model?.display(context?.thread?.sessionID)
    }
}
