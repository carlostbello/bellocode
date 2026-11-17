import AppKit
import Engine
import Foundation
import Network
import Testing
import WebKit

@testable import BrowserKit

/// Counts TCP connections on a loopback port: proof that nothing in a visual reached the network.
final class Tally: Sendable {
    let value = Mutex(0)
    let flag = Mutex(false)
}

final class ConnectionCounter: Sendable {
    let listener: NWListener
    private let counter = Tally()

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [counter] connection in
            counter.value.withLock { $0 += 1 }
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, _, _ in
                print("M3-B listener got: \(String(decoding: data ?? Data(), as: UTF8.self).split(separator: "\r\n").first ?? "")")
                connection.cancel()
            }
        }
    }

    func start() async -> UInt16 {
        await withCheckedContinuation { continuation in
            let resumed = Tally()
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state, let port = listener.port?.rawValue, !resumed.flag.withLock({ let was = $0; $0 = true; return was }) {
                    continuation.resume(returning: port)
                }
            }
            listener.start(queue: .global())
        }
    }

    var count: Int { counter.value.withLock { $0 } }
    func stop() { listener.cancel() }
}

import Synchronization

@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct HTMLVisualSandboxTests {
    @Test func documentGetsCSPAndThemeFirst() {
        let page = HTMLVisualDocument.compose("<html><head><title>x</title></head><body>hi</body></html>", theme: .dark, allowedHosts: [])
        let head = page.range(of: "<head>")!.upperBound
        #expect(page[head...].hasPrefix("<meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\""))
        #expect(page.contains("default-src 'none'"))
        #expect(page.contains("connect-src 'none'"))
        #expect(page.contains("--chart-6"))
        #expect(page.contains("color-scheme: dark"))
        let bare = HTMLVisualDocument.compose("<svg></svg>", theme: .light, allowedHosts: ["cdn.jsdelivr.net"])
        #expect(bare.hasPrefix("<!doctype html><html><head>"))
        #expect(bare.contains("connect-src https://cdn.jsdelivr.net"))
        let rules = HTMLVisualDocument.contentRules(allowedHosts: ["cdn.jsdelivr.net"])
        #expect(rules.contains(#""url-filter":".*""#))
        #expect(rules.contains("cdn\\\\.jsdelivr\\\\.net"))
    }

    @Test func hostilePageIsContained() async throws {
        let counter = try ConnectionCounter()
        let port = await counter.start()
        defer { counter.stop() }
        let base = "http://127.0.0.1:\(port)"
        let page = """
            <html><body><h1 id=t>Hostile</h1>
            <a id=link href="\(base)/link">link</a>
            <img src="\(base)/img.png"><link rel=stylesheet href="\(base)/style.css">
            <iframe src="\(base)/frame"></iframe>
            <script>
            window.__r = {};
            fetch("\(base)/fetch").then(() => __r.fetch = "loaded").catch(() => __r.fetch = "blocked");
            try { const ws = new WebSocket("ws://127.0.0.1:\(port)/ws"); ws.onerror = () => __r.ws = "blocked"; } catch (e) { __r.ws = "blocked"; }
            __r.webkit = typeof window.webkit;
            const w = window.open("\(base)/popup"); __r.open = w === null ? "null" : "window";
            setTimeout(() => { try { location.href = "\(base)/nav"; } catch (e) {} }, 20);
            setTimeout(() => { document.getElementById("link").click(); }, 40);
            </script></body></html>
            """
        let sandbox = HTMLVisualWebView()
        var opened: [URL] = []
        sandbox.openExternally = { opened.append($0) }
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sandbox.webView
        window.orderFrontRegardless()
        defer { window.close() }
        await sandbox.load(page, theme: .light, allowedHosts: [])
        // Let the page's timers and blocked loads play out.
        for _ in 0..<40 {
            if sandbox.refusedNavigations.count >= 1 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(200))
        let result = try await sandbox.webView.evaluateJavaScript("JSON.stringify(window.__r)") as? String ?? "{}"
        let values = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: String] ?? [:]
        print("M3-B sandbox: \(values); refused \(sandbox.refusedNavigations); windows \(sandbox.refusedWindows); opened \(opened); connections \(counter.count)")
        #expect(sandbox.rulesInstalled, "the content rule list compiled and is installed")
        #expect(counter.count == 0, "no request reached the network")
        #expect(values["fetch"] == "blocked")
        #expect(values["webkit"] == "undefined", "no app message handlers are reachable")
        #expect(values["open"] == "null", "window.open is refused")
        #expect(sandbox.refusedNavigations.contains { $0.hasSuffix("/nav") }, "scripted navigation is cancelled")
        #expect(opened.isEmpty, "a scripted click on a link neither navigates nor opens anything")
        #expect(!sandbox.refusedNavigations.contains { $0.hasSuffix("/link") })
        #expect(sandbox.webView.url?.absoluteString ?? "about:blank" == "about:blank", "still on the document")
        let height = await sandbox.contentHeight()
        #expect(height > 20)
    }

    @Test func contentRulesCompileWithAndWithoutHosts() async {
        #expect(await HTMLVisualRules.list(allowedHosts: []) != nil)
        #expect(await HTMLVisualRules.list(allowedHosts: ["cdn.jsdelivr.net", "fonts.gstatic.com"]) != nil)
    }

    @Test func rendererProducesHeightPNGAndConsole() async throws {
        let renderer = HTMLVisualRenderer()
        defer { renderer.close() }
        let html = """
            <html><body><div style="height:900px;background:var(--chart-1)">tall</div>
            <script>console.error("boom"); fetch("https://example.com/data.json").catch(() => {});</script></body></html>
            """
        let output = try await renderer.render(HTMLRenderRequest(html: html, allowedHosts: [], dark: true, width: 500))
        #expect(output.contentHeight >= 900)
        #expect(output.console.contains { $0.contains("boom") })
        let png = try #require(output.png)
        let image = try #require(NSBitmapImageRep(data: png))
        #expect(image.pixelsHigh > 0)
        // Capped at the transcript's height cap (in points; 1x or 2x pixels).
        #expect(Double(image.pixelsHigh) <= VisualCardContentLimits.maxHeight * 2 + 1)
        print("M3-B renderer: height \(output.contentHeight), png \(image.pixelsWide)x\(image.pixelsHigh), console \(output.console), blocked \(output.blocked)")
    }
}
