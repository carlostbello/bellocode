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
            ["trigger": ["url-filter": "^(about|data|blob):"], "action": ["type": "ignore-previous-rules"]],
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

/// A sandboxed web view and its delegates. One per live visual (bounded by the host) or per offscreen render.
@MainActor
public final class HTMLVisualWebView: NSObject, WKNavigationDelegate, WKUIDelegate {
    public let webView: WKWebView
    /// Opens a link the person clicked (http/https only).
    public var openExternally: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Navigations refused after the first load (tests and diagnostics).
    public private(set) var refusedNavigations: [String] = []
    public private(set) var refusedWindows = 0
    private var loaded: CheckedContinuation<Void, Never>?
    private var firstLoadDone = false

    public init(frame: CGRect = CGRect(x: 0, y: 0, width: 720, height: 400)) {
        let configuration = WKWebViewConfiguration()
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

    /// Loads a visual and waits for it to finish (bounded).
    public func load(_ html: String, theme: HTMLVisualTheme, allowedHosts: [String]) async {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if let rules = await HTMLVisualRules.list(allowedHosts: allowedHosts) { controller.add(rules) }
        webView.appearance = NSAppearance(named: theme.dark ? .darkAqua : .aqua)
        firstLoadDone = false
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(HTMLVisualDocument.compose(html, theme: theme, allowedHosts: allowedHosts), baseURL: nil)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.finishLoad()
            }
        }
    }

    private func finishLoad() {
        firstLoadDone = true
        let continuation = loaded
        loaded = nil
        continuation?.resume()
    }

    public func contentHeight() async -> Double {
        let value = try? await webView.evaluateJavaScript("Math.ceil(Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0))")
        return (value as? NSNumber)?.doubleValue ?? 0
    }

    public func recorded() async -> (console: [String], blocked: [String]) {
        let value = try? await webView.evaluateJavaScript("JSON.stringify(window.__bellocode || {log: [], blocked: []})")
        guard let text = value as? String, let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ([], []) }
        return (object["log"] as? [String] ?? [], object["blocked"] as? [String] ?? [])
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
@MainActor
public final class HTMLVisualRenderer: HTMLVisualRendering {
    private var window: NSWindow?
    private var sandbox: HTMLVisualWebView?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func render(_ request: HTMLRenderRequest) async throws -> HTMLRenderOutput {
        await acquire()
        defer { release() }
        let sandbox = prepare(width: request.width)
        await sandbox.load(request.html, theme: .for(dark: request.dark), allowedHosts: request.allowedHosts)
        let height = await sandbox.contentHeight()
        let shown = min(VisualCardContentLimits.maxHeight, max(60, height))
        window?.setContentSize(NSSize(width: request.width, height: shown))
        sandbox.webView.frame = CGRect(x: 0, y: 0, width: request.width, height: shown)
        sandbox.webView.layoutSubtreeIfNeeded()
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: request.width, height: shown)
        configuration.afterScreenUpdates = true
        var png: Data?
        if let image = try? await sandbox.webView.takeSnapshot(configuration: configuration), let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff)
        {
            png = bitmap.representation(using: .png, properties: [:])
        }
        let recorded = await sandbox.recorded()
        let blocked = recorded.blocked + sandbox.refusedNavigations.map { "navigation to \($0)" }
            + (sandbox.refusedWindows > 0 ? ["\(sandbox.refusedWindows) window.open call(s)"] : [])
        return HTMLRenderOutput(contentHeight: height, png: png, console: recorded.console, blocked: blocked)
    }

    /// The sandbox of the last render (tests inspect it).
    public var lastSandbox: HTMLVisualWebView? { sandbox }

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

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    /// Closes the hidden window (app shutdown).
    public func close() {
        window?.close()
        window = nil
        sandbox = nil
    }
}
