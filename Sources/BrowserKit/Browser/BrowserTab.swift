import AppKit
import OpenCodeKit
import WebKit

/// The WKWebView of a tab. The person's clicks and keys are seen by the workspace's event monitor (synthesized agent
/// events go straight to the view and never pass through the app's event queue), so a person interacting with a tab
/// the agent is driving pauses the agent on that tab (the user always wins).
@MainActor
public final class BrowserWebView: WKWebView {
    weak var tab: BrowserTab?
    private(set) var isDeliveringAgentInput = false
    /// Swallows the context menu an agent's right click would open (a modal tracking loop blocking the main thread).
    var suppressMenusUntil: Date = .distantPast
    /// Extra items for the context menu (set by the pane).
    var contextMenuProvider: ((NSMenu) -> Void)?

    /// Events the agent synthesized (number and timestamp). WebKit re-posts unhandled key equivalents through the
    /// event queue, where the input monitor would otherwise mistake them for the person. Bounded.
    /// (`eventNumber` is only valid for mouse events, so type and timestamp identify an event.)
    private var agentEvents: [(type: UInt, timestamp: TimeInterval)] = []

    func remember(_ event: NSEvent) {
        agentEvents.append((event.type.rawValue, event.timestamp))
        if agentEvents.count > 64 { agentEvents.removeFirst(agentEvents.count - 64) }
    }

    func isAgentEvent(_ event: NSEvent) -> Bool {
        isDeliveringAgentInput || agentEvents.contains { $0.type == event.type.rawValue && $0.timestamp == event.timestamp }
    }

    func deliveringAgentInput<T>(_ body: () throws -> T) rethrows -> T {
        let outer = isDeliveringAgentInput
        isDeliveringAgentInput = true
        defer { isDeliveringAgentInput = outer }
        return try body()
    }

    public override func scrollWheel(with event: NSEvent) {
        // Scrolling to read never pauses the agent; only clicks and typing do.
        super.scrollWheel(with: event)
    }

    public override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        if Date() < suppressMenusUntil {
            DispatchQueue.main.async { menu.cancelTrackingWithoutAnimation() }
            return
        }
        contextMenuProvider?(menu)
    }
}

/// Who opened a tab. Agent-opened tabs are always shared with the thread's agent.
public enum BrowserTabOwner: String, Sendable, Codable {
    case user, agent
}

/// One browser tab: page state for the pane, plus what the agent bridge needs (document generation, frames, element
/// refs, dialog gate, console, captures). Its web view is created on demand and may be suspended (closed, with a
/// snapshot and its back/forward state kept) to bound memory; it is recreated when shown or used.
///
/// Threading: `@MainActor`. The tab's `id` is the server-facing identifier (`tab_<uuid>`), stable across suspension and
/// relaunch (AGENTS.md rule 1).
@MainActor
public final class BrowserTab: NSObject {
    public let id: String
    public internal(set) var owner: BrowserTabOwner
    /// Shared with the thread's agent: published in the bridge inventory and usable by it. Private tabs never are.
    public internal(set) var isShared: Bool
    public let isPrivate: Bool
    weak var set: BrowserTabSet?

    // MARK: Page state (published to the pane)

    public private(set) var url: URL?
    public private(set) var title: String = ""
    public private(set) var favicon: NSImage?
    public private(set) var isLoading = false
    public private(set) var progress: Double = 0
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    public internal(set) var loadError: String?
    /// The web content process crashed; Reload recovers.
    public internal(set) var crashed = false
    public var zoom: Double = 1 { didSet { webView?.pageZoom = zoom } }
    public var appearance: PageAppearance = .system { didSet { applyAppearance() } }
    public var viewport: ViewportPreset? { didSet { applyViewport() } }
    /// The document generation: bumped on every new main-frame document (the agent's refs belong to one generation).
    public private(set) var generation = 0

    // MARK: Web view lifecycle

    public private(set) var webView: BrowserWebView?
    /// What the tab looked like when it was suspended (shown at once when it is displayed again).
    public private(set) var snapshot: NSImage?
    /// WebKit's session state (back/forward list and scroll), kept while suspended and across relaunch.
    var interactionState: Any?
    /// The URL to load when the web view is created (restored or suspended tabs).
    var pendingURL: URL?
    var lastUsed = Date()
    private var observations: [NSKeyValueObservation] = []
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: Agent activity (shown to the person)

    /// What the agent is doing on this tab now ("Clicking “Create account”"), nil when idle.
    public internal(set) var agentActivity: String?
    /// The person interacted while the agent was driving: agent input on this tab is paused until they resume it.
    public internal(set) var isAgentPaused = false
    /// The agent touched this tab recently (the tab strip marks it).
    public internal(set) var lastAgentAction: Date?
    /// Where the agent last clicked, in web view coordinates (the cursor overlay).
    public internal(set) var agentCursor: CGPoint? { didSet { agentCursorAt = agentCursor == nil ? nil : Date() } }
    /// When the cursor was placed: it shows for a few seconds after a pointer action only.
    public private(set) var agentCursorAt: Date?

    // MARK: Prompts waiting for the person (or the agent, for dialogs)

    public struct Dialog {
        public var type: String
        public var message: String
        public var defaultValue: String
        var resolve: (_ accept: Bool, _ text: String?) -> Void
    }
    public internal(set) var dialog: Dialog?

    public struct PermissionPrompt {
        public var origin: String
        public var kinds: String
        var decide: (WKPermissionDecision) -> Void
    }
    public internal(set) var permissionPrompt: PermissionPrompt?

    public struct AuthPrompt {
        public var host: String
        public var realm: String
        public var isProxy: Bool
        var answer: (URLCredential?) -> Void
    }
    public internal(set) var authPrompt: AuthPrompt?

    // MARK: Agent bridge state

    struct Frame {
        var info: WKFrameInfo
        var url: String
        var name: String
        var isMain: Bool
    }
    /// Frames that announced themselves from the isolated world, keyed by the frame's own random ID.
    var frames: [String: Frame] = [:]
    var frameOrder: [String] = []
    var mainFrameID: String? { frameOrder.first { frames[$0]?.isMain == true } }
    /// Element ref → frame ID. Refs are tab-unique and expire on the next snapshot or a new document.
    var refs: [String: String] = [:]
    var refCounter = 0

    struct ConsoleEntry {
        var id: String
        var timestampMs: Double
        var level: String
        var text: String
        var truncated: Bool
        var source: JSONValue?
    }
    var console: [ConsoleEntry] = []
    var consoleDropped = 0
    static let consoleLimit = 500
    /// Screenshots kept for `files.list` / `files.get`. Bounded.
    var captures: [BrowserFile] = []
    static let captureLimit = 20

    init(id: String = BrowserContract.newTabID(), owner: BrowserTabOwner, isShared: Bool, isPrivate: Bool, set: BrowserTabSet) {
        self.id = id
        self.owner = owner
        self.isShared = isShared && !isPrivate
        self.isPrivate = isPrivate
        self.set = set
        super.init()
    }

    /// Restored from a saved record: no web view until shown or used.
    convenience init(record: BrowserTabRecord, set: BrowserTabSet) {
        self.init(id: record.id, owner: record.owner, isShared: record.shared, isPrivate: false, set: set)
        url = record.url.flatMap(URL.init(string:))
        pendingURL = url
        title = record.title
        zoom = record.zoom ?? 1
        appearance = record.appearance ?? .system
        viewport = record.viewport
        interactionState = record.interactionState
    }

    var record: BrowserTabRecord {
        var state: Data?
        if let live = webView?.interactionState as? Data { state = live } else { state = interactionState as? Data }
        // Bounded: very long histories are not worth persisting.
        if let data = state, data.count > 256 * 1024 { state = nil }
        return BrowserTabRecord(
            id: id, url: (url ?? pendingURL)?.absoluteString, title: title, owner: owner, shared: isShared, zoom: zoom == 1 ? nil : zoom,
            appearance: appearance == .system ? nil : appearance, viewport: viewport, interactionState: state)
    }

    public var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = (url ?? pendingURL)?.host() { return host }
        return (url ?? pendingURL) == nil ? "New Tab" : BrowserAddress.display(url ?? pendingURL)
    }

    public var isLive: Bool { webView != nil }

    /// The bridge's view of this tab.
    public var info: BrowserTabInfo {
        // Live values when the web view exists: KVO updates can lag the navigation delegate by a run-loop turn.
        BrowserTabInfo(
            id: id, url: (webView?.url ?? url ?? pendingURL)?.absoluteString ?? "about:blank", title: webView?.title ?? title,
            loading: webView?.isLoading ?? false, loadError: loadError, canGoBack: webView?.canGoBack ?? canGoBack,
            canGoForward: webView?.canGoForward ?? canGoForward, generation: generation)
    }

    // MARK: Web view lifecycle

    /// Creates the web view if needed (restoring a suspended tab's history) and returns it.
    @discardableResult
    func ensureWebView(configuration provided: WKWebViewConfiguration? = nil) -> BrowserWebView {
        if let webView { return webView }
        guard let set else { preconditionFailure("tab without a set") }
        let configuration = provided ?? set.makeConfiguration(isPrivate: isPrivate)
        let webView = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        webView.tab = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = set.workspace?.isWebInspectorEnabled ?? false
        webView.pageZoom = zoom
        webView.setAccessibilityLabel("Web content")
        self.webView = webView
        observe(webView)
        applyAppearance()
        applyViewport()
        set.workspace?.webViewCreated(self)
        if provided == nil {
            if let state = interactionState {
                webView.interactionState = state
                interactionState = nil
            } else if let pendingURL, pendingURL.absoluteString != "about:blank" {
                webView.load(URLRequest(url: pendingURL))
            }
        }
        pendingURL = nil
        return webView
    }

    private func observe(_ webView: BrowserWebView) {
        observations = [
            webView.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.titleChanged(view.title) } },
            webView.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.urlChanged(view.url) } },
            webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.loadingChanged(view.isLoading) } },
            webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.navigationChanged() } },
            webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.navigationChanged() } },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    self?.progress = view.estimatedProgress
                    self?.changed(.progress)
                }
            },
        ]
    }

    /// Closes the web view, keeping a snapshot and its history, to bound memory. Never while the agent or a prompt
    /// needs it.
    func suspend() async {
        guard let webView, agentActivity == nil, dialog == nil, permissionPrompt == nil, authPrompt == nil else { return }
        if webView.window != nil, webView.bounds.width > 0 {
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = false
            snapshot = try? await webView.takeSnapshot(configuration: configuration)
        }
        guard self.webView === webView, agentActivity == nil else { return }
        interactionState = webView.interactionState
        pendingURL = url
        tearDownWebView()
        changed(.lifecycle)
    }

    private func tearDownWebView() {
        guard let webView else { return }
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.tab = nil
        webView.removeFromSuperview()
        self.webView = nil
        isLoading = false
        resumeLoadWaiters()
        frames.removeAll()
        frameOrder.removeAll()
        refs.removeAll()
    }

    /// Closing the tab: answers pending prompts negatively and releases the web view.
    func close() {
        dialog?.resolve(false, nil)
        dialog = nil
        permissionPrompt?.decide(.deny)
        permissionPrompt = nil
        authPrompt?.answer(nil)
        authPrompt = nil
        tearDownWebView()
    }

    /// The first paint after resuming replaces the snapshot.
    func dropSnapshot() {
        guard snapshot != nil else { return }
        snapshot = nil
        changed(.lifecycle)
    }

    // MARK: User actions

    public func load(_ url: URL) {
        loadError = nil
        crashed = false
        let webView = ensureWebView()
        webView.load(URLRequest(url: url))
        self.url = url
        changed(.page)
    }

    public func goBack() { ensureWebView().goBack() }
    public func goForward() { ensureWebView().goForward() }

    public func reload(fromOrigin: Bool = false) {
        crashed = false
        loadError = nil
        let webView = ensureWebView()
        if webView.url == nil, let url = url ?? pendingURL {
            webView.load(URLRequest(url: url))
        } else if fromOrigin {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
    }

    public func stopLoading() { webView?.stopLoading() }

    /// The person interacted with the page. If the agent is driving this tab, it pauses here (Resume continues).
    func userInteracted() {
        guard isShared, let set else { return }
        let recentlyDriven = agentActivity != nil || (lastAgentAction.map { Date().timeIntervalSince($0) < 8 } ?? false)
        guard recentlyDriven, !isAgentPaused else { return }
        isAgentPaused = true
        set.agentPaused(self)
        changed(.agent)
    }

    // MARK: Appearance and viewport

    private func applyAppearance() {
        webView?.appearance = appearance.nsAppearance
    }

    private func applyViewport() {
        guard let webView else { return }
        let mobile = viewport?.isMobile ?? false
        let agent = mobile ? ViewportPreset.mobileUserAgent : nil
        if webView.customUserAgent != agent {
            webView.customUserAgent = agent
            if webView.url != nil { webView.reload() }
        }
        changed(.viewport)
    }

    // MARK: Change notifications

    enum Change { case page, progress, lifecycle, agent, prompt, viewport }

    func changed(_ change: Change) { set?.tabChanged(self, change) }

    private func titleChanged(_ value: String?) {
        title = value ?? ""
        changed(.page)
    }

    private func urlChanged(_ value: URL?) {
        if let value { url = value }
        changed(.page)
    }

    private func loadingChanged(_ value: Bool) {
        isLoading = value
        if !value { resumeLoadWaiters() }
        changed(.page)
    }

    private func navigationChanged() {
        canGoBack = webView?.canGoBack ?? false
        canGoForward = webView?.canGoForward ?? false
        changed(.page)
    }

    // MARK: Messages from injected scripts (routed by the set, which owns the user content controller)

    func receiveFrame(_ body: JSONValue, info: WKFrameInfo) {
        guard let frameID = body["frameId"]?.stringValue else { return }
        if frames[frameID] == nil { frameOrder.append(frameID) }
        frames[frameID] = Frame(info: info, url: body["url"]?.stringValue ?? info.request.url?.absoluteString ?? "", name: body["name"]?.stringValue ?? "", isMain: info.isMainFrame)
        while frameOrder.count > 64, let victim = frameOrder.first(where: { frames[$0]?.isMain == false }) {
            frames[victim] = nil
            frameOrder.removeAll { $0 == victim }
        }
    }

    func receiveConsole(_ body: JSONValue) {
        let text = body["text"]?.stringValue ?? ""
        let entry = ConsoleEntry(
            id: "log_\(UUID().uuidString.lowercased().prefix(8))", timestampMs: Date().timeIntervalSince1970 * 1000,
            level: body["level"]?.stringValue ?? "info", text: String(text.prefix(BrowserContract.maxText)),
            truncated: text.count > BrowserContract.maxText, source: body["source"].flatMap { $0.isNull ? nil : $0 })
        console.append(entry)
        if console.count > Self.consoleLimit {
            console.removeFirst(console.count - Self.consoleLimit)
            consoleDropped += 1
        }
    }

    // MARK: JavaScript

    var agentWorld: WKContentWorld { WKContentWorld.world(name: AgentScript.worldName) }

    /// Calls `window.__bc.call(name, input)` in the isolated world of a frame and decodes its JSON result.
    func agent(_ name: String, _ input: JSONValue = [:], frame: WKFrameInfo? = nil, timeout: Duration = .seconds(30)) async throws -> JSONValue {
        let body = AgentScript.source + "\nreturn JSON.stringify((await window.__bc.call(\(jsString(name)), JSON.parse(input))) ?? null);"
        let raw = try await callJS(body, arguments: ["input": input.compactText], frame: frame, world: agentWorld, timeout: timeout)
        return try await Self.decode(raw)
    }

    /// `callAsyncJavaScript` with a deadline and cancellation: WebKit's own call cannot be cancelled and never returns
    /// while a dialog blocks the page, so the continuation is resumed by whichever comes first.
    func callJS(
        _ body: String, arguments: [String: Any] = [:], frame: WKFrameInfo?, world: WKContentWorld, timeout: Duration = .seconds(30),
        program: Bool = false
    ) async throws -> JSONValue {
        guard let webView else { throw BrowserFailure(.tabUnavailable, "The tab is not loaded. Call browser.tabs.focus({tabID}) and retry.") }
        let once = OnceContinuation()
        let hadDialog = dialog != nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, any Error>) in
                once.set(continuation)
                let completion: @MainActor @Sendable (Result<Any, any Error>) -> Void = { result in
                    switch result {
                    case .success(let value): once.resume(returning: JSONValue(foundation: value))
                    case .failure(let error): once.resume(throwing: Self.scriptFailure(error))
                    }
                }
                if program {
                    webView.evaluateJavaScript(body, in: frame, in: world, completionHandler: completion)
                } else {
                    webView.callAsyncJavaScript(body, arguments: arguments, in: frame, in: world, completionHandler: completion)
                }
                Task { @MainActor [weak self] in
                    let deadline = ContinuousClock.now + timeout
                    while ContinuousClock.now < deadline, !once.finished {
                        if !hadDialog, let dialog = self?.dialog {
                            once.resume(throwing: DialogInterrupted(type: dialog.type, message: dialog.message))
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                    once.resume(throwing: BrowserFailure(.timeout, "The page did not answer within \(timeout.components.seconds) s. It may be busy; call browser.dialog({tabID, action: \"get\"}) or inspect the tab."))
                }
            }
        } onCancel: {
            Task { @MainActor in once.resume(throwing: CancellationError()) }
        }
    }

    @concurrent
    static func decode(_ raw: JSONValue) async throws -> JSONValue {
        guard let text = raw.stringValue else { return .null }
        return try JSONValue.parse(Data(text.utf8))
    }

    static func scriptFailure(_ error: any Error) -> BrowserFailure {
        let nsError = error as NSError
        let message = (nsError.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? nsError.localizedDescription
        for code in ["stale_ref", "not_editable", "not_select", "option_missing", "not_multiple", "not_file_input", "not_checkable"] where message.contains(code) {
            let detail = message.components(separatedBy: "\(code): ").last ?? message
            let hint = code == "stale_ref" ? " Call browser.snapshot({tabID}) and use a fresh ref from this tab." : ""
            return BrowserFailure(.init(rawValue: code), detail + hint)
        }
        return BrowserFailure(.scriptError, "Page JavaScript failed: \(message.prefix(800))")
    }

    // MARK: Loading

    /// Waits until the tab is idle (or a dialog blocks it). Resumed by the navigation delegate; `timeout` bounds it.
    func waitForLoad(timeout: Duration = .seconds(30)) async throws {
        try await Task.sleep(for: .milliseconds(30))
        let deadline = ContinuousClock.now + timeout
        while webView?.isLoading == true {
            try Task.checkCancellation()
            if dialog != nil || authPrompt != nil { return }
            if ContinuousClock.now > deadline {
                throw BrowserFailure(.timeout, "The page is still loading after \(timeout.components.seconds) s. Call browser.stop({tabID}) or inspect it.")
            }
            // Woken by `loadingChanged`; the short timer re-checks dialogs and the deadline.
            await withCheckedContinuation { continuation in
                loadWaiters.append(continuation)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(100))
                    self?.resumeLoadWaiters()
                }
            }
        }
    }

    /// After recreating a suspended web view: waits until it has a document and finished loading (bounded).
    func waitForRestore(timeout: Duration = .seconds(15)) async throws {
        let deadline = ContinuousClock.now + timeout
        while let webView, webView.url == nil || webView.isLoading, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func resumeLoadWaiters() {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Favicon

    private func refreshFavicon() {
        guard let webView, url?.scheme?.hasPrefix("http") == true else { return }
        Task { [weak self] in
            guard let self, let href = try? await self.agent("favicon", [:], timeout: .seconds(3)).stringValue,
                  let iconURL = URL(string: href) else { return }
            let image = await BrowserFavicons.shared.image(for: iconURL)
            guard self.webView === webView else { return }
            self.favicon = image
            self.changed(.page)
        }
    }
}

// MARK: - Navigation and UI delegates

extension BrowserTab: WKNavigationDelegate, WKUIDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        if let url = navigationAction.request.url, !BrowserAddress.isWebScheme(url), url.scheme?.lowercased() != "file" {
            // mailto:, tel:, custom schemes: hand to the system, only for the person's own clicks.
            if navigationAction.navigationType == .linkActivated, webView === self.webView, !(self.webView?.isDeliveringAgentInput ?? true) {
                NSWorkspace.shared.open(url)
            }
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if !navigationResponse.canShowMIMEType { return .download }
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"), disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        set?.workspace?.downloads.track(download, tabID: id)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        set?.workspace?.downloads.track(download, tabID: id)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadError = nil
        crashed = false
        changed(.page)
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new main-frame document: refs, frames and console belong to the old one.
        generation += 1
        refs.removeAll()
        frames.removeAll()
        frameOrder.removeAll()
        console.removeAll()
        consoleDropped = 0
        favicon = nil
        agentCursor = nil
        dropSnapshot()
        changed(.page)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url, !isPrivate { set?.workspace?.recordVisit(url, title: webView.title ?? "") }
        refreshFavicon()
        changed(.page)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { record(error) }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        record(error)
    }

    private func record(_ error: any Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        // "Frame load interrupted" when a navigation became a download.
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        loadError = nsError.localizedDescription
        dropSnapshot()
        changed(.page)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        crashed = true
        isLoading = false
        loadError = "The page stopped working."
        refs.removeAll()
        frames.removeAll()
        frameOrder.removeAll()
        changed(.page)
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // window.open and target=_blank become a tab of the same thread, owned like the opener.
        set?.openPopup(from: self, configuration: configuration)?.webView
    }

    public func webViewDidClose(_ webView: WKWebView) { set?.close(id, byAgent: false) }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        _ = await present(type: "alert", message: message, defaultValue: "")
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await present(type: "confirm", message: message, defaultValue: "").accept
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let answer = await present(type: "prompt", message: prompt, defaultValue: defaultText ?? "")
        return answer.accept ? (answer.text ?? defaultText ?? "") : nil
    }

    /// The page stays blocked until the agent (`browser.dialog`) or the person (the dialog banner) answers.
    private func present(type: String, message: String, defaultValue: String) async -> (accept: Bool, text: String?) {
        dialog?.resolve(false, nil)
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, String?), Never>) in
            dialog = Dialog(type: type, message: String(message.prefix(4_000)), defaultValue: defaultValue) { accept, text in
                continuation.resume(returning: (accept, text))
            }
            changed(.prompt)
        }
        dialog = nil
        changed(.prompt)
        return answer
    }

    /// The person's or the agent's answer to the page's JavaScript dialog.
    public func answerDialog(accept: Bool, text: String? = nil) {
        guard let dialog else { return }
        self.dialog = nil
        dialog.resolve(accept, text)
        changed(.prompt)
    }

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        // The person chooses files; the agent uploads through browser.files.upload instead.
        guard let window = webView.window, !(self.webView?.isDeliveringAgentInput ?? false) else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.message = "Choose files for \(url?.host() ?? "the page")"
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.urls : nil
    }

    public func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        let host = origin.port > 0 ? "\(origin.host):\(origin.port)" : origin.host
        let kinds = switch type {
        case .camera: "camera"
        case .microphone: "microphone"
        case .cameraAndMicrophone: "camera and microphone"
        @unknown default: "media devices"
        }
        if let remembered = set?.workspace?.permissionDecision(origin: host, kinds: kinds) { return remembered }
        permissionPrompt?.decide(.deny)
        // Denied unless the person allows it in the banner; unanswered prompts are denied after 60 s.
        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<WKPermissionDecision, Never>) in
            let once = OnceFlag()
            permissionPrompt = PermissionPrompt(origin: host, kinds: kinds) { decision in
                if once.claim() { continuation.resume(returning: decision) }
            }
            changed(.prompt)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(60))
                if once.claim() { continuation.resume(returning: .deny) }
                self?.clearPermissionPrompt()
            }
        }
        clearPermissionPrompt()
        return decision
    }

    private func clearPermissionPrompt() {
        guard permissionPrompt != nil else { return }
        permissionPrompt = nil
        changed(.prompt)
    }

    /// The person's answer in the permission banner. `remember` keeps it for this site while BelloCode runs.
    public func answerPermission(allow: Bool, remember: Bool) {
        guard let prompt = permissionPrompt else { return }
        if remember { set?.workspace?.rememberPermission(origin: prompt.origin, kinds: prompt.kinds, allow: allow) }
        permissionPrompt = nil
        prompt.decide(allow ? .grant : .deny)
        changed(.prompt)
    }

    public func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust, CanonicalPreviewProxy.isCanonical(challenge.protectionSpace.host) {
            // Canonical project names (shared browser): only BelloCode's egress CA is trusted for `*.bc`.
            return CanonicalPreviewProxy.trust(challenge).map { (.useCredential, $0) } ?? (.cancelAuthenticationChallenge, nil)
        }
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM].contains(method) else {
            return (.performDefaultHandling, nil)
        }
        if challenge.previousFailureCount > 2 { return (.cancelAuthenticationChallenge, nil) }
        authPrompt?.answer(nil)
        // Credentials go straight to WebKit for this challenge; they are never stored or logged by BelloCode.
        let credential = await withCheckedContinuation { (continuation: CheckedContinuation<URLCredential?, Never>) in
            authPrompt = AuthPrompt(
                host: challenge.protectionSpace.host, realm: challenge.protectionSpace.realm ?? "", isProxy: challenge.protectionSpace.isProxy()
            ) { credential in continuation.resume(returning: credential) }
            changed(.prompt)
        }
        authPrompt = nil
        changed(.prompt)
        return credential.map { (.useCredential, $0) } ?? (.cancelAuthenticationChallenge, nil)
    }

    /// The person's answer in the sign-in banner (nil cancels).
    public func answerAuth(user: String?, password: String?) {
        guard let prompt = authPrompt else { return }
        authPrompt = nil
        if let user, let password {
            prompt.answer(URLCredential(user: user, password: password, persistence: .forSession))
        } else {
            prompt.answer(nil)
        }
    }
}

/// Resumes a continuation at most once, whichever of completion, timeout or cancellation wins.
@MainActor
final class OnceContinuation {
    private var continuation: CheckedContinuation<JSONValue, any Error>?
    private var early: Result<JSONValue, any Error>?
    private(set) var finished = false

    func set(_ continuation: CheckedContinuation<JSONValue, any Error>) {
        if let early {
            self.early = nil
            continuation.resume(with: early)
        } else {
            self.continuation = continuation
        }
    }

    func resume(returning value: JSONValue) { finish(.success(value)) }
    func resume(throwing error: any Error) { finish(.failure(error)) }

    private func finish(_ result: Result<JSONValue, any Error>) {
        if finished { return }
        finished = true
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else if early == nil {
            early = result
        }
    }
}

@MainActor
final class OnceFlag {
    private var done = false
    func claim() -> Bool {
        defer { done = true }
        return !done
    }
}

func jsString(_ value: String) -> String { JSONValue.string(value).compactText }

/// A script call was cut short because the page opened a JavaScript dialog. The action itself ran.
struct DialogInterrupted: Error {
    var type: String
    var message: String
}

/// A bounded cache of site icons, fetched without cookies.
@MainActor
final class BrowserFavicons {
    static let shared = BrowserFavicons()
    private var cache: [String: NSImage] = [:]
    private var order: [String] = []
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }()

    func image(for url: URL) async -> NSImage? {
        let key = url.absoluteString
        if let cached = cache[key] { return cached }
        let data: Data
        if url.scheme == "data" {
            guard let decoded = try? Data(contentsOf: url) else { return nil }
            data = decoded
        } else {
            guard let (fetched, response) = try? await session.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200,
                  fetched.count < 512 * 1024 else { return nil }
            data = fetched
        }
        guard let image = NSImage(data: data), image.isValid else { return nil }
        image.size = NSSize(width: 16, height: 16)
        cache[key] = image
        order.append(key)
        if order.count > 200 { cache[order.removeFirst()] = nil }
        return image
    }
}
