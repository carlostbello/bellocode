// SPIKE (gate G3). The desktop side of `experimental.browser` for one session: owns the tabs (visible WKWebViews),
// publishes their state and executes commands. Everything here is @MainActor; the bridge connection does the I/O.

import AppKit
import WebKit

@MainActor
public final class BrowserHost: NSObject {
    public enum InputMode: String, Sendable {
        /// Synthesized NSEvents delivered to the WKWebView: `isTrusted` input, falls back to script when impossible.
        case native
        /// DOM events dispatched from the isolated world: `isTrusted == false`.
        case script
    }

    public let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760))
    let agentWorld = WKContentWorld.world(name: AgentScript.worldName)
    private let userContent = WKUserContentController()
    private let dataStore = WKWebsiteDataStore.nonPersistent()
    public private(set) var tabs: [WebTab] = []
    public private(set) var focusedTabID: String?
    public var inputMode: InputMode = .native

    /// Sends the state to the server and returns once it acknowledged (set by the bridge connection).
    public var statePublisher: (@Sendable (BrowserState) async -> Void)?
    /// What the person sees about agent activity (the window's status line).
    public var onActivity: ((String) -> Void)?
    /// Tab strip, address and dialog banner refresh.
    public var onChange: (() -> Void)?
    /// One line per command, for the end-to-end record. Bounded.
    public private(set) var commandLog: [String] = []
    /// How each pointer/typing operation was delivered: "native" or "script (<reason>)". Bounded.
    public private(set) var deliveryLog: [String] = []

    /// The most recent screenshot bytes, for the spike's own PNG evidence.
    public var lastScreenshot: Data?

    private let highlight = HighlightView()
    private var publishTask: Task<Void, Never>?
    private var highlightTask: Task<Void, Never>?

    public override init() {
        super.init()
        contentView.wantsLayer = true
        let agentScript = WKUserScript(source: AgentScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: agentWorld)
        let consoleScript = WKUserScript(source: AgentScript.consoleSource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        userContent.addUserScript(agentScript)
        userContent.addUserScript(consoleScript)
        userContent.add(WeakMessageHandler(self), contentWorld: agentWorld, name: AgentScript.agentHandler)
        userContent.add(WeakMessageHandler(self), contentWorld: .page, name: AgentScript.consoleHandler)
    }

    public func shutdown() {
        publishTask?.cancel()
        highlightTask?.cancel()
        for tab in tabs { tab.close() }
        tabs.removeAll()
        focusedTabID = nil
        userContent.removeAllScriptMessageHandlers()
    }

    public var state: BrowserState { BrowserState(tabs: tabs.map(\.state), focusedTabID: focusedTabID) }
    public var focusedTab: WebTab? { tabs.first { $0.id == focusedTabID } }
    public func tab(_ id: String) -> WebTab? { tabs.first { $0.id == id } }

    // MARK: Tabs

    @discardableResult
    public func openTab(configuration: WKWebViewConfiguration? = nil, focus: Bool) -> WebTab {
        let configuration = configuration ?? makeConfiguration()
        let tab = WebTab(id: BrowserContract.newTabID(), configuration: configuration, host: self)
        tabs.append(tab)
        if focus || focusedTabID == nil { self.focus(tab.id) }
        schedulePublish()
        return tab
    }

    private func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContent
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    public func focus(_ id: String) {
        guard let tab = tab(id) else { return }
        focusedTab?.webView.removeFromSuperview()
        focusedTabID = id
        tab.webView.frame = contentView.bounds
        tab.webView.autoresizingMask = [.width, .height]
        contentView.addSubview(tab.webView, positioned: .below, relativeTo: nil)
        highlight.removeFromSuperview()
        contentView.addSubview(highlight)
        highlight.isHidden = true
        schedulePublish()
        onChange?()
    }

    public func closeTab(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        tab.close()
        if focusedTabID == id {
            focusedTabID = nil
            if let next = tabs[safe: min(index, tabs.count - 1)] { focus(next.id) }
        }
        schedulePublish()
        onChange?()
    }

    func tabChanged(_ tab: WebTab) {
        schedulePublish()
        onChange?()
    }

    func dialogChanged(_ tab: WebTab) {
        if let dialog = tab.dialog { onActivity?("Page dialog (\(dialog.type)): \(dialog.message.prefix(80)) - waiting for the agent or you") }
        onChange?()
    }

    /// Coalesces state publication (33 ms) and keeps it ordered through the connection's outbox.
    func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(33))
            guard let self, !Task.isCancelled else { return }
            self.publishTask = nil
            await self.publishNow()
        }
    }

    public func publishNow() async {
        await statePublisher?(state)
    }

    // MARK: Messages

    fileprivate func receive(_ message: WKScriptMessage) {
        guard let tab = tabs.first(where: { $0.webView === message.webView }) else { return }
        let body = JSONValue(foundation: message.body)
        if message.name == AgentScript.agentHandler, body["kind"]?.string == "frame" { tab.receiveFrame(body, info: message.frameInfo) }
        if message.name == AgentScript.consoleHandler { tab.receiveConsole(body) }
    }

    // MARK: Activity

    func show(_ text: String) { onActivity?(text) }

    func flash(_ tab: WebTab, cssRect: CGRect, offset: CGPoint) {
        guard tab.id == focusedTabID else { return }
        let zoom = tab.webView.pageZoom
        let rect = CGRect(x: (cssRect.minX + offset.x) * zoom, y: (cssRect.minY + offset.y) * zoom, width: cssRect.width * zoom, height: cssRect.height * zoom)
        let viewRect = tab.webView.isFlipped ? rect : CGRect(x: rect.minX, y: tab.webView.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        highlight.frame = contentView.convert(viewRect.insetBy(dx: -3, dy: -3), from: tab.webView)
        highlight.isHidden = false
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled { self?.highlight.isHidden = true }
        }
    }

    func logDelivery(_ operation: String, _ how: String) {
        deliveryLog.append("\(operation): \(how)")
        if deliveryLog.count > 500 { deliveryLog.removeFirst() }
    }

    // MARK: Commands

    public func perform(_ command: BrowserCommand) async -> BrowserOutcome {
        let summary = Self.summary(command.action)
        commandLog.append(summary)
        if commandLog.count > 1_000 { commandLog.removeFirst() }
        show("Agent: \(summary)")
        do {
            let result = try await run(command)
            let size = (try? result.value.encoded().count) ?? 0
            if size > BrowserContract.maxResultCharacters {
                throw BrowserFailure("too_large", "Browser result exceeds \(BrowserContract.maxResultCharacters) JSON characters. Request fewer entries, reduce snapshot depth, or return only selected fields.")
            }
            return .success(result)
        } catch let failure as BrowserFailure {
            show("Agent: \(summary) failed: \(failure.code)")
            return .failure(failure)
        } catch is CancellationError {
            return .failure(BrowserFailure("cancelled", "browser.\(command.type) was cancelled; it may have partially run. Inspect the tab before repeating it."))
        } catch {
            return .failure(BrowserFailure("operation_failed", "browser.\(command.type) failed: \(String(describing: error).prefix(400))"))
        }
    }

    static func summary(_ action: JSONValue) -> String {
        var fields = action.object ?? [:]
        let type = fields.removeValue(forKey: "type")?.string ?? "?"
        fields["tabID"] = fields["tabID"].map { .string(String(($0.string ?? "").prefix(12)) + "…") }
        if let script = fields["script"]?.string { fields["script"] = .string(String(script.prefix(80))) }
        if let text = fields["text"]?.string { fields["text"] = .string(String(text.prefix(80))) }
        return "\(type) \(JSONValue.object(fields).compactText)"
    }

    private func run(_ command: BrowserCommand) async throws -> BrowserResult {
        let action = command.action
        switch command.type {
        case "tabs.list":
            return BrowserResult(value: state.json)
        case "tabs.open":
            let tab = openTab(focus: action["focus"]?.bool ?? true)
            if let url = action["url"]?.string, url != "about:blank" { try await navigate(tab, to: url) }
            await publishNow()  // the server resolves tab IDs from its inventory: publish before answering
            return BrowserResult(value: tab.state.json)
        case "tabs.focus":
            let tab = try requireTab(action)
            focus(tab.id)
            await publishNow()
            return BrowserResult(value: tab.state.json)
        case "tabs.close":
            let tab = try requireTab(action)
            closeTab(tab.id)
            await publishNow()
            return BrowserResult(value: state.json)
        case "preview":
            throw BrowserFailure("unsupported", "browser.preview is not implemented by this BelloCode build. Tell the user the file path instead.")
        default:
            break
        }

        let tab = try requireTab(action)
        if command.inspect { return BrowserResult(value: inspect(tab, action)) }
        if let target = command.target, target != inspect(tab, action) {
            throw BrowserFailure("target_changed", "Browser target changed while permission was pending. Take a fresh snapshot or listing and request the action again; it was not executed.")
        }
        if let generation = command.generation, generation != tab.generation, !BrowserContract.retainedOperations.contains(command.type) {
            throw BrowserFailure("document_changed", "The document changed before this operation ran. Call browser.tabs.list({}) to check its current URL, then browser.snapshot({tabID}) for fresh refs.")
        }
        if let dialog = tab.dialog, !["dialog", "screenshot", "console", "frames", "stop"].contains(command.type) {
            throw BrowserFailure("dialog_open", "A JavaScript \(dialog.type) is blocking this tab: \"\(dialog.message.prefix(200))\". Call browser.dialog({tabID, action: \"accept\"}) or \"dismiss\" first.")
        }
        return try await BrowserOperations(host: self, tab: tab).run(command)
    }

    func requireTab(_ action: JSONValue) throws -> WebTab {
        guard let id = action["tabID"]?.string, let tab = tab(id) else {
            throw BrowserFailure("tab_unavailable", "This tab is closed or does not belong to the connected session. Call browser.tabs.list({}) and use an exact returned tabID.")
        }
        return tab
    }

    /// `Browser.Target` metadata for permission inspection: never page content.
    private func inspect(_ tab: WebTab, _ action: JSONValue) -> JSONValue {
        let url = action["type"]?.string == "navigate" ? (action["url"]?.string ?? "") : (tab.webView.url?.absoluteString ?? "about:blank")
        let refs = ["ref", "from", "to"].compactMap { action[$0]?.string }
        return ["resources": [.string(url)], "key": .string(JSONValue.array([.number(Double(tab.generation)), .array(refs.map(JSONValue.string))]).compactText)]
    }

    func navigate(_ tab: WebTab, to address: String) async throws {
        guard let url = URL(string: address), ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") else {
            throw BrowserFailure("invalid_url", "Use an HTTP/HTTPS URL or about:blank.")
        }
        tab.loadError = nil
        tab.webView.load(URLRequest(url: url))
        try await withTaskCancellationHandler {
            try await tab.waitForLoad()
        } onCancel: {
            Task { @MainActor in tab.webView.stopLoading() }
        }
        if let error = tab.loadError {
            throw BrowserFailure("navigation_failed", "browser.navigate failed. The site could not be loaded; check the URL and that the server is running. Details: \(error)")
        }
    }
}

/// The user content controller retains its handlers; this breaks the cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var host: BrowserHost?
    init(_ host: BrowserHost) { self.host = host }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { host?.receive(message) }
    }
}

/// Outline drawn over the element the agent acts on, so the person sees what it is doing.
final class HighlightView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderColor = NSColor.systemOrange.cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 3
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
