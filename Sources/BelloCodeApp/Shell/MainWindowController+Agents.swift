import AppKit
import BelloCore
import Engine
import OrchestrationUI

/// Agents panel commands (docs/features/orchestration.md). Every panel action has a menu item here.
struct AgentsCommandState: Equatable, Sendable {
    /// A thread is displayed (the panel has a tree to act on).
    var available = false
    var hasSelection = false
    var selectionIsOther = false
    var canStopSelection = false
    var selectionIsChild = false
    var hasParent = false
}

extension MainWindowController: AgentsShell {
    func showAgentsPanel() {
        if split.panelItem.isCollapsed {
            split.setCollapsed(split.panelItem, false)
        }
        rightPanel.select("agents")
        workspace.updateLayout(rightPanelTab: "agents")
    }

    var isAgentsPanelShown: Bool { !split.panelItem.isCollapsed && rightPanel.selectedID == "agents" }

    func agentsCommandState() -> AgentsCommandState {
        guard let model = agents?.model, let threadID = model.threadID else { return AgentsCommandState() }
        let selected = model.selection ?? threadID
        let node = model.orchestration.node(selected)?.node
        return AgentsCommandState(
            available: true, hasSelection: node != nil, selectionIsOther: selected != threadID,
            canStopSelection: model.canStop(selected), selectionIsChild: node?.parentID != nil,
            hasParent: model.orchestration.node(threadID)?.node.parentID != nil)
    }

    func performAgents(_ command: ShellCommand) {
        guard let agents, let model = agents.model else { return NSSound.beep() }
        switch command {
        case .showAgents: showAgentsPanel()
        case .nextAgent:
            showAgentsPanel()
            model.moveSelection(by: 1)
        case .previousAgent:
            showAgentsPanel()
            model.moveSelection(by: -1)
        case .openAgent: model.openSelected()
        case .followUpAgent:
            showAgentsPanel()
            if let id = model.selection ?? model.threadID { model.beginFollowUp(id) }
        case .stopAgentTree:
            if let id = model.selection ?? model.threadID { model.stop(id) }
        case .openParentThread: model.openParent()
        default: break
        }
    }

    @objc func showAgents(_ sender: Any?) { perform(.showAgents) }
    @objc func selectNextAgent(_ sender: Any?) { perform(.nextAgent) }
    @objc func selectPreviousAgent(_ sender: Any?) { perform(.previousAgent) }
    @objc func openSelectedAgent(_ sender: Any?) { perform(.openAgent) }
    @objc func followUpSelectedAgent(_ sender: Any?) { perform(.followUpAgent) }
    @objc func stopSelectedAgentTree(_ sender: Any?) { perform(.stopAgentTree) }
    @objc func openParentThread(_ sender: Any?) { perform(.openParentThread) }
}
