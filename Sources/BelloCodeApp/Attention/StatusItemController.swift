import AppKit
import BelloCore
import DesignSystem
import Engine

/// The optional menu-bar item (Settings ▸ Notifications): a glyph with the blocker count, and a menu listing the
/// "Needs you" threads (status in words, project, age). Choosing one opens it in the front window.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let engine: Engine
    private let settings: AppSettings
    private var item: NSStatusItem?
    private var loop: ObservationLoop?
    var onOpen: (SessionID) -> Void = { _ in }
    /// Brings BelloCode forward before any window opens from the menu (another app is frontmost then; NF21).
    var activateApp: () -> Void = { NSApp.activate() }
    var onShowScheduledTasks: () -> Void = { (NSApp.delegate as? AppDelegate)?.showScheduledTasks(nil) }

    init(engine: Engine, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
        super.init()
    }

    isolated deinit { loop?.cancel() }

    func start() {
        loop = ObservationLoop { [weak self] in self?.update() }
    }

    private func update() {
        let shows = settings.notifications.showsMenuBarItem
        let summary = engine.root.attention
        guard shows else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let statusItem = item ?? {
            let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            created.menu = menu
            item = created
            return created
        }()
        let blockers = summary.counts.dockBadge
        statusItem.button?.image = NSImage(
            systemSymbolName: blockers > 0 ? "exclamationmark.bubble.fill" : "bubble.left", accessibilityDescription: "BelloCode")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = blockers > 0 ? " \(blockers)" : ""
        statusItem.button?.setAccessibilityLabel(blockers > 0 ? "BelloCode, \(blockers) need you" : "BelloCode, nothing needs you")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let items = engine.root.attention.items
        let header = NSMenuItem(title: items.isEmpty ? "Nothing needs you" : "Needs You", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let now = Date()
        for attention in items.prefix(20) {
            let row = engine.root.projects.lazy.compactMap { $0.projectID.flatMap(self.engine.root.project)?.row(attention.sessionID) }.first
            let project = engine.root.projects.first { $0.projectID == attention.projectID }?.name ?? ""
            let title = row?.session.displayTitle ?? "Thread"
            let entry = NSMenuItem(title: title, action: #selector(open(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = attention.sessionID.rawValue
            entry.image = StatusGlyph(attention.status).image()
            let detail = [StatusGlyph(attention.status).label, project, RelativeTime.short(attention.since.date, now: now)]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            entry.attributedTitle = NSAttributedString(
                string: "\(title)\n", attributes: [.font: NSFont.menuFont(ofSize: 0)])
                + NSAttributedString(string: detail, attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        // M3-B: scheduled tasks run while BelloCode is open, even with no window; show what runs next.
        if let schedules = engine.extras?.schedules {
            let next = schedules.nextRun
            let line = NSMenuItem(
                title: next.map { "Next scheduled: \($0.task.name), \(Self.when($0.date, now: now))" } ?? "No scheduled tasks pending",
                action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
            let tasks = NSMenuItem(title: "Scheduled Tasks…", action: #selector(showScheduledTasks(_:)), keyEquivalent: "")
            tasks.target = self
            menu.addItem(tasks)
            menu.addItem(.separator())
        }
        let show = NSMenuItem(title: "Open BelloCode", action: #selector(activate(_:)), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
    }

    static func when(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = date.timeIntervalSince(now) < 6 * 86_400 ? "EEE HH:mm" : "d MMM HH:mm"
        return formatter.string(from: date)
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        activateApp()
        onOpen(SessionID(raw))
    }

    @objc private func activate(_ sender: Any?) {
        activateApp()
        (NSApp.delegate as? AppDelegate)?.showFrontWindow()
    }

    @objc func showScheduledTasks(_ sender: Any?) {
        activateApp()
        onShowScheduledTasks()
    }
}

private func + (lhs: NSAttributedString, rhs: NSAttributedString) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: lhs)
    result.append(rhs)
    return result
}
