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
        self.model = model
        let hosting = NSHostingController(rootView: MergeRequestPanelView(model: model))
        hosting.sizingOptions = []
        host.addChild(hosting)
        hosting.view.frame = host.view.bounds
        hosting.view.autoresizingMask = [.width, .height]
        host.view.addSubview(hosting.view)
        display(context)
    }

    func display(_ context: ThreadSurfaceContext?) {
        self.context = context
        context?.onShowMergeRequests = { [weak self] in self?.showPanel() }
        model?.display(context?.thread?.sessionID)
    }
}
