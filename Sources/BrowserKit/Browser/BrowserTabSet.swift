import AppKit
import BelloCore
import Engine
import OpenCodeKit
import WebKit

/// A saved tab (private tabs are never saved).
public struct BrowserTabRecord: Codable, Sendable, Equatable {
    public var id: String
    public var url: String?
    public var title: String
    public var owner: BrowserTabOwner
    public var shared: Bool
    public var zoom: Double?
    public var appearance: PageAppearance?
    public var viewport: ViewportPreset?
    /// WebKit's session state (back/forward list), bounded.
    public var interactionState: Data?
}

/// A thread's saved browser set.
public struct BrowserSetRecord: Codable, Sendable, Equatable {
    public var tabs: [BrowserTabRecord]
    public var selectedTabID: String?
    public var updated: Date
}

/// What the person picked in inspect mode, ready for the composer.
public struct BrowserPick: Sendable, Equatable {
    public var url: String
    public var pageTitle: String
    public var selector: String
    public var tag: String
    public var role: String
    public var name: String
    public var text: String
    /// CSS pixels in the viewport.
    public var rect: CGRect
    /// The element's pixels (PNG), when it could be captured.
    public var image: Data?
    public var note: String

    /// The context block inserted into the composer.
    public var contextText: String {
        var lines = [
            "Element picked in the browser",
            "Page: \(pageTitle.isEmpty ? url : "\(pageTitle) — \(url)")",
            "Selector: \(selector)",
            "Element: <\(tag)>\(role != tag ? " role=\(role)" : "")\(name.isEmpty ? "" : " name=\"\(name)\"")",
            "Box: x \(Int(rect.minX)), y \(Int(rect.minY)), \(Int(rect.width))×\(Int(rect.height)) CSS px",
        ]
        if !text.isEmpty { lines.append("Text: \(text.prefix(1_000))") }
        if !note.isEmpty { lines.append("Note: \(note)") }
        return lines.joined(separator: "\n")
    }
}

/// A thread's browser: its tabs, selection and recently closed tabs, and the desktop side of the agent bridge for that
/// thread's session (`BrowserBridgeHost`).
///
/// Ownership and safety (docs/features/browser.md): the agent sees and acts only on shared tabs (tabs it opened, and tabs
/// the person shared); private tabs are never shared; the person interacting with a tab the agent drives pauses the
/// agent there until Resume; the person can stop a running command or take over at any time.
@MainActor
public final class BrowserTabSet: NSObject {
    public enum InputMode: String, Sendable {
        /// Synthesized NSEvents delivered to the web view: `isTrusted` input, with script fallbacks when impossible.
        case native
        /// DOM events dispatched from the isolated world: `isTrusted == false` (self-test only).
        case script
    }

    public let key: String
    public let sessionID: SessionID?
    public let projectDirectory: String
    weak var workspace: BrowserWorkspace?
    public private(set) var tabs: [BrowserTab] = []
    public private(set) var selectedTabID: String?
    private var closed: [BrowserTabRecord] = []
    static let closedLimit = 20
    let userContent = WKUserContentController()
    public var inputMode: InputMode = .native
    /// Called on every change; `tab` nil for set-level changes (tabs added, removed, reordered, selection).
    var observers: [UUID: (BrowserTab?, BrowserTab.Change?) -> Void] = [:]
    /// The pick in progress (inspect mode) and its tab.
    public private(set) var pickingTabID: String?
    /// How each pointer/typing operation was delivered: "native" or "script (<reason>)". Bounded, content-free.
    public private(set) var deliveryLog: [String] = []
    /// One line per agent command (operation and tab), bounded and content-free, for diagnostics.
    public private(set) var commandLog: [String] = []
    public var lastScreenshot: Data?
    /// Saved state finished loading (tabs restored).
    public private(set) var isLoaded = false

    init(key: String, sessionID: SessionID?, projectDirectory: String, workspace: BrowserWorkspace) {
        self.key = key
        self.sessionID = sessionID
        self.projectDirectory = projectDirectory
        self.workspace = workspace
        super.init()
        let agentWorld = WKContentWorld.world(name: AgentScript.worldName)
        userContent.addUserScript(WKUserScript(source: AgentScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: agentWorld))
        userContent.addUserScript(WKUserScript(source: AgentScript.consoleSource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        userContent.add(WeakMessageHandler(self), contentWorld: agentWorld, name: AgentScript.agentHandler)
        userContent.add(WeakMessageHandler(self), contentWorld: .page, name: AgentScript.consoleHandler)
    }

    func shutdown() {
        for tab in tabs { tab.close() }
        tabs.removeAll()
        userContent.removeAllScriptMessageHandlers()
    }

    public var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabID } }
    public func tab(_ id: String) -> BrowserTab? { tabs.first { $0.id == id } }
    public var canReopenClosedTab: Bool { !closed.isEmpty }
    public var sharedTabs: [BrowserTab] { tabs.filter { $0.isShared && !$0.isPrivate } }

    func makeConfiguration(isPrivate: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContent
        if let workspace {
            configuration.websiteDataStore = isPrivate
                ? workspace.profiles.privateStore(forThread: key) : workspace.profiles.store(forProject: projectDirectory)
        } else {
            configuration.websiteDataStore = .nonPersistent()
        }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        return configuration
    }

    // MARK: Observation

    @discardableResult
    func observe(_ handler: @escaping (BrowserTab?, BrowserTab.Change?) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    private func notify(_ tab: BrowserTab?, _ change: BrowserTab.Change?) {
        for observer in observers.values { observer(tab, change) }
    }

    func tabChanged(_ tab: BrowserTab, _ change: BrowserTab.Change) {
        notify(tab, change)
        guard change == .page || change == .lifecycle else { return }
        if change == .page, tab.isShared { workspace?.publishBridge(self) }
        if change == .page { workspace?.setChanged(self) }
    }

    private func structureChanged() {
        notify(nil, nil)
        workspace?.setChanged(self)
        workspace?.publishBridge(self)
    }

    // MARK: Restoring

    func restore(_ record: BrowserSetRecord) {
        guard tabs.isEmpty else {
            isLoaded = true
            return
        }
        tabs = record.tabs.filter { BrowserContract.isTabID($0.id) }.map { BrowserTab(record: $0, set: self) }
        selectedTabID = tabs.contains { $0.id == record.selectedTabID } ? record.selectedTabID : tabs.first?.id
        isLoaded = true
        structureChanged()
    }

    func markLoaded() {
        isLoaded = true
        notify(nil, nil)
    }

    var record: BrowserSetRecord {
        let saved = tabs.filter { !$0.isPrivate }.map(\.record)
        let selected = tabs.first { $0.id == selectedTabID && !$0.isPrivate }?.id ?? saved.first?.id
        return BrowserSetRecord(tabs: saved, selectedTabID: selected, updated: Date())
    }

    // MARK: Tabs (the person)

    /// Opens a tab. Tabs the person opens are not shared with the agent unless `shared` (default: not shared).
    @discardableResult
    public func newTab(
        url: URL? = nil, isPrivate: Bool = false, select: Bool = true, owner: BrowserTabOwner = .user, shared: Bool = false,
        after: String? = nil
    ) -> BrowserTab {
        let tab = BrowserTab(owner: owner, isShared: owner == .agent || shared, isPrivate: isPrivate, set: self)
        if let after, let index = tabs.firstIndex(where: { $0.id == after }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        if select || selectedTabID == nil { selectedTabID = tab.id }
        if let url {
            tab.load(url)
        }
        workspace?.enforceLiveBudget()
        structureChanged()
        return tab
    }

    public func select(_ id: String) {
        guard let tab = tab(id), selectedTabID != id else { return }
        selectedTabID = id
        tab.lastUsed = Date()
        workspace?.enforceLiveBudget()
        structureChanged()
    }

    public func selectAdjacent(_ offset: Int) {
        guard let current = tabs.firstIndex(where: { $0.id == selectedTabID }), !tabs.isEmpty else { return }
        select(tabs[(current + offset + tabs.count) % tabs.count].id)
    }

    /// Closes a tab (remembered for Reopen Closed Tab unless private).
    public func close(_ id: String, byAgent: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        if !tab.isPrivate {
            closed.append(tab.record)
            if closed.count > Self.closedLimit { closed.removeFirst() }
        }
        if pickingTabID == id { pickingTabID = nil }
        tab.close()
        if selectedTabID == id { selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        if !tabs.contains(where: \.isPrivate) { workspace?.profiles.releasePrivateStore(forThread: key) }
        structureChanged()
    }

    @discardableResult
    public func reopenClosedTab() -> BrowserTab? {
        guard let record = closed.popLast() else { return nil }
        let tab = BrowserTab(record: record, set: self)
        tabs.append(tab)
        selectedTabID = tab.id
        workspace?.enforceLiveBudget()
        structureChanged()
        return tab
    }

    public func move(_ id: String, to destination: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        tabs.insert(tab, at: min(max(destination, 0), tabs.count))
        structureChanged()
    }

    /// Shares a tab with this thread's agent, or stops sharing it (agent tabs can be unshared too). Never private tabs.
    public func setShared(_ shared: Bool, tab id: String) {
        guard let tab = tab(id), !tab.isPrivate, tab.isShared != shared else { return }
        tab.isShared = shared
        if !shared { tab.isAgentPaused = false }
        structureChanged()
    }

    // MARK: Agent control (the person)

    /// Agent input on this tab paused because the person interacted; the pane shows Resume.
    func agentPaused(_ tab: BrowserTab) {
        if let sessionID, tab.agentActivity != nil { workspace?.engine?.browser.cancelRunning(sessionID) }
        notify(tab, .agent)
    }

    /// Lets the agent continue on a tab the person paused.
    public func resumeAgent(on id: String) {
        guard let tab = tab(id) else { return }
        tab.isAgentPaused = false
        tab.changed(.agent)
    }

    /// Take Over: stop the running command and pause the agent on this tab.
    public func takeOver(_ id: String) {
        guard let tab = tab(id) else { return }
        stopAgent()
        tab.isAgentPaused = true
        tab.changed(.agent)
    }

    /// Stop: cancel the agent's running commands (the agent gets `cancelled` and may continue with others).
    public func stopAgent() {
        if let sessionID { workspace?.engine?.browser.cancelRunning(sessionID) }
    }

    // MARK: Popups

    func openPopup(from opener: BrowserTab, configuration: WKWebViewConfiguration) -> BrowserTab? {
        let tab = BrowserTab(owner: opener.owner, isShared: opener.isShared, isPrivate: opener.isPrivate, set: self)
        if let index = tabs.firstIndex(where: { $0.id == opener.id }) { tabs.insert(tab, at: index + 1) } else { tabs.append(tab) }
        tab.ensureWebView(configuration: configuration)
        selectedTabID = tab.id
        workspace?.enforceLiveBudget()
        structureChanged()
        return tab
    }

    // MARK: Inspect mode (pick element)

    public func startPicking() {
        guard let tab = selectedTab, tab.isLive else { return }
        if let previous = pickingTabID, previous != tab.id { stopPicking() }
        pickingTabID = tab.id
        Task { _ = try? await tab.agent("pickStart", [:], timeout: .seconds(3)) }
        notify(tab, .agent)
    }

    public func stopPicking() {
        guard let id = pickingTabID else { return }
        pickingTabID = nil
        if let tab = tab(id) {
            Task { _ = try? await tab.agent("pickStop", [:], timeout: .seconds(3)) }
            notify(tab, .agent)
        }
    }

    private func picked(_ body: JSONValue, tab: BrowserTab) {
        guard pickingTabID == tab.id else { return }
        stopPicking()
        let rect = CGRect(
            x: body["rect"]?["x"]?.numberValue ?? 0, y: body["rect"]?["y"]?.numberValue ?? 0,
            width: body["rect"]?["width"]?.numberValue ?? 0, height: body["rect"]?["height"]?.numberValue ?? 0)
        var pick = BrowserPick(
            url: body["url"]?.stringValue ?? "", pageTitle: body["title"]?.stringValue ?? "", selector: body["selector"]?.stringValue ?? "",
            tag: body["tag"]?.stringValue ?? "", role: body["role"]?.stringValue ?? "", name: body["name"]?.stringValue ?? "",
            text: body["text"]?.stringValue ?? "", rect: rect, image: nil, note: "")
        Task { [weak self] in
            pick.image = await Self.capture(tab: tab, cssRect: rect)
            guard let self else { return }
            self.workspace?.picked(pick, in: self)
        }
    }

    /// A PNG of an element's box, scaled for the composer.
    static func capture(tab: BrowserTab, cssRect: CGRect) async -> Data? {
        guard let webView = tab.webView, webView.window != nil else { return nil }
        let zoom = webView.pageZoom
        let rect = CGRect(x: cssRect.minX * zoom, y: cssRect.minY * zoom, width: cssRect.width * zoom, height: cssRect.height * zoom)
            .insetBy(dx: -4, dy: -4).intersection(webView.bounds)
        guard !rect.isEmpty else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        if rect.width > 1_200 { configuration.snapshotWidth = 1_200 }
        guard let image = try? await webView.takeSnapshot(configuration: configuration), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: Messages from injected scripts

    fileprivate func receive(_ message: WKScriptMessage) {
        guard let tab = tabs.first(where: { $0.webView === message.webView }) else { return }
        let body = JSONValue(foundation: message.body)
        if message.name == AgentScript.consoleHandler {
            tab.receiveConsole(body)
            return
        }
        switch body["kind"]?.stringValue {
        case "frame": tab.receiveFrame(body, info: message.frameInfo)
        case "pick" where message.frameInfo.isMainFrame: picked(body, tab: tab)
        case "pickCancel": stopPicking()
        default: break
        }
    }

    // MARK: Agent activity helpers (used by BrowserOperations)

    func logDelivery(_ operation: String, _ how: String) {
        deliveryLog.append("\(operation): \(how)")
        if deliveryLog.count > 500 { deliveryLog.removeFirst() }
    }

    /// Outlines the element the agent acts on (the pane draws it when the tab is shown).
    func flash(_ tab: BrowserTab, cssRect: CGRect, offset: CGPoint) {
        guard let webView = tab.webView else { return }
        let zoom = webView.pageZoom
        let rect = CGRect(x: (cssRect.minX + offset.x) * zoom, y: (cssRect.minY + offset.y) * zoom, width: cssRect.width * zoom, height: cssRect.height * zoom)
        notifyHighlight(tab, rect)
    }

    /// Moves the agent's cursor to a click point (CSS pixels of the main frame).
    func pointAgentCursor(_ tab: BrowserTab, css: CGPoint) {
        guard let webView = tab.webView else { return }
        let zoom = webView.pageZoom
        tab.agentCursor = CGPoint(x: css.x * zoom, y: css.y * zoom)
        tab.changed(.agent)
    }

    private(set) var highlight: (tabID: String, rect: CGRect, until: Date)?
    private func notifyHighlight(_ tab: BrowserTab, _ rect: CGRect) {
        highlight = (tab.id, rect, Date().addingTimeInterval(1.2))
        tab.changed(.agent)
    }

    func navigate(_ tab: BrowserTab, to address: String) async throws {
        guard let url = URL(string: address), ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") else {
            throw BrowserFailure(.invalidURL, "Use an HTTP/HTTPS URL or about:blank.")
        }
        tab.load(url)
        try await withTaskCancellationHandler {
            try await tab.waitForLoad()
        } onCancel: {
            Task { @MainActor in tab.stopLoading() }
        }
        if let error = tab.loadError {
            throw BrowserFailure(.navigationFailed, "browser.navigate failed: the site could not be loaded (\(error)). Check the URL and that the server is running.")
        }
    }
}

// MARK: - Bridge host

extension BrowserTabSet: BrowserBridgeHost {
    public func browserInventory() -> BrowserInventory {
        let shared = sharedTabs
        let focused = shared.contains { $0.id == selectedTabID } ? selectedTabID : nil
        return BrowserInventory(tabs: shared.map(\.info), focusedTabID: focused)
    }

    /// Operations that only read the page: allowed while the person has paused the agent on a tab.
    static let readOnlyOperations: Set<String> = [
        "snapshot", "find", "frames", "screenshot", "console", "network.list", "network.get", "files.list", "files.get", "wait",
    ]

    public func perform(_ command: BrowserCommand) async -> BrowserOutcome {
        let operation = command.type
        commandLog.append("\(operation) \(command.tabID.map { String($0.prefix(12)) } ?? "")")
        if commandLog.count > 1_000 { commandLog.removeFirst() }
        if OperationSupport.support(for: operation) == .unsupported { return .failure(OperationSupport.unsupportedFailure(operation)) }
        do {
            return .success(try await run(command))
        } catch let failure as BrowserFailure {
            return .failure(failure)
        } catch is CancellationError {
            return .failure(BrowserFailure(.cancelled, "browser.\(operation) was cancelled; it may have partially run. Inspect the tab before repeating it."))
        } catch {
            return .failure(BrowserFailure(.operationFailed, "browser.\(operation) failed (\(type(of: error))). Inspect the tab with browser.snapshot({tabID}) before retrying."))
        }
    }

    private func run(_ command: BrowserCommand) async throws -> BrowserResult {
        let action = command.action
        switch command.type {
        case "tabs.list":
            return BrowserResult(value: browserInventory().json)
        case "tabs.open":
            let focus = action["focus"]?.boolValue ?? true
            let tab = newTab(select: focus, owner: .agent)
            tab.lastAgentAction = Date()
            workspace?.prepareForAgent(tab)
            if let url = action["url"]?.stringValue, url != "about:blank" {
                try await withActivity(tab, "Opening \(URL(string: url)?.host() ?? "a page")") { try await navigate(tab, to: url) }
            }
            // The server resolves tab IDs from the published inventory: publish before answering.
            await publishAndWait()
            return BrowserResult(value: tab.info.json)
        case "tabs.focus":
            let tab = try requireTab(action)
            select(tab.id)
            await publishAndWait()
            return BrowserResult(value: tab.info.json)
        case "tabs.close":
            let tab = try requireTab(action)
            try checkPaused(tab, operation: "tabs.close")
            close(tab.id, byAgent: true)
            await publishAndWait()
            return BrowserResult(value: browserInventory().json)
        default:
            break
        }

        let tab = try requireTab(action)
        try checkPaused(tab, operation: command.type)
        if command.inspect { return BrowserResult(value: inspect(tab, action)) }
        if let target = command.target, target != inspect(tab, action) {
            throw BrowserFailure(.targetChanged, "The browser target changed while permission was pending. Take a fresh snapshot or listing and request the action again; it was not executed.")
        }
        if let generation = command.generation, generation != tab.generation, !BrowserContract.retainedOperations.contains(command.type) {
            throw BrowserFailure(.documentChanged, "The document changed before this operation ran. Call browser.tabs.list({}) to check its current URL, then browser.snapshot({tabID}) for fresh refs.")
        }
        if let dialog = tab.dialog, !["dialog", "console", "stop", "files.list", "files.get"].contains(command.type) {
            throw BrowserFailure(.dialogOpen, "A JavaScript \(dialog.type) is blocking this tab (WebKit cannot script or capture it until answered): \"\(dialog.message.prefix(200))\". Call browser.dialog({tabID, action: \"accept\"}) or \"dismiss\" first.")
        }
        workspace?.prepareForAgent(tab)
        tab.lastAgentAction = Date()
        return try await withActivity(tab, Self.describe(command)) {
            try await BrowserOperations(set: self, tab: tab, command: command).run()
        }
    }

    private func publishAndWait() async {
        guard let sessionID, let engine = workspace?.engine else { return }
        await engine.browser.publishAndWait(sessionID)
    }

    /// Shows "the agent is doing X" on the tab while `body` runs.
    private func withActivity<T>(_ tab: BrowserTab, _ text: String, _ body: () async throws -> T) async throws -> T {
        tab.agentActivity = text
        tab.changed(.agent)
        defer {
            tab.agentActivity = nil
            tab.lastAgentAction = Date()
            tab.changed(.agent)
        }
        return try await body()
    }

    /// Only shared, non-private tabs of this thread. The server already refuses unpublished tab IDs; this is the
    /// desktop's own check.
    func requireTab(_ action: JSONValue) throws -> BrowserTab {
        guard let id = action["tabID"]?.stringValue, let tab = tab(id) else {
            throw BrowserFailure(.tabUnavailable, "This tab is closed or does not belong to the connected session. Call browser.tabs.list({}) and use an exact returned tabID.")
        }
        guard tab.isShared, !tab.isPrivate else {
            throw BrowserFailure(.notShared, "The user has not shared this tab with you. Use browser.tabs.list({}) for your tabs, or ask the user to share it.")
        }
        return tab
    }

    private func checkPaused(_ tab: BrowserTab, operation: String) throws {
        guard tab.isAgentPaused, !Self.readOnlyOperations.contains(operation) else { return }
        throw BrowserFailure(.userControl, "The user took over this tab, so browser.\(operation) did not run. Reading it (snapshot, screenshot, console) still works. Wait until the user resumes you or ask them; do not open another tab to work around it.")
    }

    /// `Browser.Target` metadata for permission inspection: never page content.
    private func inspect(_ tab: BrowserTab, _ action: JSONValue) -> JSONValue {
        let url = action["type"]?.stringValue == "navigate" ? (action["url"]?.stringValue ?? "") : tab.info.url
        let refs = ["ref", "from", "to"].compactMap { action[$0]?.stringValue }
        return ["resources": [.string(url)], "key": .string(JSONValue.array([.number(Double(tab.generation)), .array(refs.map(JSONValue.string))]).compactText)]
    }

    /// The activity line for a command, without page content (typed text is not shown).
    static func describe(_ command: BrowserCommand) -> String {
        switch command.type {
        case "navigate": "Opening \(URL(string: command.action["url"]?.stringValue ?? "")?.host() ?? "a page")"
        case "click": "Clicking"
        case "hover": "Hovering"
        case "drag": "Dragging"
        case "fill", "fill_form": "Filling in the form"
        case "select": "Choosing an option"
        case "check": "Toggling a checkbox"
        case "press": "Pressing \(command.action["key"]?.stringValue ?? "a key")"
        case "scroll": "Scrolling"
        case "snapshot", "find": "Reading the page"
        case "screenshot": "Taking a screenshot"
        case "evaluate": "Running a script"
        case "wait": "Waiting for the page"
        case "back": "Going back"
        case "forward": "Going forward"
        case "reload": "Reloading"
        case "dialog": "Answering a page dialog"
        case "files.upload", "files.drop": "Uploading a file"
        case "console": "Reading the console"
        default: "Working (\(command.type))"
        }
    }
}

/// The user content controller retains its handlers; this breaks the cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var set: BrowserTabSet?
    init(_ set: BrowserTabSet) { self.set = set }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { set?.receive(message) }
    }
}
