import AppKit
import Engine
import WebKit

// HTML visual replies (docs/features/orchestration-extras.md): the sandbox every visual renders in, offscreen (for
// `html_preview`, snapshots and the PNG export) and live in the transcript.
//
// Rules, each enforced twice where WebKit allows:
// - Non-persistent data store; a fresh content controller with no message handlers (the page cannot reach the app).
// - No network: a content rule list blocks every load except about:/data:/blob: and approved hosts, and a CSP meta
//   (`default-src 'none'`, scripts inline only) refuses the rest inside the page.
// - JavaScript runs, limited to the document: no `window.open` (the UI delegate refuses every new window), no
//   navigation away (every navigation after the first load is cancelled), no frames (CSP `frame-src 'none'`).
// - Links open in the default browser only on the person's click (`.linkActivated`, http/https only).
// - Theme variables and the app's fonts are injected so the content follows light/dark.

/// Colours and fonts the visual can use as CSS variables.
public struct HTMLVisualTheme: Sendable, Hashable {
    public var dark: Bool
    public var background: String
    public var foreground: String
    public var muted: String
    public var border: String
    public var accent: String
    public var charts: [String]

    public static let light = HTMLVisualTheme(
        dark: false, background: "#ffffff", foreground: "#1d1d1f", muted: "#6e6e73", border: "#d2d2d7", accent: "#0a66d8",
        charts: ["#2f6fdf", "#e2711d", "#2a9d8f", "#c43c6b", "#7b5cd6", "#8a8f00"])
    public static let dark = HTMLVisualTheme(
        dark: true, background: "#1e1e1f", foreground: "#f2f2f4", muted: "#a1a1a6", border: "#3a3a3c", accent: "#4c9bff",
        charts: ["#5b93f2", "#f08c42", "#3fbfae", "#e2648f", "#9c84ec", "#b8bd2a"])

    public static func `for`(dark: Bool) -> HTMLVisualTheme { dark ? .dark : .light }

    var css: String {
        var variables = [
            "--background: \(background)", "--foreground: \(foreground)", "--muted: \(muted)", "--border: \(border)",
            "--accent: \(accent)", "--font-sans: -apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"Helvetica Neue\", sans-serif",
            "--font-mono: ui-monospace, \"SF Mono\", Menlo, monospace", "color-scheme: \(dark ? "dark" : "light")",
        ]
        for (index, color) in charts.enumerated() { variables.append("--chart-\(index + 1): \(color)") }
        return ":root { \(variables.joined(separator: "; ")); }\n"
            + "html, body { margin: 0; background: var(--background); color: var(--foreground); font: 13px/1.45 var(--font-sans); }\n"
            + "body { padding: 12px 14px; } a { color: var(--accent); } code, pre { font-family: var(--font-mono); }\n"
    }
}

public enum HTMLVisualDocument {
    /// The page as it runs: CSP and theme first in `<head>`, the console/CSP-violation recorder, then the content.
    public static func compose(_ html: String, theme: HTMLVisualTheme, allowedHosts: [String]) -> String {
        let hostSources = allowedHosts.map { "https://\($0)" }.joined(separator: " ")
        let csp = [
            "default-src 'none'", "script-src 'unsafe-inline' \(hostSources)", "style-src 'unsafe-inline' data: \(hostSources)",
            "img-src data: blob: \(hostSources)", "font-src data: \(hostSources)", "connect-src \(hostSources.isEmpty ? "'none'" : hostSources)",
            "media-src data: blob:", "frame-src 'none'", "child-src 'none'", "worker-src 'none'", "form-action 'none'", "base-uri 'none'",
            "object-src 'none'",
        ].map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "; ")
        let head = """
            <meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="\(csp)">
            <meta name="viewport" content="width=device-width"><style id="bellocode-theme">\(theme.css)</style>
            """
        if let range = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var result = html
            result.insert(contentsOf: head, at: range.upperBound)
            return result
        }
        if let range = html.range(of: "<html[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var result = html
            result.insert(contentsOf: "<head>\(head)</head>", at: range.upperBound)
            return result
        }
        return "<!doctype html><html><head>\(head)</head><body>\(html)</body></html>"
    }

    /// Recorder injected at document start (page world, no app access): console errors and warnings, uncaught errors,
    /// CSP violations. Read back with `evaluateJavaScript` after load.
    static let recorder = """
        (() => {
          const log = []; window.__bellocode = { log, blocked: [] };
          const keep = (kind, args) => { if (log.length < 50) log.push(kind + ": " + Array.from(args).map(String).join(" ").slice(0, 300)); };
          for (const kind of ["error", "warn"]) { const original = console[kind]; console[kind] = function () { keep(kind, arguments); return original.apply(this, arguments); }; }
          window.addEventListener("error", (event) => keep("uncaught", [event.message]));
          // Only the person's own clicks follow links (and then open in the default browser): scripted clicks are
          // dropped before WebKit starts the navigation (it would otherwise pre-connect to the host).
          window.addEventListener("click", (event) => {
            const anchor = event.target && event.target.closest ? event.target.closest("a[href]") : null;
            if (anchor && !event.isTrusted) { event.preventDefault(); event.stopImmediatePropagation(); }
          }, true);
          document.addEventListener("securitypolicyviolation", (event) => { if (window.__bellocode.blocked.length < 50) window.__bellocode.blocked.push(event.blockedURI + " (" + event.effectiveDirective + ")"); });
        })();
        """

    /// Content rules: block every load, then let about:/data:/blob: and approved hosts through.
    public static func contentRules(allowedHosts: [String]) -> String {
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            // WebKit's rule regexes have no disjunctions: one rule per scheme.
            ["trigger": ["url-filter": "^about:"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^data:"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^blob:"], "action": ["type": "ignore-previous-rules"]],
        ]
        for host in allowedHosts {
            let escaped = NSRegularExpression.escapedPattern(for: host)
            rules.append(["trigger": ["url-filter": "^https://\(escaped)[:/]"], "action": ["type": "ignore-previous-rules"]])
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Compiled content rule lists, by host set (compiling takes a few milliseconds; bounded).
@MainActor
enum HTMLVisualRules {
    private static var compiled: [String: WKContentRuleList] = [:]

    static func list(allowedHosts: [String]) async -> WKContentRuleList? {
        let key = allowedHosts.sorted().joined(separator: ",")
        if let list = compiled[key] { return list }
        let identifier = "bellocode-visual-" + String(key.hashValue, radix: 36)
        guard let store = WKContentRuleListStore.default(),
            let list = try? await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: HTMLVisualDocument.contentRules(allowedHosts: allowedHosts))
        else { return nil }
        if compiled.count > 32 { compiled.removeAll() }
        compiled[key] = list
        return list
    }
}

/// A WebKit step that ran past its time limit or was cancelled. Each step of a render has its own limit, because WebKit's
/// async calls never time out on their own: a page whose script loops forever blocks its JavaScript thread, and an
/// evaluation or snapshot sent to it never completes.
public struct HTMLVisualTimeout: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Step: String, Sendable, Hashable { case load, script, sizing, snapshot }
    public var step: Step
    public var limit: Duration
    public var description: String { "\(step.rawValue) did not finish within \(limit)" }
}

/// Runs one completion-handler WebKit call with a hard time limit and cancellation. The continuation is resumed exactly
/// once, by whichever comes first: the completion, the limit or cancellation. A completion that arrives later (when
/// the web view is discarded) is ignored.
@MainActor
func withWebKitDeadline<T: Sendable>(
    _ step: HTMLVisualTimeout.Step, limit: Duration, _ start: (@escaping @MainActor (Result<T, any Error>) -> Void) -> Void
) async throws -> T {
    try Task.checkCancellation()
    let once = WebKitOnce<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            once.continuation = continuation
            let timer = DispatchWorkItem { MainActor.assumeIsolated { once.resume(.failure(HTMLVisualTimeout(step: step, limit: limit))) } }
            once.timer = timer
            let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timer)
            start { result in once.resume(result) }
        }
    } onCancel: {
        DispatchQueue.main.async { MainActor.assumeIsolated { once.resume(.failure(CancellationError())) } }
    }
}

@MainActor
private final class WebKitOnce<T: Sendable> {
    var continuation: CheckedContinuation<T, any Error>?
    var timer: DispatchWorkItem?

    func resume(_ result: Result<T, any Error>) {
        timer?.cancel()
        timer = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

/// A sandboxed web view and its delegates. One per live visual (bounded by the host) or per offscreen render.
@MainActor
public final class HTMLVisualWebView: NSObject, WKNavigationDelegate, WKUIDelegate {
    public let webView: WKWebView
    /// Opens a link the person clicked (http/https only).
    public var openExternally: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Navigations refused after the first load (tests and diagnostics).
    public private(set) var refusedNavigations: [String] = []
    public private(set) var refusedWindows = 0
    /// Whether the content rule list compiled and is installed (the CSP applies either way).
    public private(set) var rulesInstalled = false
    /// The first load finished (`didFinish` or a failure), as opposed to giving up at the limit.
    public private(set) var loadFinished = false
    /// The web view was discarded after a step ran past its limit; it must not be used again.
    public private(set) var isDiscarded = false
    private var loadCompletion: (@MainActor (Result<Void, any Error>) -> Void)?
    private var firstLoadDone = false

    public init(frame: CGRect = CGRect(x: 0, y: 0, width: 720, height: 400)) {
        let configuration = WKWebViewConfiguration()
        // A data store of its own also gives the view a web content process of its own (WebKit does not share
        // processes across data stores), so a page stuck in a script cannot stall the next one.
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = WKUserContentController()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.suppressesIncrementalRendering = true
        configuration.userContentController.addUserScript(
            WKUserScript(source: HTMLVisualDocument.recorder, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: frame, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.setAccessibilityLabel("Visual")
    }

    /// Loads a visual and waits for it to finish, at most `limit`. Returns whether it finished; a page still loading at
    /// the limit (a script that never returns, a request that never answers) is left as it is.
    @discardableResult
    public func load(_ html: String, theme: HTMLVisualTheme, allowedHosts: [String], limit: Duration = .seconds(5)) async -> Bool {
        do {
            try await loadOrThrow(html, theme: theme, allowedHosts: allowedHosts, limit: limit)
            return true
        } catch {
            return false
        }
    }

    /// `load`, throwing `HTMLVisualTimeout(.load)` at the limit and `CancellationError` when cancelled.
    func loadOrThrow(_ html: String, theme: HTMLVisualTheme, allowedHosts: [String], limit: Duration) async throws {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if let rules = await HTMLVisualRules.list(allowedHosts: allowedHosts) {
            controller.add(rules)
            rulesInstalled = true
        } else {
            rulesInstalled = false
        }
        webView.appearance = NSAppearance(named: theme.dark ? .darkAqua : .aqua)
        firstLoadDone = false
        loadFinished = false
        let page = HTMLVisualDocument.compose(html, theme: theme, allowedHosts: allowedHosts)
        defer { loadCompletion = nil }
        try await withWebKitDeadline(.load, limit: limit) { (done: @escaping @MainActor (Result<Void, any Error>) -> Void) in
            loadCompletion = done
            webView.loadHTMLString(page, baseURL: nil)
        }
    }

    private func finishLoad() {
        firstLoadDone = true
        loadFinished = true
        loadCompletion?(.success(()))
        loadCompletion = nil
    }

    /// What a script evaluation returned, reduced to what the renderer reads.
    enum ScriptValue: Sendable, Equatable {
        case number(Double)
        case string(String)
        case other
    }

    /// Runs `script` in the page, at most `limit` (`HTMLVisualTimeout(step)` after it).
    func evaluate(_ script: String, step: HTMLVisualTimeout.Step = .script, limit: Duration) async throws -> ScriptValue {
        try await withWebKitDeadline(step, limit: limit) { done in
            webView.evaluateJavaScript(script) { value, error in
                let result: Result<ScriptValue, any Error>
                if let error {
                    result = .failure(error)
                } else if let number = value as? NSNumber {
                    result = .success(.number(number.doubleValue))
                } else if let text = value as? String {
                    result = .success(.string(text))
                } else {
                    result = .success(.other)
                }
                MainActor.assumeIsolated { done(result) }
            }
        }
    }

    /// The document's height in CSS pixels; 0 if it cannot be read within `limit`.
    public func contentHeight(limit: Duration = .seconds(2)) async -> Double {
        (try? await contentHeightOrThrow(limit: limit)) ?? 0
    }

    func contentHeightOrThrow(limit: Duration) async throws -> Double {
        let value = try await evaluate(
            "document.body ? Math.ceil(Math.max(document.body.scrollHeight, document.body.getBoundingClientRect().height)) : 0",
            step: .sizing, limit: limit)
        if case .number(let height) = value { return height }
        return 0
    }

    /// Console lines and refused requests the recorder kept; empty if they cannot be read within `limit`.
    public func recorded(limit: Duration = .seconds(2)) async -> (console: [String], blocked: [String]) {
        guard case .string(let text)? = try? await evaluate("JSON.stringify(window.__bellocode || {log: [], blocked: []})", limit: limit),
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ([], []) }
        return (object["log"] as? [String] ?? [], object["blocked"] as? [String] ?? [])
    }

    /// A PNG snapshot of `rect`, at most `limit` (nil if WebKit drew nothing).
    func snapshotPNG(_ rect: CGRect, limit: Duration) async throws -> Data? {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.afterScreenUpdates = true
        return try await withWebKitDeadline(.snapshot, limit: limit) { done in
            webView.takeSnapshot(with: configuration) { image, error in
                let result: Result<Data?, any Error>
                if let image {
                    let png = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])
                    result = .success(png)
                } else if let error {
                    result = .failure(error)
                } else {
                    result = .success(nil)
                }
                MainActor.assumeIsolated { done(result) }
            }
        }
    }

    /// Gives up on this web view after a step ran past its limit: stops loading, detaches the delegates, removes it
    /// from its window and ends its web content process. A process stuck in a script never answers again, so the
    /// view cannot be reused; ending the process also frees the CPU it is spinning on.
    public func discard() {
        guard !isDiscarded else { return }
        isDiscarded = true
        loadCompletion?(.failure(CancellationError()))
        loadCompletion = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        // No public API ends a web content process. `_killWebContentProcess` is what WebKit's own tests use; when it
        // is missing, releasing the view closes the page and WebKit reclaims the process.
        let kill = NSSelectorFromString("_killWebContentProcess")
        if webView.responds(to: kill) { webView.perform(kill) }
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        let scheme = url?.scheme?.lowercased() ?? ""
        // The document itself (about:blank from loadHTMLString) and same-document fragment jumps.
        if !firstLoadDone, navigationAction.targetFrame?.isMainFrame == true, scheme == "about" || scheme.isEmpty { return .allow }
        if scheme == "about", url?.absoluteString.hasPrefix("about:blank#") == true { return .allow }
        refusedNavigations.append(url?.absoluteString ?? "")
        if navigationAction.navigationType == .linkActivated, ["http", "https"].contains(scheme), let url { openExternally(url) }
        return .cancel
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoad() }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finishLoad() }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finishLoad() }

    // MARK: WKUIDelegate

    public func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        refusedWindows += 1
        return nil
    }
}

/// Renders visuals offscreen (`HTMLVisualRendering` for the Engine): one at a time in a hidden window, so WebKit
/// paints; returns the content height, a PNG (height capped), console lines and refused requests.
///
/// Every WebKit step has a hard limit (`Limits`). A step past its limit ends the render with an `ExtrasError` the agent
/// reads (the transcript card shows it as a failed visual), and the web view is discarded with its content process, so
/// the next render in the queue starts on a fresh view and process. At most `Limits.maxWaiting` renders wait; more
/// are refused at once. A waiting render that is cancelled leaves the queue.
@MainActor
public final class HTMLVisualRenderer: HTMLVisualRendering {
    public struct Limits: Sendable, Hashable {
        /// Loading the document (parsing it runs its inline scripts; an endless loop never finishes).
        public var load: Duration
        /// Each script evaluation (sizing, reading the console recorder).
        public var script: Duration
        /// The snapshot.
        public var snapshot: Duration
        /// Renders waiting behind the current one.
        public var maxWaiting: Int

        public init(load: Duration = .seconds(5), script: Duration = .seconds(2), snapshot: Duration = .seconds(5), maxWaiting: Int = 8) {
            self.load = load
            self.script = script
            self.snapshot = snapshot
            self.maxWaiting = maxWaiting
        }

        public static let standard = Limits()
    }

    public let limits: Limits
    private var window: NSWindow?
    private var sandbox: HTMLVisualWebView?
    private var busy = false
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, any Error>)] = []
    private var nextWaiterID = 0
    /// Web views given up on after a step ran past its limit (tests and diagnostics).
    public private(set) var discardedViews = 0

    public init(limits: Limits = .standard) {
        self.limits = limits
    }

    public func render(_ request: HTMLRenderRequest) async throws -> HTMLRenderOutput {
        try await acquire()
        defer { release() }
        let sandbox = prepare(width: request.width)
        do {
            return try await render(request, in: sandbox)
        } catch {
            sandbox.discard()
            discardedViews += 1
            if self.sandbox === sandbox { window?.contentView = nil }
            throw Self.failure(error)
        }
    }

    private func render(_ request: HTMLRenderRequest, in sandbox: HTMLVisualWebView) async throws -> HTMLRenderOutput {
        try await sandbox.loadOrThrow(request.html, theme: .for(dark: request.dark), allowedHosts: request.allowedHosts, limit: limits.load)
        let height = try await sandbox.contentHeightOrThrow(limit: limits.script)
        let shown = min(VisualCardContentLimits.maxHeight, max(60, height))
        window?.setContentSize(NSSize(width: request.width, height: shown))
        sandbox.webView.frame = CGRect(x: 0, y: 0, width: request.width, height: shown)
        sandbox.webView.layoutSubtreeIfNeeded()
        let png = try await sandbox.snapshotPNG(CGRect(x: 0, y: 0, width: request.width, height: shown), limit: limits.snapshot)
        let recorded = await sandbox.recorded(limit: limits.script)
        let blocked = recorded.blocked + sandbox.refusedNavigations.map { "navigation to \($0)" }
            + (sandbox.refusedWindows > 0 ? ["\(sandbox.refusedWindows) window.open call(s)"] : [])
        return HTMLRenderOutput(contentHeight: height, png: png, console: recorded.console, blocked: blocked)
    }

    /// What the agent reads when a render fails.
    static func failure(_ error: any Error) -> any Error {
        guard let timeout = error as? HTMLVisualTimeout else { return error }
        let seconds = timeout.limit.components.seconds
        let limit = seconds > 0 ? "\(seconds) s" : "\(timeout.limit)"
        let what: String
        switch timeout.step {
        case .load: what = "The page did not finish loading within \(limit): a script that never returns (an endless loop) or a request that never answers."
        case .script, .sizing: what = "The page's JavaScript did not respond within \(limit): a script is probably stuck in an endless loop."
        case .snapshot: what = "The page could not be drawn within \(limit) (too large, or a script is blocking it)."
        }
        return ExtrasError("Visual not rendered. \(what) Fix the document and try again; the user sees it as a failed visual.")
    }

    /// The sandbox of the last render (tests inspect it).
    public var lastSandbox: HTMLVisualWebView? { sandbox }

    /// Renders running or waiting (tests).
    public var queueDepth: Int { (busy ? 1 : 0) + waiters.count }

    private func prepare(width: Double) -> HTMLVisualWebView {
        // A fresh web view per render: nothing carries over between documents.
        let sandbox = HTMLVisualWebView(frame: CGRect(x: 0, y: 0, width: width, height: 400))
        let window = self.window ?? {
            let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: width, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.alphaValue = 0.01
            window.collectionBehavior = [.transient, .ignoresCycle]
            window.orderFrontRegardless()
            return window
        }()
        self.window = window
        window.setContentSize(NSSize(width: width, height: 400))
        window.contentView = sandbox.webView
        self.sandbox = sandbox
        return sandbox
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !busy {
            busy = true
            return
        }
        guard waiters.count < limits.maxWaiting else {
            throw ExtrasError("Visual not rendered: \(waiters.count) visuals are already waiting to render. Try again in a moment.")
        }
        nextWaiterID += 1
        let id = nextWaiterID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters.append((id, continuation))
            }
        } onCancel: {
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.cancelWaiter(id) } }
        }
    }

    private func cancelWaiter(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().continuation.resume() }
    }

    /// Closes the hidden window (app shutdown). Renders waiting are cancelled.
    public func close() {
        for waiter in waiters { waiter.continuation.resume(throwing: CancellationError()) }
        waiters.removeAll()
        sandbox?.discard()
        window?.close()
        window = nil
        sandbox = nil
    }
}
