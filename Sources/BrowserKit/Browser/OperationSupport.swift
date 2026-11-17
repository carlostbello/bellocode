import OpenCodeKit

/// How well this WebKit browser supports each `experimental.browser` operation (docs/features/browser.md). One table
/// drives the model guidance, the unsupported-operation failures and the docs, so they cannot drift apart.
public enum OperationSupport: String, Sendable, CaseIterable {
    case supported
    /// Works with documented limits (script fallbacks, partial data).
    case reduced
    /// Fails with `[browser.unsupported]` and a hint.
    case unsupported

    public static let matrix: [(operation: String, support: OperationSupport, note: String)] = [
        ("tabs.list", .supported, "shared tabs only"), ("tabs.open", .supported, ""), ("tabs.focus", .supported, ""),
        ("tabs.close", .supported, ""), ("navigate", .supported, "http, https, about:blank"), ("back", .supported, ""),
        ("forward", .supported, ""), ("reload", .supported, ""), ("stop", .supported, ""),
        ("frames", .supported, "nested frames are listed under the main frame"),
        ("snapshot", .supported, "open shadow roots and slots; closed shadow roots are invisible"),
        ("find", .supported, ""), ("evaluate", .supported, "with ref: runs in an isolated world (page globals not visible)"),
        ("click", .supported, "trusted native input; middle click by script"), ("fill", .supported, "trusted native typing"),
        ("fill_form", .supported, ""), ("select", .supported, ""), ("check", .supported, ""),
        ("press", .supported, "trusted native keys"), ("wait", .supported, ""),
        ("screenshot", .supported, "png or jpeg; viewport, element or full page"), ("dialog", .supported, ""),
        ("console", .supported, "page-world hook; entries are untrusted"), ("files.upload", .supported, "by script"),
        ("files.list", .supported, "screenshots and downloads"), ("files.get", .supported, ""),
        ("hover", .reduced, "CSS :hover only while the window is key; otherwise synthetic mouseover"),
        ("scroll", .reduced, "exact scrollBy, no wheel event"), ("drag", .reduced, "synthetic drag events, one frame"),
        ("files.drop", .reduced, "synthetic drop events"),
        ("network.list", .reduced, "Resource Timing only: no methods, headers, failures"),
        ("network.get", .reduced, "no headers or bodies"),
        ("preview", .unsupported, "tell the user the file path"),
        ("trace.start", .unsupported, "no Chromium DevTools protocol"), ("trace.stop", .unsupported, ""),
        ("trace.analyze", .unsupported, ""), ("cpu.start", .unsupported, ""), ("cpu.stop", .unsupported, ""),
        ("cpu.analyze", .unsupported, ""), ("heap.snapshot", .unsupported, ""), ("heap.summary", .unsupported, ""),
        ("heap.query", .unsupported, ""), ("heap.object", .unsupported, ""), ("heap.compare", .unsupported, ""),
        ("lighthouse", .unsupported, ""),
    ]

    public static func support(for operation: String) -> OperationSupport {
        matrix.first { $0.operation == operation }?.support ?? .unsupported
    }

    /// The failure for an operation this browser cannot run.
    public static func unsupportedFailure(_ operation: String) -> BrowserFailure {
        switch operation {
        case "preview":
            BrowserFailure(.unsupported, "browser.preview is not available in BelloCode's browser. Tell the user the file path instead, or open an http URL with browser.tabs.open.")
        case let name where name.hasPrefix("trace.") || name.hasPrefix("cpu.") || name.hasPrefix("heap.") || name == "lighthouse":
            BrowserFailure(.unsupported, "browser.\(name) needs the Chromium DevTools protocol; BelloCode's browser is WebKit and has none. Use browser.evaluate with the Performance API (performance.getEntriesByType, PerformanceObserver; performance.memory does not exist), or ask the user to profile in Safari Web Inspector.")
        default:
            BrowserFailure(.unsupported, "BelloCode's browser does not support browser.\(operation). Use another browser operation; do not retry this one.")
        }
    }

    /// Model guidance, attached to the session as the instruction entry `bellocode.browser` while a browser is
    /// attached. The built-in `browser` skill describes a Chromium desktop; this corrects it for this browser.
    public static let guidance: String = {
        let unsupported = matrix.filter { $0.support == .unsupported }.map(\.operation)
        let reduced = matrix.filter { $0.support == .reduced }.map { "\($0.operation) (\($0.note))" }
        return """
            When the browser.* tools are available in this session, they drive BelloCode's built-in browser: a WebKit \
            (Safari engine) view in the user's BelloCode window, not Chromium. Where the browser skill differs, this \
            note wins.
            - Unavailable here (they fail with [browser.unsupported]; do not call them): \(unsupported.joined(separator: ", ")). \
            For performance, use browser.evaluate with the Performance API instead of trace, cpu, heap or lighthouse recipes.
            - Reduced fidelity: \(reduced.joined(separator: "; ")).
            - Pages load from the user's own Mac, so localhost is the user's machine.
            - You only see tabs you opened and tabs the user shared with this thread. If the user starts using a tab \
            you are driving, your actions on it fail with [browser.user_control] until they resume you; wait or ask, \
            do not work around it.
            - A JavaScript alert, confirm or prompt blocks the page until answered: call browser.dialog first \
            (other operations fail with [browser.dialog_open]).
            """
    }()
}
