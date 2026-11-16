// SPIKE (gate G3). A window around the BrowserHost: tab strip, agent activity line, dialog banner, web content.
// Agent activity is always visible to the person: the status line names each command and the acted-on element is
// outlined in the page.

import AppKit
import BrowserKit

@MainActor
final class SpikeWindow {
    let window: NSWindow
    let host: BrowserHost
    private let tabsLabel = NSTextField(labelWithString: "No tabs")
    private let activity = NSTextField(labelWithString: "Agent idle")
    private let dialogBar = NSStackView()
    private let dialogLabel = NSTextField(labelWithString: "")

    init(host: BrowserHost) {
        self.host = host
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 840), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "BelloCode G3 browser spike"
        window.isReleasedWhenClosed = false
        for label in [tabsLabel, activity, dialogLabel] {
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        activity.textColor = .secondaryLabelColor
        let accept = NSButton(title: "Accept", target: nil, action: nil)
        let dismiss = NSButton(title: "Dismiss", target: nil, action: nil)
        accept.target = self
        accept.action = #selector(acceptDialog)
        dismiss.target = self
        dismiss.action = #selector(dismissDialog)
        dialogBar.orientation = .horizontal
        dialogBar.addArrangedSubview(NSImageView(image: NSImage(systemSymbolName: "exclamationmark.bubble", accessibilityDescription: "Page dialog")!))
        dialogBar.addArrangedSubview(dialogLabel)
        dialogBar.addArrangedSubview(accept)
        dialogBar.addArrangedSubview(dismiss)
        dialogBar.isHidden = true
        let stack = NSStackView(views: [tabsLabel, activity, dialogBar, host.contentView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 0, right: 8)
        host.contentView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        NSLayoutConstraint.activate([
            host.contentView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            host.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 700),
        ])
        host.onActivity = { [weak self] text in self?.activity.stringValue = text }
        host.onChange = { [weak self] in self?.refresh() }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func refresh() {
        let names = host.tabs.map { tab in
            let state = tab.state
            return (state.id == host.focusedTabID ? "▸ " : "  ") + (state.title.isEmpty ? state.url : state.title) + (state.loading ? " (loading)" : "")
        }
        tabsLabel.stringValue = names.isEmpty ? "No tabs" : names.joined(separator: "   |")
        if let dialog = host.focusedTab?.pendingDialog {
            dialogLabel.stringValue = "Page \(dialog.type): \(dialog.message)"
            dialogBar.isHidden = false
        } else {
            dialogBar.isHidden = true
        }
    }

    @objc private func acceptDialog() { host.focusedTab?.respondToDialog(accept: true) }
    @objc private func dismissDialog() { host.focusedTab?.respondToDialog(accept: false) }
}
