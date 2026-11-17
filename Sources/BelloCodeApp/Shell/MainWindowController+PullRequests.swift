import AppKit
import Engine

// M3-B: the "Pull Requests" right-panel tab (PullRequestSurface.swift) and opening links in the built-in browser.

extension MainWindowController {
    func showPullRequestsPanel() {
        if split.panelItem.isCollapsed { split.setCollapsed(split.panelItem, false) }
        rightPanel.select("pullRequests")
        workspace.updateLayout(rightPanelTab: "pullRequests")
    }

    /// Wires the extras into a displayed thread's context (called from the display hook).
    func attachExtras(_ context: ThreadSurfaceContext?) {
        pullRequests?.display(context)
        context?.onOpenInBrowser = { [weak self] url in self?.browser?.open(url) ?? false }
    }

    @objc func showPullRequests(_ sender: Any?) { showPullRequestsPanel() }
}
