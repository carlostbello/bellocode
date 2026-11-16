// SPIKE (gate G3). One browser tab: a visible WKWebView plus the state the bridge needs (document generation, frame
// registry, element refs, pending dialog, console buffer).

import AppKit
import WebKit

/// WKWebView that can swallow the context menu an agent's right click would open (a modal tracking loop that would
/// otherwise block the main thread until a person dismisses it).
final class AgentWebView: WKWebView {
    var suppressMenusUntil: Date = .distantPast

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        if Date() < suppressMenusUntil {
            DispatchQueue.main.async { menu.cancelTrackingWithoutAnimation() }
        }
    }
}

@MainActor
public final class WebTab: NSObject {
    public let id: String
    let webView: AgentWebView
    public private(set) var generation = 0
    var loadError: String?
    weak var host: BrowserHost?
    var observations: [NSKeyValueObservation] = []

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

    struct Dialog {
        var type: String
        var message: String
        var defaultValue: String
        var resolve: (_ accept: Bool, _ text: String?) -> Void
    }
    var dialog: Dialog?

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

    init(id: String, configuration: WKWebViewConfiguration, host: BrowserHost) {
        self.id = id
        self.host = host
        webView = AgentWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true
        observations = [
            webView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.changed() } },
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.changed() } },
            webView.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.changed() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.changed() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.changed() } },
        ]
    }

    func close() {
        observations.removeAll()
        dialog?.resolve(false, nil)
        dialog = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    private func changed() { host?.tabChanged(self) }

    public var state: BrowserTab {
        BrowserTab(
            id: id, url: webView.url?.absoluteString ?? "about:blank", title: webView.title ?? "", loading: webView.isLoading,
            loadError: loadError, canGoBack: webView.canGoBack, canGoForward: webView.canGoForward, generation: generation
        )
    }

    // MARK: Messages from injected scripts (routed by the host, which owns the shared user content controller)

    func receiveFrame(_ body: JSONValue, info: WKFrameInfo) {
        guard let frameID = body["frameId"]?.string else { return }
        if frames[frameID] == nil { frameOrder.append(frameID) }
        frames[frameID] = Frame(info: info, url: body["url"]?.string ?? info.request.url?.absoluteString ?? "", name: body["name"]?.string ?? "", isMain: info.isMainFrame)
        // Bound the registry: drop the oldest non-main frames.
        while frameOrder.count > 64, let victim = frameOrder.first(where: { frames[$0]?.isMain == false }) {
            frames[victim] = nil
            frameOrder.removeAll { $0 == victim }
        }
    }

    func receiveConsole(_ body: JSONValue) {
        let text = body["text"]?.string ?? ""
        let entry = ConsoleEntry(
            id: "log_\(UUID().uuidString.lowercased().prefix(8))", timestampMs: Date().timeIntervalSince1970 * 1000,
            level: body["level"]?.string ?? "info", text: String(text.prefix(BrowserContract.maxText)), truncated: text.count > BrowserContract.maxText,
            source: body["source"].flatMap { $0 == .null ? nil : $0 }
        )
        console.append(entry)
        if console.count > Self.consoleLimit {
            console.removeFirst(console.count - Self.consoleLimit)
            consoleDropped += 1
        }
    }

    // MARK: JavaScript

    func frameInfo(_ frameID: String?) throws -> (id: String, info: WKFrameInfo?) {
        guard let frameID else { return (mainFrameID ?? "main", nil) }
        guard let frame = frames[frameID] else {
            throw BrowserFailure("frame_unavailable", "Frame \(frameID) is unavailable. Call browser.frames({tabID}) and use a current frameID; omit frameID for the main frame.")
        }
        return (frameID, frame.isMain ? nil : frame.info)
    }

    /// Calls `window.__bc.call(name, input)` in the isolated world of a frame and decodes its JSON result.
    func agent(_ name: String, _ input: JSONValue = [:], frame: WKFrameInfo? = nil, timeout: Duration = .seconds(30)) async throws -> JSONValue {
        let body = AgentScript.source + "\nreturn JSON.stringify((await window.__bc.call(\(jsString(name)), JSON.parse(input))) ?? null);"
        let raw = try await callJS(body, arguments: ["input": input.compactText], frame: frame, world: host!.agentWorld, timeout: timeout)
        return try await Self.decode(raw)
    }

    /// `callAsyncJavaScript` with a deadline and cancellation: WebKit's own call cannot be cancelled and never returns
    /// while a dialog blocks the page, so the continuation is resumed by whichever comes first.
    func callJS(_ body: String, arguments: [String: Any] = [:], frame: WKFrameInfo?, world: WKContentWorld, timeout: Duration = .seconds(30), program: Bool = false) async throws -> JSONValue {
        let once = OnceContinuation()
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
                // WebKit never answers while a JavaScript dialog blocks the page: stop waiting as soon as one opens.
                let hadDialog = dialog != nil
                Task { @MainActor [weak self] in
                    let deadline = ContinuousClock.now + timeout
                    while ContinuousClock.now < deadline, !once.finished {
                        if !hadDialog, let dialog = self?.dialog {
                            once.resume(throwing: DialogInterrupted(type: dialog.type, message: dialog.message))
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                    once.resume(throwing: BrowserFailure("timeout", "The page did not answer within \(timeout). It may be busy; call browser.dialog({tabID, action: \"get\"}) or inspect the tab."))
                }
            }
        } onCancel: {
            Task { @MainActor in once.resume(throwing: CancellationError()) }
        }
    }

    @concurrent
    static func decode(_ raw: JSONValue) async throws -> JSONValue {
        guard let text = raw.string else { return .null }
        return try JSONValue.parse(Data(text.utf8))
    }

    static func scriptFailure(_ error: any Error) -> BrowserFailure {
        let nsError = error as NSError
        let message = (nsError.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? nsError.localizedDescription
        for code in ["stale_ref", "not_editable", "not_select", "option_missing", "not_multiple", "not_file_input", "not_checkable"] where message.contains(code) {
            let detail = message.components(separatedBy: "\(code): ").last ?? message
            let hint = code == "stale_ref" ? " Call browser.snapshot({tabID}) and use a fresh ref from this tab." : ""
            return BrowserFailure(code, detail + hint)
        }
        return BrowserFailure("script_error", "Page JavaScript failed: \(message.prefix(800))")
    }

    // MARK: Loading

    /// Waits until WebKit reports the tab idle. Polling is fine for the spike; production uses the navigation delegate.
    func waitForLoad(timeout: Duration = .seconds(30)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        try await Task.sleep(for: .milliseconds(30))
        while webView.isLoading {
            try Task.checkCancellation()
            if dialog != nil { return }
            if clock.now > deadline { throw BrowserFailure("timeout", "The page is still loading after \(timeout). Call browser.stop({tabID}) or inspect it.") }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
}

// MARK: - Navigation and UI delegates

extension WebTab: WKNavigationDelegate, WKUIDelegate {
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadError = nil
        changed()
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new main-frame document: refs, frames and console belong to the old one.
        generation += 1
        refs.removeAll()
        frames.removeAll()
        frameOrder.removeAll()
        console.removeAll()
        consoleDropped = 0
        changed()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { changed() }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        record(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        record(error)
    }

    private func record(_ error: any Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        loadError = "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
        changed()
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // window.open and target=_blank become a new tab of the same session.
        host?.openTab(configuration: configuration, focus: true).webView
    }

    public func webViewDidClose(_ webView: WKWebView) { host?.closeTab(id) }

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

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        // The spike never shows an open panel; files reach inputs through browser.files.upload.
        nil
    }

    /// The page stays blocked until the agent (browser.dialog) or the person (banner buttons) answers.
    private func present(type: String, message: String, defaultValue: String) async -> (accept: Bool, text: String?) {
        dialog?.resolve(false, nil)
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, String?), Never>) in
            dialog = Dialog(type: type, message: message, defaultValue: defaultValue) { accept, text in
                continuation.resume(returning: (accept, text))
            }
            host?.dialogChanged(self)
        }
        dialog = nil
        host?.dialogChanged(self)
        return answer
    }

    public var pendingDialog: (type: String, message: String)? { dialog.map { ($0.type, $0.message) } }

    /// The person's answer from the dialog banner.
    public func respondToDialog(accept: Bool) {
        answerDialog(accept: accept, text: nil)
        host?.show("You \(accept ? "accepted" : "dismissed") the page dialog")
    }

    func answerDialog(accept: Bool, text: String?) {
        guard let dialog else { return }
        self.dialog = nil
        dialog.resolve(accept, text)
    }
}

/// Resumes a continuation at most once, whichever of completion, timeout or cancellation wins.
@MainActor
final class OnceContinuation {
    private var continuation: CheckedContinuation<JSONValue, any Error>?
    private var early: Result<JSONValue, any Error>?

    func set(_ continuation: CheckedContinuation<JSONValue, any Error>) {
        if let early {
            self.early = nil
            continuation.resume(with: early)
        } else {
            self.continuation = continuation
        }
    }

    private(set) var finished = false
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

func jsString(_ value: String) -> String { JSONValue.string(value).compactText }

/// A script call was cut short because the page opened a JavaScript dialog. The action itself ran.
struct DialogInterrupted: Error {
    var type: String
    var message: String
}
