import AgentUI
import AppKit
import BelloCore
import ComposerKit
import DesignSystem
import Engine
import OrchestrationUI
import SwiftUI
import TerminalKit

/// One Settings pane. Later packages add panes here (each a real pane; no placeholders are shown).
@MainActor
struct SettingsPane {
    var id: String
    var title: String
    var symbolName: String
    var make: @MainActor () -> NSViewController
}

/// The Settings window (⌘,): a sidebar of panes beside the selected pane's grouped rows (visual-language.md, the
/// spec's settings layout), not the stock toolbar of tabs. Transparent title bar; the traffic lights sit in the
/// sidebar's top 52 pt like the main window. ↑/↓ in the sidebar switch panes; each pane is built once.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let root: SettingsRootViewController
    private(set) var panes: [SettingsPane]

    init(
        settings: AppSettings, auth: AuthService?, importSource: CredentialImportSource?, engine: Engine? = nil,
        notifier: AttentionNotifier? = nil, openThread: ((SessionID) -> Void)? = nil
    ) {
        var panes = [
            SettingsPane(id: "general", title: "General", symbolName: "gearshape") {
                let controller = NSHostingController(rootView: GeneralSettingsView(settings: settings))
                controller.sizingOptions = [.preferredContentSize]
                return controller
            },
            SettingsPane(id: "terminal", title: "Terminal", symbolName: "terminal") {
                let controller = NSHostingController(rootView: TerminalSettingsView(settings: settings))
                controller.sizingOptions = [.preferredContentSize]
                return controller
            },
            SettingsPane(id: "browser", title: "Browser", symbolName: "globe") {
                let browse = BrowseStatusModel(configDirectory: AppRuntime.applicationSupport().appending(path: "opencode/config"))
                let controller = NSHostingController(rootView: BrowserSettingsView(settings: settings, browse: browse))
                controller.sizingOptions = [.preferredContentSize]
                return controller
            },
        ]
        if let engine {
            panes.append(
                SettingsPane(id: "threads", title: "Threads", symbolName: "tray.2") {
                    let controller = NSHostingController(rootView: ThreadSettingsView(engine: engine, root: engine.root))
                    controller.sizingOptions = [.preferredContentSize]
                    return controller
                })
            panes.append(
                SettingsPane(id: "notifications", title: "Notifications", symbolName: "bell.badge") {
                    let controller = NSHostingController(
                        rootView: NotificationSettingsView(settings: settings, root: engine.root, notifier: notifier))
                    controller.sizingOptions = [.preferredContentSize]
                    return controller
                })
            // M6-A containerised execution (docs/features/containers.md).
            panes.append(
                SettingsPane(id: "containers", title: "Containers", symbolName: "shippingbox") {
                    let view = ContainersSettingsView(model: ContainersSettingsModel(engine: engine), service: engine.environments) { container in
                        let alert = NSAlert()
                        alert.messageText = "Remove the container \(container.name)?"
                        alert.informativeText = "Processes in it stop. Project files are on this Mac and are not touched; the container is created again on next use."
                        alert.addButton(withTitle: "Remove")
                        alert.addButton(withTitle: "Cancel")
                        alert.buttons.first?.hasDestructiveAction = true
                        return alert.runModal() == .alertFirstButtonReturn
                    }
                    let controller = NSHostingController(rootView: view)
                    controller.sizingOptions = [.preferredContentSize]
                    return controller
                })
            panes.append(
                SettingsPane(id: "environment", title: "Environment", symbolName: "cube.transparent") {
                    let model = EnvironmentSettingsModel(engine: engine, directory: EnvironmentSettingsModel.preferredDirectory)
                    model.openTerminal = { _ in EnvironmentSettingsModel.openTerminalInFrontWindow() }
                    model.openBrowser = { url in
                        // The built-in browser of the front window's thread; the default browser without one.
                        let front = NSApp.orderedWindows.compactMap { $0.windowController as? MainWindowController }.first
                        if front?.browser?.open(url) != true { NSWorkspace.shared.open(url) }
                    }
                    EnvironmentSettingsModel.last = model
                    let controller = NSHostingController(rootView: EnvironmentSettingsView(model: model))
                    controller.sizingOptions = [.preferredContentSize]
                    return controller
                })
            if let extras = engine.extras {
                // M3-B (docs/features/orchestration-extras.md).
                panes.append(
                    SettingsPane(id: "schedules", title: "Scheduled Tasks", symbolName: "calendar.badge.clock") {
                        let model = ScheduledTasksModel(scheduler: extras.schedules)
                        model.projects = { engine.root.projects.map { ($0.name, $0.directory) } }
                        model.threads = { directory in
                            guard let projectID = engine.root.projects.first(where: { $0.directory == directory })?.projectID,
                                let graph = engine.orchestration?.graph
                            else { return [] }
                            return graph.nodes.values.filter { $0.projectID == projectID && $0.parentID == nil }
                                .sorted { $0.created > $1.created }.prefix(40).map { ($0.title, $0.id) }
                        }
                        model.openThread = { id in openThread?(id) }
                        ScheduledTasksModelRegistry.last = model
                        let controller = NSHostingController(rootView: ScheduledTasksView(model: model))
                        controller.sizingOptions = [.preferredContentSize]
                        return controller
                    })
                panes.append(
                    SettingsPane(id: "gitlab", title: "GitLab", symbolName: "arrow.triangle.pull") {
                        let model = GitLabSettingsModel(service: extras.mergeRequests)
                        let view = GitLabSettingsView(model: model) { instance in
                            let alert = NSAlert()
                            alert.messageText = "Remove \(instance.baseURL)?"
                            alert.informativeText = "Its access token is deleted from your Keychain. Linked merge requests on it stop updating until you add it again with a token."
                            alert.addButton(withTitle: "Remove")
                            alert.addButton(withTitle: "Cancel")
                            alert.buttons.first?.hasDestructiveAction = true
                            return alert.runModal() == .alertFirstButtonReturn
                        }
                        let controller = NSHostingController(rootView: view)
                        controller.sizingOptions = [.preferredContentSize]
                        return controller
                    })
                panes.append(
                    SettingsPane(id: "secrets", title: "Secrets", symbolName: "key") {
                        let view = SecretsSettingsView(secrets: extras.secrets, visuals: extras.visuals) { label in
                            let alert = NSAlert()
                            alert.messageText = "Delete “\(label.label)”?"
                            alert.informativeText = "The value is removed from your Keychain. Agents holding a reference to it can no longer use it. This cannot be undone."
                            alert.addButton(withTitle: "Delete")
                            alert.addButton(withTitle: "Cancel")
                            alert.buttons.first?.hasDestructiveAction = true
                            return alert.runModal() == .alertFirstButtonReturn
                        }
                        let controller = NSHostingController(rootView: view)
                        controller.sizingOptions = [.preferredContentSize]
                        return controller
                    })
            }
        }
        if let auth {
            panes.append(
                SettingsPane(id: "accounts", title: "Accounts", symbolName: "person.crop.circle") {
                    let controller = AgentUIFactories.accountsSettings(auth: auth, importSource: importSource, style: AppStyle.agentUI)
                    controller.preferredContentSize = NSSize(width: 620, height: 460)
                    return controller
                })
        }
        self.panes = panes
        root = SettingsRootViewController(panes: panes)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = root
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "BelloCodeSettingsToolbar")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = DS.Color.canvas
        window.minSize = NSSize(width: 720, height: 460)
        window.setContentSize(NSSize(width: 860, height: 620))
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BelloCodeSettings2")
        super.init(window: window)
        window.delegate = self
        root.onSelect = { [weak window] pane in window?.title = pane.title }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the window on a pane ("general", "accounts").
    func show(pane: String? = nil) {
        if let pane { root.select(pane) } else { root.selectIfNeeded() }
        window?.title = root.selectedPane?.title ?? "Settings"
        showWindow(nil)
        window?.center()
    }

    var selectedPaneID: String? { root.selectedPane?.id }

    var paneIDs: [String] { panes.map(\.id) }
}

/// Settings ▸ General.
struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsPaneBody {
            SettingsGroup("Send messages with") {
                SettingsRadioRows(
                    options: [(SendKey.returnKey, "Return (⇧↩ for a new line)"), (SendKey.commandReturn, "⌘ Return (↩ for a new line)")],
                    selection: $settings.sendKey)
            }
            SettingsGroup("Appearance") {
                SettingsRow("Theme", divided: false) {
                    DSSegmentedPicker(options: AppSettings.Appearance.allCases.map { ($0, $0.title) }, selection: $settings.appearance)
                        .fixedSize()
                }
                SettingsSliderRow(
                    title: "Text size", range: AppSettings.fontSizeRange, accessibilityLabel: "Text size", value: $settings.baseFontSize)
            }
        }
    }
}

/// Settings ▸ Terminal.
struct TerminalSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsPaneBody {
            SettingsGroup("Display") {
                SettingsSliderRow(
                    title: "Font size",
                    range: Double(TerminalPreferences.fontSizeRange.lowerBound)...Double(TerminalPreferences.fontSizeRange.upperBound),
                    accessibilityLabel: "Terminal font size", value: fontSize, divided: false)
                SettingsRow("Scrollback") {
                    SettingsMenuPicker(
                        label: "Scrollback",
                        options: [(1_000, "1,000 lines"), (10_000, "10,000 lines"), (50_000, "50,000 lines"), (100_000, "100,000 lines")],
                        selection: $settings.terminalPreferences.scrollback)
                }
            }
            SettingsGroup("Keyboard and clipboard", footer: "Terminal output is untrusted. Programs can never read the clipboard.") {
                SettingsToggleRow("Use Option as Meta key", divided: false, isOn: $settings.terminalPreferences.optionAsMeta)
                SettingsToggleRow("Ask before pasting several lines into a shell", isOn: $settings.terminalPreferences.confirmsMultilinePaste)
                SettingsToggleRow("Let programs copy to the clipboard (OSC 52)", isOn: $settings.terminalPreferences.allowsClipboardWrites)
            }
        }
    }

    private var fontSize: Binding<Double> {
        Binding(
            get: { Double(settings.terminalPreferences.fontSize) },
            set: { settings.terminalPreferences.fontSize = CGFloat($0) })
    }
}

/// A small titled window hosting a view controller (onboarding, Connect Provider). Never modal.
@MainActor
final class UtilityWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(title: String, content: NSViewController, size: NSSize) {
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = DS.Color.canvas
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

/// The Settings window's content: a 200 pt sidebar of panes (`sidebar` surface, rows in the neutral row recipe, a
/// 14 pt glyph and the title) and the selected pane under a 52 pt title bar, scrolled on `canvas`.
@MainActor
final class SettingsRootViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let panes: [SettingsPane]
    let table = NSTableView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let document = DSFlippedView()
    private var built: [String: NSViewController] = [:]
    private(set) var selectedPane: SettingsPane?
    var onSelect: ((SettingsPane) -> Void)?

    static let sidebarWidth: CGFloat = 200

    init(panes: [SettingsPane]) {
        self.panes = panes
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = PanelBackgroundView()
        let sidebar = PanelBackgroundView()
        sidebar.color = DS.Color.sidebar
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.rowHeight = DS.Size.sidebarRow
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = false
        table.setAccessibilityLabel("Settings panes")
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.drawsBackground = false
        tableScroll.hasVerticalScroller = true
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        DSScroller.install(on: tableScroll)
        let divider = DSDivider(vertical: true)
        divider.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = DS.TextRole.title.font
        titleLabel.textColor = DS.Color.text
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        let headerLine = DSDivider()
        headerLine.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        DSScroller.install(on: scrollView)
        document.translatesAutoresizingMaskIntoConstraints = false
        for view in [sidebar, tableScroll, divider, titleLabel, headerLine, scrollView] as [NSView] { container.addSubview(view) }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: container.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            tableScroll.topAnchor.constraint(equalTo: container.topAnchor, constant: DS.Size.header),
            tableScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: DS.Border.hairline),
            titleLabel.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: DS.Space.s24),
            titleLabel.centerYAnchor.constraint(equalTo: container.topAnchor, constant: DS.Size.header / 2),
            headerLine.topAnchor.constraint(equalTo: container.topAnchor, constant: DS.Size.header),
            headerLine.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            headerLine.heightAnchor.constraint(equalToConstant: DS.Border.hairline),
            scrollView.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        selectIfNeeded()
    }

    func selectIfNeeded() {
        if selectedPane == nil, let first = panes.first { select(first.id) }
    }

    /// Shows a pane by ID (building its controller once).
    func select(_ id: String) {
        _ = view
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return }
        let pane = panes[index]
        if table.selectedRow != index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        guard selectedPane?.id != id else { return }
        selectedPane = pane
        titleLabel.stringValue = pane.title
        for child in children { child.view.removeFromSuperview() }
        let controller = built[id] ?? {
            let controller = pane.make()
            built[id] = controller
            addChild(controller)
            return controller
        }()
        let paneView = controller.view
        paneView.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(paneView)
        NSLayoutConstraint.activate([
            paneView.topAnchor.constraint(equalTo: document.topAnchor, constant: DS.Space.s20),
            paneView.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: DS.Space.s24),
            paneView.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -DS.Space.s24),
            paneView.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -DS.Space.s24),
        ])
        if let height = (controller.preferredContentSize.height > 0 ? controller.preferredContentSize.height : nil),
           controller is NSHostingController<AnyView> == false, !(paneView is NSHostingView<AnyView>), paneView.fittingSize.height < 1
        {
            paneView.heightAnchor.constraint(equalToConstant: height).isActive = true
            paneView.widthAnchor.constraint(equalToConstant: max(controller.preferredContentSize.width, 520)).isActive = true
        }
        scrollView.contentView.scroll(to: .zero)
        table.enumerateAvailableRowViews { rowView, row in (rowView as? DSTableRowView)?.isActive = row == index }
        onSelect?(pane)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { panes.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = DSTableRowView()
        rowView.isActive = panes[row].id == selectedPane?.id
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: SettingsPaneCell.identifier, owner: nil) as? SettingsPaneCell ?? SettingsPaneCell()
        cell.configure(panes[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, table.selectedRow < panes.count else { return }
        select(panes[table.selectedRow].id)
    }
}

/// A pane row in the Settings sidebar: 14 pt glyph tinted `icon`, title `body`.
@MainActor
final class SettingsPaneCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("settingsPane")
    private let icon = ProjectIcon()
    private let title = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = DS.TextRole.body.font
        title.textColor = DS.Color.sidebarText
        title.lineBreakMode = .byTruncatingTail
        textField = title
        for view in [icon, title] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarMetrics.glyphX),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: DS.Space.s6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -SidebarMetrics.glyphX),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ pane: SettingsPane) {
        icon.symbolName = pane.symbolName
        title.stringValue = pane.title
        setAccessibilityLabel(pane.title)
    }
}
