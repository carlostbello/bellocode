import AppKit
import BelloCore
import DesignSystem
import Engine
import OpenCodeKit
import WebKit

/// Browser commands, for the app's Browser menu (it maps each to a menu item, validates with `canPerform`).
public enum BrowserPaneCommand: String, CaseIterable, Sendable {
    case newTab, newPrivateTab, closeTab, reopenClosedTab, nextTab, previousTab
    case openLocation, back, forward, reload, reloadFromOrigin, stopLoading
    case zoomIn, zoomOut, actualSize, findInPage
    case openInDefaultBrowser, pickElement, shareTab, toggleWebInspector, clearSiteData
    case stopAgent, takeOver, resumeAgent, toggleAgentControl, reconnectAgent
    case responsiveOff, responsiveCustom, appearanceSystem, appearanceLight, appearanceDark
}

/// What the pane shows about the displayed thread (UX rule 6: context for anything acting on the thread).
public struct BrowserPaneContext: Equatable, Sendable {
    public var projectName: String
    public var threadTitle: String?
    public var sessionID: SessionID?
    public var projectDirectory: String

    public init(projectName: String, threadTitle: String?, sessionID: SessionID?, projectDirectory: String) {
        self.projectName = projectName
        self.threadTitle = threadTitle
        self.sessionID = sessionID
        self.projectDirectory = projectDirectory
    }
}

/// The browser pane for one window: tab strip, toolbar, prompts and agent bars, find bar, page, downloads shelf and a
/// status line with the agent connection and the thread it belongs to. It shows the set of the displayed thread and
/// swaps sets instantly when the thread changes (no reload: live web views move between sets' panes).
@MainActor
public final class BrowserPaneController: NSViewController {
    public let workspace: BrowserWorkspace
    public private(set) var set: BrowserTabSet?
    public private(set) var context: BrowserPaneContext?
    private let strip = BrowserTabStrip()
    private let toolbar = BrowserToolbarView()
    private let banners = NSStackView()
    private let findBar = BrowserFindBar()
    private let content = BrowserContentView()
    private let shelf = DownloadsShelfView()
    private let footer = NSView()
    private let footerIcon = NSImageView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let controlSwitch = NSSwitch()
    private let controlLabel = NSTextField(labelWithString: "Agent control")
    private var observerID: UUID?
    private var observedSet: BrowserTabSet?
    private var bridgeObservation: Task<Void, Never>?
    private var refreshScheduled = false
    private var bannerPool: [String: BrowserBanner] = [:]
    private var findText = ""

    public init(workspace: BrowserWorkspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        if let observerID { observedSet?.removeObserver(observerID) }
        bridgeObservation?.cancel()
    }

    public override func loadView() {
        let root = BrowserPaneView()
        root.pane = self
        root.setAccessibilityLabel("Browser")
        view = root
        strip.delegate = self
        banners.orientation = .vertical
        banners.alignment = .width
        banners.spacing = DS.Spacing.xs
        banners.edgeInsets = NSEdgeInsets(top: DS.Spacing.xs, left: DS.Spacing.s, bottom: DS.Spacing.xs, right: DS.Spacing.s)
        banners.detachesHiddenViews = true
        findBar.isHidden = true
        shelf.isHidden = true
        shelf.downloads = workspace.downloads
        content.onRetry = { [weak self] in self?.set?.selectedTab?.reload() }
        configureToolbar()
        configureFooter()
        let separators = (0..<3).map { _ -> NSBox in
            let box = NSBox()
            box.boxType = .separator
            return box
        }
        let stack = NSStackView(views: [strip, separators[0], toolbar, banners, findBar, content, separators[1], shelf, separators[2], footer])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            findBar.heightAnchor.constraint(equalToConstant: 30), footer.heightAnchor.constraint(equalToConstant: 24),
            banners.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        content.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        findBar.onChange = { [weak self] text in self?.find(text, forward: true) }
        findBar.onNext = { [weak self] forward in self.map { $0.find($0.findText, forward: forward) } }
        findBar.onClose = { [weak self] in self?.hideFind() }
        workspace.downloads.onChange = { [weak self] in self?.scheduleRefresh() }
        let previous = workspace.onWorkspaceChange
        workspace.onWorkspaceChange = { [weak self] in
            previous?()
            self?.scheduleRefresh()
        }
        refresh()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        if content.contentSize.width > 100 { workspace.lastPaneSize = content.contentSize }
        strip.update(set?.tabs ?? [], selectedID: set?.selectedTabID, availableWidth: view.bounds.width)
    }

    // MARK: Displaying a thread

    /// Shows a thread's set (nil: no thread, or a draft). Instant: no page reloads; the selected tab's web view moves here.
    public func display(_ set: BrowserTabSet?, context: BrowserPaneContext?) {
        self.context = context
        if observedSet !== set {
            if let observerID { observedSet?.removeObserver(observerID) }
            observerID = set?.observe { [weak self] tab, change in self?.setChanged(tab, change) }
            observedSet = set
            set?.stopPicking()
            hideFind()
        }
        self.set = set
        workspace.display(set)
        observeBridge()
        if isViewLoaded { refresh() }
    }

    private func observeBridge() {
        bridgeObservation?.cancel()
        guard let sessionID = set?.sessionID, let engine = workspace.engine else { return }
        let model = engine.browser.model(for: sessionID)
        bridgeObservation = Task { [weak self] in
            while !Task.isCancelled {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = model.status
                        _ = model.running.count
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { return }
                self?.scheduleRefresh()
            }
        }
    }

    private func setChanged(_ tab: BrowserTab?, _ change: BrowserTab.Change?) {
        if change == .progress, tab?.id == set?.selectedTabID {
            toolbar.update(tab: tab, picking: set?.pickingTabID == tab?.id)
            return
        }
        if let tab, tab.id != set?.selectedTabID, change != nil, change != .page {
            strip.update(set?.tabs ?? [], selectedID: set?.selectedTabID, availableWidth: view.bounds.width)
            return
        }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    /// Re-applies every visible piece of state (cheap: no page work).
    func refresh() {
        guard isViewLoaded else { return }
        let tab = set?.selectedTab
        if let tab, view.window != nil, !tab.isLive { tab.ensureWebView() }
        strip.update(set?.tabs ?? [], selectedID: set?.selectedTabID, availableWidth: view.bounds.width)
        strip.isHidden = set == nil
        toolbar.update(tab: tab, picking: set?.pickingTabID != nil && set?.pickingTabID == tab?.id)
        toolbar.isHidden = set == nil
        content.display(tab)
        updateBanners(tab)
        updateFooter()
        let hasDownloads = !workspace.downloads.items.isEmpty
        shelf.isHidden = !hasDownloads
        if hasDownloads { shelf.update() }
        if let webView = tab?.webView {
            webView.contextMenuProvider = { [weak self] menu in self?.extendContextMenu(menu) }
        }
    }

    // MARK: Banners

    private func banner(_ id: String) -> BrowserBanner {
        if let banner = bannerPool[id] { return banner }
        let banner = BrowserBanner()
        bannerPool[id] = banner
        return banner
    }

    private func updateBanners(_ tab: BrowserTab?) {
        var shown: [BrowserBanner] = []
        let status = set?.sessionID.flatMap { workspace.engine?.browser.model(for: $0).status }
        if let status, status.needsAttention, let sessionID = set?.sessionID {
            let bar = banner("bridge")
            var actions: [BrowserBanner.Action] = []
            if status == .replaced || { if case .unavailable = status { true } else { false } }() {
                actions.append(.init(title: "Reconnect", isDefault: false) { [weak self] in self?.workspace.engine?.browser.reconnect(sessionID) })
            }
            bar.configure(id: "bridge-\(status.label)", symbol: "bolt.horizontal.circle", tone: .attention, message: "\(status.label). \(status.detail)", actions: actions)
            shown.append(bar)
        }
        if let tab {
            if let activity = tab.agentActivity, !tab.isAgentPaused {
                let bar = banner("agent")
                bar.configure(id: "agent", symbol: "cursorarrow.motionlines", tone: .accent, message: "Agent is controlling this tab — \(activity)", actions: [
                    .init(title: "Stop") { [weak self] in self?.set?.stopAgent() },
                    .init(title: "Take Over") { [weak self] in self?.set?.takeOver(tab.id) },
                ])
                shown.append(bar)
            } else if tab.isAgentPaused {
                let bar = banner("paused")
                bar.configure(id: "paused", symbol: "pause.circle.fill", tone: .attention, message: "You took over this tab. The agent is paused here and can only read it.", actions: [
                    .init(title: "Resume Agent") { [weak self] in self?.set?.resumeAgent(on: tab.id) },
                ])
                shown.append(bar)
            }
            if let dialog = tab.dialog {
                let bar = banner("dialog")
                let isPrompt = dialog.type == "prompt"
                bar.configure(
                    id: "dialog-\(dialog.type)", symbol: "exclamationmark.bubble", tone: .attention,
                    message: "\(tab.url?.host() ?? "The page") says: \(dialog.message)",
                    fields: isPrompt ? [(placeholder: "Answer", secure: false, value: dialog.defaultValue)] : [],
                    actions: dialog.type == "alert"
                        ? [.init(title: "OK", isDefault: true) { tab.answerDialog(accept: true) }]
                        : [
                            .init(title: "Cancel") { tab.answerDialog(accept: false) },
                            .init(title: "OK", isDefault: true) { [weak bar] in tab.answerDialog(accept: true, text: bar?.textFields.first?.stringValue) },
                        ])
                shown.append(bar)
            }
            if let prompt = tab.permissionPrompt {
                let bar = banner("permission")
                bar.configure(id: "permission", symbol: "video.badge.ellipsis", tone: .attention, message: "\(prompt.origin) wants to use your \(prompt.kinds). Denied unless you allow it.", actions: [
                    .init(title: "Deny") { tab.answerPermission(allow: false, remember: false) },
                    .init(title: "Allow Once") { tab.answerPermission(allow: true, remember: false) },
                    .init(title: "Always Allow This Site") { tab.answerPermission(allow: true, remember: true) },
                ])
                shown.append(bar)
            }
            if let auth = tab.authPrompt {
                let bar = banner("auth")
                bar.configure(
                    id: "auth", symbol: "person.badge.key", tone: .neutral,
                    message: "\(auth.isProxy ? "Proxy" : auth.host) asks you to sign in\(auth.realm.isEmpty ? "" : " (\(auth.realm))"). Not saved.",
                    fields: [(placeholder: "User name", secure: false, value: ""), (placeholder: "Password", secure: true, value: "")],
                    actions: [
                        .init(title: "Cancel") { tab.answerAuth(user: nil, password: nil) },
                        .init(title: "Sign In", isDefault: true) { [weak bar] in
                            tab.answerAuth(user: bar?.textFields.first?.stringValue ?? "", password: bar?.textFields.last?.stringValue ?? "")
                        },
                    ])
                shown.append(bar)
            }
        }
        if let sessionID = set?.sessionID, let offer = workspace.offers[BrowserWorkspace.key(for: sessionID)], let context {
            let bar = banner("offer")
            bar.configure(id: "offer-\(offer.absoluteString)", symbol: "server.rack", tone: .neutral, message: "A dev server is running at \(BrowserAddress.display(offer)).", actions: [
                .init(title: "Not Now") { [weak self] in self?.workspace.dismissOffer(for: sessionID) },
                .init(title: "Open") { [weak self] in self?.workspace.acceptOffer(for: sessionID, projectDirectory: context.projectDirectory) },
            ])
            shown.append(bar)
        }
        if set?.pickingTabID != nil, set?.pickingTabID == tab?.id {
            let bar = banner("picking")
            bar.configure(id: "picking", symbol: "scope", tone: .accent, message: "Click an element on the page to add it to the composer. Escape cancels.", actions: [
                .init(title: "Cancel") { [weak self] in self?.set?.stopPicking() },
            ])
            shown.append(bar)
        }
        if let pending = workspace.pendingPick, pending.setKey == set?.key {
            let bar = banner("pick")
            let element = "<\(pending.pick.tag)>\(pending.pick.name.isEmpty ? "" : " “\(pending.pick.name.prefix(40))”")"
            bar.configure(
                id: "pick-\(pending.pick.selector)", symbol: "text.bubble", tone: .accent, message: "Picked \(element). Add a note for the agent:",
                fields: [(placeholder: "What should change?", secure: false, value: "")],
                actions: [
                    .init(title: "Discard") { [weak self] in self?.workspace.discardPick() },
                    .init(title: "Add to Composer", isDefault: true) { [weak self, weak bar] in self?.workspace.commitPick(note: bar?.textFields.first?.stringValue ?? "") },
                ])
            shown.append(bar)
        }
        let current = banners.arrangedSubviews
        if current.count != shown.count || zip(current, shown).contains(where: { $0 !== $1 }) {
            for view in current { banners.removeArrangedSubview(view); view.removeFromSuperview() }
            for bar in shown {
                banners.addArrangedSubview(bar)
                bar.translatesAutoresizingMaskIntoConstraints = false
                bar.widthAnchor.constraint(equalTo: banners.widthAnchor, constant: -2 * DS.Spacing.s).isActive = true
            }
        }
        banners.isHidden = shown.isEmpty
    }

    // MARK: Footer

    private func configureFooter() {
        footerIcon.imageScaling = .scaleProportionallyDown
        footerLabel.font = DS.Typography.current.caption
        footerLabel.textColor = DS.Palette.secondaryText
        footerLabel.lineBreakMode = .byTruncatingMiddle
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controlLabel.font = DS.Typography.current.caption
        controlLabel.textColor = DS.Palette.secondaryText
        controlSwitch.controlSize = .mini
        controlSwitch.target = self
        controlSwitch.action = #selector(controlSwitchChanged)
        controlSwitch.setAccessibilityLabel("Let this thread's agent control the browser")
        for view in [footerIcon, footerLabel, controlLabel, controlSwitch] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(view)
        }
        NSLayoutConstraint.activate([
            footerIcon.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: DS.Spacing.m),
            footerIcon.centerYAnchor.constraint(equalTo: footer.centerYAnchor), footerIcon.widthAnchor.constraint(equalToConstant: 12),
            footerLabel.leadingAnchor.constraint(equalTo: footerIcon.trailingAnchor, constant: DS.Spacing.xs),
            footerLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: controlLabel.leadingAnchor, constant: -DS.Spacing.m),
            controlLabel.trailingAnchor.constraint(equalTo: controlSwitch.leadingAnchor, constant: -DS.Spacing.xs),
            controlLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            controlSwitch.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -DS.Spacing.m),
            controlSwitch.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        footer.setAccessibilityElement(true)
        footer.setAccessibilityRole(.group)
    }

    private func updateFooter() {
        guard let context else {
            footerIcon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            footerLabel.stringValue = "Select a thread to use its browser"
            controlSwitch.isHidden = true
            controlLabel.isHidden = true
            return
        }
        let where_ = [context.projectName, context.threadTitle].compactMap { $0 }.joined(separator: " › ")
        guard let sessionID = context.sessionID, let engine = workspace.engine else {
            footerIcon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            footerLabel.stringValue = set == nil ? "Browser tabs belong to a thread. Send a message to start one. · \(where_)" : where_
            controlSwitch.isHidden = true
            controlLabel.isHidden = true
            return
        }
        let model = engine.browser.model(for: sessionID)
        let status = model.status
        let shared = set?.sharedTabs.count ?? 0
        let (symbol, tint): (String, NSColor) = switch status {
        case .attached: (model.running.isEmpty ? "sparkle" : "cursorarrow.motionlines", DS.Palette.accent)
        case .disabled, .off, .parked: ("sparkle", DS.Palette.secondaryText)
        case .connecting, .retrying, .waitingForServer: ("arrow.triangle.2.circlepath", DS.Palette.secondaryText)
        case .replaced, .unavailable, .incompatible: ("exclamationmark.triangle.fill", DS.Palette.attention)
        }
        footerIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        footerIcon.contentTintColor = tint
        let tabs = status == .attached ? " · \(shared) shared tab\(shared == 1 ? "" : "s")" : ""
        footerLabel.stringValue = "\(status.label)\(tabs) · \(where_)"
        footerLabel.toolTip = status.detail
        footer.setAccessibilityLabel("\(status.label)\(tabs). \(status.detail) \(where_)")
        controlSwitch.isHidden = false
        controlLabel.isHidden = false
        controlSwitch.state = engine.browser.isControlEnabled(sessionID) ? .on : .off
    }

    @objc private func controlSwitchChanged() { perform(.toggleAgentControl) }

    // MARK: Toolbar

    private func configureToolbar() {
        toolbar.back.target = self
        toolbar.back.action = #selector(backPressed)
        toolbar.forward.target = self
        toolbar.forward.action = #selector(forwardPressed)
        toolbar.reload.target = self
        toolbar.reload.action = #selector(reloadPressed)
        toolbar.pick.target = self
        toolbar.pick.action = #selector(pickPressed)
        toolbar.share.target = self
        toolbar.share.action = #selector(sharePressed)
        toolbar.viewport.target = self
        toolbar.viewport.action = #selector(viewportPressed(_:))
        toolbar.appearanceButton.target = self
        toolbar.appearanceButton.action = #selector(appearancePressed(_:))
        toolbar.more.target = self
        toolbar.more.action = #selector(morePressed(_:))
        toolbar.address.onSubmit = { [weak self] text in self?.go(text) }
        toolbar.address.suggestionsProvider = { [weak self] text in self?.workspace.history.suggestions(for: text) ?? [] }
        toolbar.address.completionProvider = { [weak self] text in self?.workspace.history.inlineCompletion(for: text) }
    }

    @objc private func backPressed() { perform(.back) }
    @objc private func forwardPressed() { perform(.forward) }
    @objc private func reloadPressed() { perform(set?.selectedTab?.isLoading == true ? .stopLoading : .reload) }
    @objc private func pickPressed() { perform(.pickElement) }
    @objc private func sharePressed() { perform(.shareTab) }

    @objc private func viewportPressed(_ sender: NSButton) {
        let menu = NSMenu()
        let current = set?.selectedTab?.viewport
        let fill = NSMenuItem(title: "Fill Pane", action: #selector(viewportChosen(_:)), keyEquivalent: "")
        fill.state = current == nil ? .on : .off
        fill.target = self
        menu.addItem(fill)
        menu.addItem(.separator())
        for (index, preset) in ViewportPreset.presets.enumerated() {
            let item = NSMenuItem(title: "\(preset.name)  \(preset.width) × \(preset.height)", action: #selector(viewportChosen(_:)), keyEquivalent: "")
            item.tag = index + 1
            item.target = self
            item.state = current == preset ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(title: "Custom Size…", action: #selector(customViewport), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func viewportChosen(_ sender: NSMenuItem) {
        guard let tab = set?.selectedTab else { return }
        tab.viewport = sender.tag == 0 ? nil : ViewportPreset.presets[sender.tag - 1]
        workspace.setChanged(set!)
        refresh()
    }

    @objc private func customViewport() {
        guard let tab = set?.selectedTab, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Custom Viewport Size"
        alert.informativeText = "Width and height in CSS pixels (200–3840)."
        let width = NSTextField(string: "\(tab.viewport?.width ?? 1024)")
        let height = NSTextField(string: "\(tab.viewport?.height ?? 768)")
        for field in [width, height] { field.widthAnchor.constraint(equalToConstant: 80).isActive = true }
        let stack = NSStackView(views: [width, NSTextField(labelWithString: "×"), height])
        stack.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                tab.viewport = ViewportPreset.custom(width: Int(width.intValue), height: Int(height.intValue))
                if let set = self?.set { self?.workspace.setChanged(set) }
                self?.refresh()
            }
        }
    }

    @objc private func appearancePressed(_ sender: NSButton) {
        let menu = NSMenu()
        for (index, appearance) in PageAppearance.allCases.enumerated() {
            let item = NSMenuItem(title: appearance.title, action: #selector(appearanceChosen(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            item.state = set?.selectedTab?.appearance == appearance ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func appearanceChosen(_ sender: NSMenuItem) {
        perform([BrowserPaneCommand.appearanceSystem, .appearanceLight, .appearanceDark][sender.tag])
    }

    @objc private func morePressed(_ sender: NSButton) {
        let menu = NSMenu()
        let entries: [(String, BrowserPaneCommand)] = [
            ("Open in Default Browser", .openInDefaultBrowser), ("Find in Page…", .findInPage),
            ("Zoom In", .zoomIn), ("Zoom Out", .zoomOut), ("Actual Size", .actualSize),
            ("New Private Tab", .newPrivateTab), ("Reopen Closed Tab", .reopenClosedTab),
            (workspace.isWebInspectorEnabled ? "Disallow Web Inspector" : "Allow Web Inspector", .toggleWebInspector),
            ("Clear Site Data for This Project…", .clearSiteData),
        ]
        for (index, entry) in entries.enumerated() {
            if [2, 5, 7].contains(index) { menu.addItem(.separator()) }
            let item = NSMenuItem(title: entry.0, action: #selector(menuCommand(_:)), keyEquivalent: "")
            item.representedObject = entry.1.rawValue
            item.target = self
            item.isEnabled = canPerform(entry.1)
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func menuCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = BrowserPaneCommand(rawValue: raw) else { return }
        perform(command)
    }

    private func extendContextMenu(_ menu: NSMenu) {
        menu.addItem(.separator())
        for (title, command) in [("Pick Element for Composer", BrowserPaneCommand.pickElement), ("Open Page in Default Browser", .openInDefaultBrowser)] {
            let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: "")
            item.representedObject = command.rawValue
            item.target = self
            menu.addItem(item)
        }
    }

    // MARK: Commands

    /// Opens what the person typed: a URL, a host, or a search. Creates a tab when there is none.
    public func go(_ text: String) {
        guard let url = BrowserAddress.resolve(text, searchTemplate: workspace.searchTemplate) else { return }
        guard let set else { return }
        if let tab = set.selectedTab { tab.load(url) } else { set.newTab(url: url) }
        view.window?.makeFirstResponder(set.selectedTab?.webView)
    }

    public func canPerform(_ command: BrowserPaneCommand) -> Bool {
        let tab = set?.selectedTab
        switch command {
        case .newTab, .newPrivateTab: return set != nil
        case .reopenClosedTab: return set?.canReopenClosedTab ?? false
        case .closeTab, .openLocation, .findInPage, .zoomIn, .zoomOut, .actualSize, .shareTab, .responsiveOff, .responsiveCustom,
            .appearanceSystem, .appearanceLight, .appearanceDark:
            if command == .shareTab { return tab != nil && tab?.isPrivate == false && set?.sessionID != nil }
            return tab != nil
        case .nextTab, .previousTab: return (set?.tabs.count ?? 0) > 1
        case .back: return tab?.canGoBack ?? false
        case .forward: return tab?.canGoForward ?? false
        case .reload, .reloadFromOrigin: return tab != nil
        case .stopLoading: return tab?.isLoading ?? false
        case .openInDefaultBrowser: return tab?.url.map { $0.scheme?.hasPrefix("http") == true } ?? false
        case .pickElement: return tab?.isLive == true && tab?.url != nil
        case .toggleWebInspector: return true
        case .clearSiteData: return context != nil
        case .stopAgent: return set?.tabs.contains { $0.agentActivity != nil } ?? false
        case .takeOver: return tab?.isShared == true && tab?.isAgentPaused == false
        case .resumeAgent: return tab?.isAgentPaused ?? false
        case .toggleAgentControl: return set?.sessionID != nil && workspace.engine != nil
        case .reconnectAgent:
            guard let sessionID = set?.sessionID, let status = workspace.engine?.browser.model(for: sessionID).status else { return false }
            return status == .replaced || status == .parked || { if case .unavailable = status { true } else { false } }()
        }
    }

    public func perform(_ command: BrowserPaneCommand) {
        guard canPerform(command) else { return NSSound.beep() }
        let tab = set?.selectedTab
        switch command {
        case .newTab:
            set?.newTab()
            focusAddress()
        case .newPrivateTab:
            set?.newTab(isPrivate: true)
            focusAddress()
        case .closeTab: if let tab { set?.close(tab.id) }
        case .reopenClosedTab: set?.reopenClosedTab()
        case .nextTab: set?.selectAdjacent(1)
        case .previousTab: set?.selectAdjacent(-1)
        case .openLocation: focusAddress()
        case .back: tab?.goBack()
        case .forward: tab?.goForward()
        case .reload: tab?.reload()
        case .reloadFromOrigin: tab?.reload(fromOrigin: true)
        case .stopLoading: tab?.stopLoading()
        case .zoomIn: tab.map { $0.zoom = min(3, ($0.zoom * 1.1 * 100).rounded() / 100) }
        case .zoomOut: tab.map { $0.zoom = max(0.3, ($0.zoom / 1.1 * 100).rounded() / 100) }
        case .actualSize: tab?.zoom = 1
        case .findInPage: showFind()
        case .openInDefaultBrowser: if let url = tab?.url { NSWorkspace.shared.open(url) }
        case .pickElement:
            if set?.pickingTabID != nil { set?.stopPicking() } else { set?.startPicking() }
        case .shareTab: if let tab { set?.setShared(!tab.isShared, tab: tab.id) }
        case .toggleWebInspector:
            workspace.isWebInspectorEnabled.toggle()
        case .clearSiteData: confirmClearSiteData()
        case .stopAgent: set?.stopAgent()
        case .takeOver: if let tab { set?.takeOver(tab.id) }
        case .resumeAgent: if let tab { set?.resumeAgent(on: tab.id) }
        case .toggleAgentControl:
            if let sessionID = set?.sessionID, let browser = workspace.engine?.browser {
                browser.setControlEnabled(!browser.isControlEnabled(sessionID), for: sessionID)
            }
        case .reconnectAgent: if let sessionID = set?.sessionID { workspace.engine?.browser.reconnect(sessionID) }
        case .responsiveOff: tab?.viewport = nil
        case .responsiveCustom: customViewport()
        case .appearanceSystem: tab?.appearance = .system
        case .appearanceLight: tab?.appearance = .light
        case .appearanceDark: tab?.appearance = .dark
        }
        if let set, [.zoomIn, .zoomOut, .actualSize, .responsiveOff, .appearanceSystem, .appearanceLight, .appearanceDark].contains(command) {
            workspace.setChanged(set)
        }
        scheduleRefresh()
    }

    public func focusAddress() {
        view.window?.makeFirstResponder(toolbar.address)
    }

    /// Selecting a responsive preset from the app's menu.
    public func setViewport(_ preset: ViewportPreset?) {
        guard let tab = set?.selectedTab, let set else { return }
        tab.viewport = preset
        workspace.setChanged(set)
        refresh()
    }

    private func confirmClearSiteData() {
        guard let context, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear site data for “\(context.projectName)”?"
        alert.informativeText = "Cookies, sign-ins, local storage and caches of this project's browser profile are removed. Open pages keep running. This cannot be undone."
        alert.addButton(withTitle: "Clear Site Data")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.workspace.clearSiteData(projectDirectory: context.projectDirectory) }
            }
        }
    }

    // MARK: Find

    public var isFindVisible: Bool { !findBar.isHidden }

    public func showFind() {
        findBar.isHidden = false
        view.window?.makeFirstResponder(findBar.field)
        findBar.field.currentEditor()?.selectAll(nil)
    }

    func hideFind() {
        guard !findBar.isHidden else { return }
        findBar.isHidden = true
        findText = ""
        findBar.count.stringValue = ""
        if let webView = set?.selectedTab?.webView {
            view.window?.makeFirstResponder(webView)
            // Clears WebKit's find highlight.
            webView.find("\u{0}", configuration: WKFindConfiguration()) { _ in }
        }
    }

    public func find(_ text: String, forward: Bool) {
        findText = text
        guard let tab = set?.selectedTab, let webView = tab.webView, !text.isEmpty else {
            findBar.count.stringValue = ""
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.wraps = true
        configuration.caseSensitive = false
        webView.find(text, configuration: configuration) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.findText == text else { return }
                if !result.matchFound { self.findBar.count.stringValue = "Not found" }
            }
        }
        Task { [weak self] in
            let count = (try? await tab.agent("countMatches", ["text": .string(text)], timeout: .seconds(2)))?.intValue ?? 0
            guard let self, self.findText == text else { return }
            self.findBar.count.stringValue = count == 0 ? "Not found" : "\(count) match\(count == 1 ? "" : "es")"
        }
    }

    /// The tab strip's and content's state, for the snapshot harness.
    public var selectedTab: BrowserTab? { self.set?.selectedTab }
}

// MARK: - Tab strip delegate

extension BrowserPaneController: BrowserTabStripDelegate {
    func tabStrip(_ strip: BrowserTabStrip, select id: String) { set?.select(id) }
    func tabStrip(_ strip: BrowserTabStrip, close id: String) { set?.close(id) }
    func tabStrip(_ strip: BrowserTabStrip, move id: String, to index: Int) { set?.move(id, to: index) }
    func tabStripNewTab(_ strip: BrowserTabStrip) { perform(.newTab) }

    func tabStrip(_ strip: BrowserTabStrip, menuFor id: String) -> NSMenu {
        let menu = NSMenu()
        guard let tab = set?.tab(id) else { return menu }
        func add(_ title: String, enabled: Bool = true, _ action: @escaping @MainActor () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        if set?.sessionID != nil {
            add(tab.isShared ? "Stop Sharing with Agent" : "Share with Agent", enabled: !tab.isPrivate) { [weak self] in
                self?.set?.setShared(!tab.isShared, tab: id)
            }
            menu.addItem(.separator())
        }
        add("Duplicate Tab", enabled: tab.url != nil && !tab.isPrivate) { [weak self] in
            _ = self?.set?.newTab(url: tab.url, select: true, after: id)
        }
        add("Open in Default Browser", enabled: tab.url?.scheme?.hasPrefix("http") == true) { if let url = tab.url { NSWorkspace.shared.open(url) } }
        add("Copy Address", enabled: tab.url != nil) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.url?.absoluteString ?? "", forType: .string)
        }
        menu.addItem(.separator())
        add("Close Tab") { [weak self] in self?.set?.close(id) }
        add("Close Other Tabs", enabled: (set?.tabs.count ?? 0) > 1) { [weak self] in
            for other in self?.set?.tabs.map(\.id) ?? [] where other != id { self?.set?.close(other) }
        }
        return menu
    }
}

/// A menu item that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, action handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

/// The pane's root view. While focus is inside the browser, ⌘F, ⌘G and ⇧⌘G find in the page: it answers the shell's
/// Find selectors before the window does (the same arrangement the terminal uses for ⌘K).
@MainActor
final class BrowserPaneView: NSView {
    weak var pane: BrowserPaneController?

    @objc func findInTranscript(_ sender: Any?) { pane?.perform(.findInPage) }
    @objc func findNextInTranscript(_ sender: Any?) { pane.map { $0.find($0.findBarText, forward: true) } }
    @objc func findPreviousInTranscript(_ sender: Any?) { pane.map { $0.find($0.findBarText, forward: false) } }

    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(findInTranscript(_:)) || selector == #selector(findNextInTranscript(_:)) || selector == #selector(findPreviousInTranscript(_:)) {
            return MainActor.assumeIsolated { pane?.selectedTab != nil }
        }
        return super.responds(to: selector)
    }
}

extension BrowserPaneController {
    var findBarText: String { findBar.field.stringValue }
}

extension BrowserPaneController {
    /// Puts text in the find field (the snapshot harness).
    func findBarSet(_ text: String) { findBar.field.stringValue = text }
}
