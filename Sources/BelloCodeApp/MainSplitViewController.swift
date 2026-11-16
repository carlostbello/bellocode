import AppKit
import DesignSystem
import SwiftUI

/// The three window regions: sidebar, content, and a collapsible right panel (an inspector split item).
///
/// Each region currently hosts a SwiftUI placeholder. Later work packages replace the view controllers; the split
/// structure, autosave and the toggle commands (`toggleSidebar:`, `toggleInspector:`) stay.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    private static let autosaveName = "BelloCodeMainSplit"

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin

        let sidebar = NSSplitViewItem(sidebarWithViewController: Self.placeholder(
            "Projects", systemImage: "sidebar.left", detail: "Projects and threads appear here."
        ))
        sidebar.minimumThickness = 200
        sidebar.maximumThickness = 400
        sidebar.canCollapse = true

        let content = NSSplitViewItem(viewController: Self.placeholder(
            "No Thread Selected", systemImage: "bubble.left.and.bubble.right", detail: "The transcript and composer appear here."
        ))
        content.minimumThickness = 360

        let panel = NSSplitViewItem(inspectorWithViewController: Self.placeholder(
            "Panel", systemImage: "sidebar.right", detail: "Diffs, terminal and browser tabs appear here."
        ))
        panel.minimumThickness = 260
        panel.maximumThickness = 720
        panel.canCollapse = true
        panel.isCollapsed = true

        addSplitViewItem(sidebar)
        addSplitViewItem(content)
        addSplitViewItem(panel)

        // Restores divider positions and collapsed state across launches.
        splitView.autosaveName = Self.autosaveName
    }

    private static func placeholder(_ title: String, systemImage: String, detail: String) -> NSViewController {
        let controller = NSHostingController(rootView: PlaceholderPane(title, systemImage: systemImage, detail: detail))
        // The split view, not SwiftUI's ideal size, decides pane widths.
        controller.sizingOptions = []
        return controller
    }
}
