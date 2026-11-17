import AppKit
import BelloCore
import DesignSystem
import Engine
import OrchestrationUI
import SwiftUI

/// What the Agents surface needs from the window.
@MainActor
protocol AgentsShell: AnyObject {
    /// Shows the right panel on its "Agents" tab.
    func showAgentsPanel()
    var isAgentsPanelShown: Bool { get }
}

/// The window's Agents panel (OrchestrationUI, docs/features/orchestration.md): the "Agents" right-panel tab, following
/// the displayed thread. Created by `ShellSurfaces.builtIn` (Seams.swift) and bound by `MainWindowController`.
@MainActor
final class AgentsSurfaces {
    private(set) var model: AgentsPanelModel?
    private let host = NSViewController()
    private weak var shell: (any AgentsShell)?
    private(set) var context: ThreadSurfaceContext?

    init() {
        host.view = NSView()
    }

    func makePanelController() -> NSViewController { host }

    /// Binds to a window's engine. Idempotent.
    func bind(engine: Engine, shell: any AgentsShell) {
        self.shell = shell
        guard model == nil, let orchestration = engine.orchestration else { return }
        let model = AgentsPanelModel(orchestration: orchestration)
        model.onOpen = { [weak self] id in self?.context?.onOpenThread?(id) }
        self.model = model
        let hosting = NSHostingController(rootView: AgentsPanelView(model: model))
        hosting.sizingOptions = []
        host.addChild(hosting)
        hosting.view.frame = host.view.bounds
        hosting.view.autoresizingMask = [.width, .height]
        host.view.addSubview(hosting.view)
        display(context)
    }

    func display(_ context: ThreadSurfaceContext?) {
        self.context = context
        model?.display(context?.thread?.sessionID)
    }

    func show() { shell?.showAgentsPanel() }
}
