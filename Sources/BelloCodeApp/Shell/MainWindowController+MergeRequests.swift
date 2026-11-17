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
}
