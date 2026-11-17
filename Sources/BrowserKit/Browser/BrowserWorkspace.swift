import AppKit
import BelloCore
import Engine
import OpenCodeKit
import WebKit
import os

/// The app's built-in browser: one tab set per thread, the website data profiles, downloads, history and the bounded
/// pool of live web views. Bridges each thread's set to its opencode session through `Engine.browser`.
///
/// - Switching threads swaps sets instantly: live web views stay alive (at most `liveLimit` across all threads); the
///   rest are suspended to a snapshot plus WebKit's session state and recreated when shown or used.
/// - A tab the agent uses while it is not on screen lives in an off-screen parking window, so native input and
///   screenshots keep working.
/// - Sets, tab URLs and history persist as app preferences in the projection store (no schema change), bounded.
///
/// Threading and ownership: `@MainActor`; one per app (the window's browser surface uses it). `close()` saves and
/// releases everything.
@MainActor
public final class BrowserWorkspace {
    public static let liveLimit = 8
    public static let savedSetLimit = 200
    static let setKeyPrefix = "browser.set."
    static let indexKey = "browser.sets"
    static let historyKey = "browser.history"

    public let engine: Engine?
    let store: ProjectionStore?
    let profiles: BrowserProfiles
    public let downloads: BrowserDownloads
    public private(set) var history = BrowserHistory()
    public var searchTemplate = BrowserAddress.defaultSearchTemplate
    private var sets: [String: BrowserTabSet] = [:]
    private var setIndex: [String] = []
    private var pendingSaves: Set<String> = []
    private var saveTask: Task<Void, Never>?
    private var historySaveTask: Task<Void, Never>?
    private var budgetTask: Task<Void, Never>?
    private var permissionDecisions: [String: Bool] = [:]
    private let log = Logger(subsystem: "app.bellocode.BrowserKit", category: "Workspace")
    private let signposter = OSSignposter(subsystem: "app.bellocode.BrowserKit", category: "Workspace")
    /// Holds live web views that are not on screen (agent work in another thread's tabs).
    let parking: NSWindow
    /// The set the window shows now (its selected tab is never suspended).
    public private(set) var displayedKey: String?
    /// Dev-server URLs offered to a thread (the pane shows "Open"), newest first.
    public private(set) var offers: [String: URL] = [:]

    /// Opens the browser panel for a set (a link was opened, the agent opened a tab in the displayed thread).
    public var onRequestShow: ((BrowserTabSet) -> Void)?
    /// The person picked an element and wrote a note: insert it into the thread's composer.
    public var onPick: ((BrowserPick, BrowserTabSet) -> Void)?
    /// Anything the pane shows changed for a set (offers, inspector, history).
    var onWorkspaceChange: (() -> Void)?

    public var isWebInspectorEnabled = false {
        didSet {
            for set in sets.values { for tab in set.tabs { tab.webView?.isInspectable = isWebInspectorEnabled } }
            onWorkspaceChange?()
        }
    }

    /// - Parameters:
    ///   - engine: the bridge and persistence; nil for a standalone browser (demo harness).
    ///   - isolatedProfiles: ephemeral website data only (tests and the demo never touch real profiles).
    public init(engine: Engine?, isolatedProfiles: Bool = false, downloadsFolder: URL? = nil) {
        self.engine = engine
        store = engine?.store
        profiles = BrowserProfiles(isolated: isolatedProfiles)
        downloads = BrowserDownloads(folder: downloadsFolder)
        parking = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1_100, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        parking.isReleasedWhenClosed = false
        parking.ignoresMouseEvents = true
        parking.title = "BelloCode browser (background tabs)"
        parking.isExcludedFromWindowsMenu = true
        parking.contentView = NSView(frame: parking.contentRect(forFrameRect: parking.frame))
        loadHistory()
        installInputMonitor()
    }

    private var inputMonitor: Any?

    /// Real clicks and keystrokes in a web view (the agent's synthesized events never reach the app's event queue).
    private func installInputMonitor() {
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            MainActor.assumeIsolated {
                var view: NSView?
                if event.type == .keyDown {
                    view = event.window?.firstResponder as? NSView
                } else if let content = event.window?.contentView {
                    view = content.hitTest(content.convert(event.locationInWindow, from: nil))
                }
                while let current = view, !(current is BrowserWebView) { view = current.superview }
                if let webView = view as? BrowserWebView, !webView.isAgentEvent(event) { webView.tab?.userInteracted() }
            }
            return event
        }
    }

    /// Saves and releases every set (window or app closing). Attachments end; PTYs and pages are not involved.
    public func close() async {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        await flushSaves()
        await flushHistory()
        for set in sets.values {
            if let sessionID = set.sessionID { engine?.browser.unbindKeepingGuidance(sessionID) }
            set.shutdown()
        }
        sets.removeAll()
        parking.orderOut(nil)
    }

    // MARK: Sets

    public static func key(for sessionID: SessionID) -> String { sessionID.rawValue }

    /// A thread's browser set, created (and restored from disk) on first use, and attached to the agent.
    public func set(for sessionID: SessionID, projectDirectory: String) -> BrowserTabSet {
        let key = Self.key(for: sessionID)
        if let existing = sets[key] {
            bind(existing)
            return existing
        }
        let set = BrowserTabSet(key: key, sessionID: sessionID, projectDirectory: projectDirectory, workspace: self)
        sets[key] = set
        loadRecord(into: set)
        bind(set)
        return set
    }

    /// A browser set without an agent (the demo harness, or tests).
    public func standaloneSet(key: String, projectDirectory: String) -> BrowserTabSet {
        if let existing = sets[key] { return existing }
        let set = BrowserTabSet(key: key, sessionID: nil, projectDirectory: projectDirectory, workspace: self)
        sets[key] = set
        set.markLoaded()
        return set
    }

    public func existingSet(for sessionID: SessionID) -> BrowserTabSet? { sets[Self.key(for: sessionID)] }

    /// The window now shows this set (nil: none). Keeps its selected tab live and marks it recently used.
    public func display(_ set: BrowserTabSet?) {
        displayedKey = set?.key
        if let set {
            set.selectedTab?.lastUsed = Date()
            bind(set)
        }
        enforceLiveBudget()
    }

    /// The thread was deleted: drop its set and saved state.
    public func forget(_ sessionID: SessionID) {
        let key = Self.key(for: sessionID)
        engine?.browser.unbind(sessionID)
        sets.removeValue(forKey: key)?.shutdown()
        setIndex.removeAll { $0 == key }
        guard let store else { return }
        Task { try? await store.setPreference(Self.setKeyPrefix + key, BrowserSetRecord?.none) }
    }

    private func bind(_ set: BrowserTabSet) {
        guard let sessionID = set.sessionID, let engine else { return }
        engine.browser.bind(sessionID, directory: set.projectDirectory, host: set, guidance: OperationSupport.guidance)
    }

    func publishBridge(_ set: BrowserTabSet) {
        guard let sessionID = set.sessionID else { return }
        engine?.browser.publish(sessionID)
    }

    /// Opens a URL in a thread's browser (terminal links, dev-server offers) and asks the window to show it.
    @discardableResult
    public func open(_ url: URL, in sessionID: SessionID, projectDirectory: String, shared: Bool = false) -> BrowserTab {
        let set = self.set(for: sessionID, projectDirectory: projectDirectory)
        if let existing = set.tabs.first(where: { $0.url == url || $0.info.url == url.absoluteString }) {
            set.select(existing.id)
            onRequestShow?(set)
            return existing
        }
        let tab = set.newTab(url: url, shared: shared)
        onRequestShow?(set)
        return tab
    }

    // MARK: Dev-server offers

    /// Offers a dev-server URL to a thread (from terminal output or agent output). Never opens anything by itself, and
    /// never re-offers a URL already open or dismissed.
    public func offerDevServer(_ url: URL, for sessionID: SessionID) {
        let key = Self.key(for: sessionID)
        if dismissedOffers.contains("\(key) \(url.absoluteString)") { return }
        if let set = sets[key], set.tabs.contains(where: { $0.url?.host() == url.host() && $0.url?.port == url.port }) { return }
        guard offers[key] != url else { return }
        offers[key] = url
        if offers.count > 100, let oldest = offers.keys.first(where: { $0 != key }) { offers[oldest] = nil }
        onWorkspaceChange?()
    }

    private var dismissedOffers: Set<String> = []

    public func dismissOffer(for sessionID: SessionID) {
        let key = Self.key(for: sessionID)
        if let url = offers.removeValue(forKey: key) {
            dismissedOffers.insert("\(key) \(url.absoluteString)")
            if dismissedOffers.count > 500 { dismissedOffers.removeFirst() }
        }
        onWorkspaceChange?()
    }

    public func acceptOffer(for sessionID: SessionID, projectDirectory: String) {
        let key = Self.key(for: sessionID)
        guard let url = offers.removeValue(forKey: key) else { return }
        dismissedOffers.insert("\(key) \(url.absoluteString)")
        open(url, in: sessionID, projectDirectory: projectDirectory)
        onWorkspaceChange?()
    }

    // MARK: Live web view budget

    func webViewCreated(_ tab: BrowserTab) {
        tab.webView?.isInspectable = isWebInspectorEnabled
        scheduleBudget()
    }

    /// Makes the tab's web view live and on a window, so agent input and screenshots work when it is not on screen.
    func prepareForAgent(_ tab: BrowserTab) {
        let webView = tab.ensureWebView()
        tab.lastUsed = Date()
        guard webView.window == nil else { return }
        park(webView, viewport: tab.viewport)
    }

    func park(_ webView: BrowserWebView, viewport: ViewportPreset?) {
        guard let content = parking.contentView else { return }
        let size = viewport.map { NSSize(width: $0.width, height: $0.height) } ?? lastPaneSize
        webView.removeFromSuperview()
        webView.frame = NSRect(origin: .zero, size: size)
        webView.autoresizingMask = []
        if parking.frame.size.width < size.width || parking.frame.size.height < size.height {
            parking.setContentSize(NSSize(width: max(size.width, 1_100), height: max(size.height, 800)))
        }
        content.addSubview(webView)
        if !parking.isVisible { parking.orderBack(nil) }
    }

    /// The pane's content size, used for parked web views so pages lay out as they would on screen.
    var lastPaneSize = NSSize(width: 1_000, height: 760)

    func scheduleBudget() {
        guard budgetTask == nil else { return }
        budgetTask = Task { [weak self] in
            await Task.yield()
            self?.budgetTask = nil
            self?.enforceLiveBudget()
        }
    }

    /// Suspends the least recently used live tabs beyond `liveLimit`. Never the displayed tab, a tab the agent is
    /// using (or used in the last 30 s), a tab with a prompt or one in inspect mode.
    func enforceLiveBudget() {
        let displayedTabID = displayedKey.flatMap { sets[$0]?.selectedTabID }
        let live = sets.values.flatMap { set in set.tabs.filter(\.isLive).map { (set, $0) } }
        guard live.count > Self.liveLimit else { return }
        let now = Date()
        let candidates = live.filter { set, tab in
            tab.id != displayedTabID && tab.agentActivity == nil && tab.dialog == nil && tab.permissionPrompt == nil
                && tab.authPrompt == nil && set.pickingTabID != tab.id
                && (tab.lastAgentAction.map { now.timeIntervalSince($0) > 30 } ?? true)
        }.sorted { $0.1.lastUsed < $1.1.lastUsed }
        for (_, tab) in candidates.prefix(live.count - Self.liveLimit) {
            Task { await tab.suspend() }
        }
    }

    public var liveWebViewCount: Int { sets.values.reduce(0) { $0 + $1.tabs.filter(\.isLive).count } }

    // MARK: Permissions (camera and microphone; per site while the app runs)

    func permissionDecision(origin: String, kinds: String) -> WKPermissionDecision? {
        permissionDecisions["\(origin) \(kinds)"].map { $0 ? .grant : .deny }
    }

    func rememberPermission(origin: String, kinds: String, allow: Bool) {
        permissionDecisions["\(origin) \(kinds)"] = allow
    }

    // MARK: Site data

    /// Clears cookies, storage and caches for a project's profile.
    public func clearSiteData(projectDirectory: String) async {
        await profiles.clearSiteData(forProject: projectDirectory)
    }

    // MARK: Picks

    func picked(_ pick: BrowserPick, in set: BrowserTabSet) {
        pendingPick = (pick, set.key)
        onWorkspaceChange?()
    }

    /// A pick waiting for the person's note (the pane shows the annotation bar).
    public private(set) var pendingPick: (pick: BrowserPick, setKey: String)?

    /// Sends the pending pick with a note to the composer (through `onPick`).
    public func commitPick(note: String) {
        guard var pending = pendingPick, let set = sets[pending.setKey] else { return }
        pendingPick = nil
        pending.pick.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        onPick?(pending.pick, set)
        onWorkspaceChange?()
    }

    public func discardPick() {
        pendingPick = nil
        onWorkspaceChange?()
    }

    // MARK: History

    func recordVisit(_ url: URL, title: String) {
        history.record(url, title: title)
        scheduleHistorySave()
    }

    public func clearHistory() {
        history.clear()
        scheduleHistorySave()
    }

    private func loadHistory() {
        guard let store else { return }
        Task { [weak self] in
            let saved = try? await store.preference(Self.historyKey, as: BrowserHistory.self)
            guard let self, let saved, self.history.entries.isEmpty else { return }
            self.history = saved
        }
    }

    private func scheduleHistorySave() {
        guard store != nil, historySaveTask == nil else { return }
        historySaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.flushHistory()
        }
    }

    private func flushHistory() async {
        historySaveTask = nil
        guard let store else { return }
        try? await store.setPreference(Self.historyKey, history)
    }

    // MARK: Persistence

    private func loadRecord(into set: BrowserTabSet) {
        guard let store else {
            set.markLoaded()
            return
        }
        let key = set.key
        let interval = signposter.beginInterval("load set")
        Task { [weak self, weak set] in
            let record = try? await store.preference(Self.setKeyPrefix + key, as: BrowserSetRecord.self)
            if let self, self.setIndex.isEmpty {
                self.setIndex = (try? await store.preference(Self.indexKey, as: [String].self)) ?? []
            }
            self?.signposter.endInterval("load set", interval)
            guard let set else { return }
            if let record { set.restore(record) } else { set.markLoaded() }
        }
    }

    func setChanged(_ set: BrowserTabSet) {
        guard store != nil, set.sessionID != nil, set.isLoaded else { return }
        pendingSaves.insert(set.key)
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            await self?.flushSaves()
        }
    }

    /// Writes every pending set (and the bounded index of saved sets).
    public func flushSaves() async {
        saveTask = nil
        guard let store, !pendingSaves.isEmpty else { return }
        let keys = pendingSaves
        pendingSaves.removeAll()
        for key in keys {
            guard let set = sets[key] else { continue }
            setIndex.removeAll { $0 == key }
            setIndex.insert(key, at: 0)
            try? await store.setPreference(Self.setKeyPrefix + key, set.record)
        }
        let dropped = setIndex.count > Self.savedSetLimit ? Array(setIndex[Self.savedSetLimit...]) : []
        setIndex = Array(setIndex.prefix(Self.savedSetLimit))
        for key in dropped { try? await store.setPreference(Self.setKeyPrefix + key, BrowserSetRecord?.none) }
        try? await store.setPreference(Self.indexKey, setIndex)
    }
}
