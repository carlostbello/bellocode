import AppKit
import Engine

// M3-B: the "Merge Requests" right-panel tab (MergeRequestSurface.swift) and opening links in the built-in browser.

extension MainWindowController {
    func showMergeRequestsPanel() {
        if split.panelItem.isCollapsed { split.setCollapsed(split.panelItem, false) }
        rightPanel.select("mergeRequests")
        workspace.updateLayout(rightPanelTab: "mergeRequests")
    }

    /// Wires the extras into a displayed thread's context (called from the display hook).
    func attachExtras(_ context: ThreadSurfaceContext?) {
        mergeRequests?.display(context)
        context?.onOpenInBrowser = { [weak self] url in self?.browser?.open(url) ?? false }
    }

    @objc func showMergeRequests(_ sender: Any?) { showMergeRequestsPanel() }

    /// Create Merge Request (Changes panel button and menu item) opens the inline form in the Merge Requests tab when a
    /// thread is shown and GitLab is configured; otherwise the Changes panel opens GitLab's own page.
    func wireCreateMergeRequest() {
        changes?.panel.createMergeRequestHandler = { [weak self] in
            guard let self, let surfaces = self.mergeRequests, surfaces.context?.thread != nil,
                self.workspace.engine.extras?.mergeRequests.instances.isEmpty == false
            else { return false }
            surfaces.showCreate()
            return true
        }
    }
}
