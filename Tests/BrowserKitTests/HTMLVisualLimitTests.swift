import AppKit
import Engine
import Foundation
import Network
import Synchronization
import Testing
import WebKit

@testable import BrowserKit

/// Accepts loopback TCP connections and never answers: a request to it never finishes. Nothing leaves the machine.
final class SilentListener: Sendable {
    let listener: NWListener
    private let held = Mutex<[NWConnection]>([])
    let accepted = Mutex(0)

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accepted.withLock { $0 += 1 }
            self?.held.withLock { $0.append(connection) }
            connection.start(queue: .global())
        }
    }

    func start() async -> UInt16 {
        await withCheckedContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state, let port = listener.port?.rawValue, !resumed.withLock({ let was = $0; $0 = true; return was }) {
                    continuation.resume(returning: port)
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() {
        listener.cancel()
        for connection in held.withLock({ $0 }) { connection.cancel() }
    }
}

/// Every WebKit step of an offscreen render has a hard limit: a hostile or broken visual fails fast with a clear
/// message, its web view (and content process) is discarded, and the render queued behind it proceeds.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct HTMLVisualLimitTests {
    static let limits = HTMLVisualRenderer.Limits(load: .seconds(1), script: .seconds(1), snapshot: .seconds(3), maxWaiting: 2)
    static let simple = "<html><body><div style=\"height:120px\">ok</div></body></html>"

    func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    /// Renders `html`, expecting a failure; returns its message and how long it took.
    func expectFailure(_ renderer: HTMLVisualRenderer, _ html: String, hosts: [String] = []) async -> (String, Double) {
        let start = ContinuousClock.now
        do {
            _ = try await renderer.render(HTMLRenderRequest(html: html, allowedHosts: hosts, width: 400))
            Issue.record("the render was expected to fail")
            return ("", seconds(since: start))
        } catch {
            return (ExtrasError.message(error), seconds(since: start))
        }
    }

    @Test func endlessLoopWhileParsingFailsFastAndTheNextRenderProceeds() async throws {
        let renderer = HTMLVisualRenderer(limits: Self.limits)
        defer { renderer.close() }
        // The next render is queued while the stuck one runs: it must start as soon as the first gives up.
        let stuck = Task { await expectFailure(renderer, "<html><body>loop<script>while (true) {}</script></body></html>") }
        while renderer.queueDepth == 0 { await Task.yield() }
        // `render` acquires and prepares its web view without suspending: this is the stuck render's view.
        let stuckView = renderer.lastSandbox
        let queuedStart = ContinuousClock.now
        let next = Task { try await renderer.render(HTMLRenderRequest(html: Self.simple, width: 400)) }
        let (message, elapsed) = await stuck.value
        print("HTML-LIMITS endless loop (parse): failed after \(String(format: "%.2f", elapsed)) s: \(message)")
        #expect(message.contains("did not finish loading"), "\(message)")
        #expect(message.contains("endless loop"))
        #expect(elapsed < 10, "fails at the 1 s load limit, not WebKit's own timeouts (\(elapsed) s)")
        #expect(renderer.discardedViews == 1)
        #expect(stuckView?.isDiscarded == true)
        let output = try await next.value
        let queuedFor = seconds(since: queuedStart)
        print("HTML-LIMITS render queued behind the loop finished after \(String(format: "%.2f", queuedFor)) s")
        #expect(output.contentHeight >= 120, "the render behind it ran on a fresh view and process")
        #expect(output.png != nil)
        #expect(queuedFor < 20)
        #expect(renderer.queueDepth == 0)
    }

    @Test func endlessLoopAfterLoadFailsAtTheScriptLimit() async throws {
        let renderer = HTMLVisualRenderer(limits: Self.limits)
        defer { renderer.close() }
        // The page finishes loading, then its JavaScript thread is blocked for good: sizing never answers.
        let html = "<html><body>later<script>addEventListener('load', () => setTimeout(() => { while (true) {} }, 0));</script></body></html>"
        let (message, elapsed) = await expectFailure(renderer, html)
        print("HTML-LIMITS endless loop (after load): failed after \(String(format: "%.2f", elapsed)) s: \(message)")
        #expect(message.contains("Visual not rendered"), "\(message)")
        #expect(elapsed < 10)
        #expect(renderer.discardedViews == 1)
        let output = try await renderer.render(HTMLRenderRequest(html: Self.simple, width: 400))
        #expect(output.contentHeight >= 120)
    }

    @Test func pageThatNeverFinishesLoadingFailsAtTheLoadLimit() async throws {
        let silent = try SilentListener()
        let port = await silent.start()
        defer { silent.stop() }
        let renderer = HTMLVisualRenderer(limits: Self.limits)
        defer { renderer.close() }
        // An approved host on loopback that accepts and never answers: the image never loads, so neither does the page.
        let host = "127.0.0.1:\(port)"
        let html = "<html><body>waiting<img src=\"https://\(host)/never.png\"></body></html>"
        let (message, elapsed) = await expectFailure(renderer, html, hosts: [host])
        print("HTML-LIMITS never loads: failed after \(String(format: "%.2f", elapsed)) s (connections \(silent.accepted.withLock { $0 })): \(message)")
        #expect(message.contains("did not finish loading"), "\(message)")
        #expect(elapsed < 10)
        let output = try await renderer.render(HTMLRenderRequest(html: Self.simple, width: 400))
        #expect(output.contentHeight >= 120)
    }

    @Test func veryLargeDocumentEndsWithinItsLimitsAndDoesNotDelayTheNext() async throws {
        let renderer = HTMLVisualRenderer(limits: Self.limits)
        defer { renderer.close() }
        // About 2 MB (the tool's maximum): 40,000 table rows.
        var html = "<html><body><table>"
        for index in 0..<40_000 { html += "<tr><td>row \(index)</td><td>\(String(repeating: "x", count: 20))</td></tr>" }
        html += "</table></body></html>"
        let start = ContinuousClock.now
        let result: String
        do {
            let output = try await renderer.render(HTMLRenderRequest(html: html, width: 400))
            result = "rendered, height \(Int(output.contentHeight)), png \(output.png?.count ?? 0) bytes"
            #expect(output.contentHeight > 10_000)
        } catch {
            result = "failed: \(ExtrasError.message(error))"
            #expect(ExtrasError.message(error).contains("Visual not rendered"))
        }
        let elapsed = seconds(since: start)
        print("HTML-LIMITS large document (\(html.utf8.count) bytes): \(result) after \(String(format: "%.2f", elapsed)) s")
        // Load, sizing, snapshot and the recorder each have a limit: 1 + 1 + 3 + 1 s, plus WebKit start-up.
        #expect(elapsed < 20)
        let output = try await renderer.render(HTMLRenderRequest(html: Self.simple, width: 400))
        #expect(output.contentHeight >= 120)
    }

    @Test func queueIsBoundedAndAWaitingRenderCanBeCancelled() async throws {
        let renderer = HTMLVisualRenderer(limits: Self.limits)
        defer { renderer.close() }
        let stuck = Task { await expectFailure(renderer, "<script>while (true) {}</script>") }
        while renderer.queueDepth == 0 { await Task.yield() }
        let first = Task { try await renderer.render(HTMLRenderRequest(html: Self.simple, width: 400)) }
        let second = Task { try await renderer.render(HTMLRenderRequest(html: Self.simple, width: 400)) }
        while renderer.queueDepth < 3 { await Task.yield() }
        // The queue holds two waiting renders: a third is refused at once, without waiting for the stuck one.
        let start = ContinuousClock.now
        await #expect(throws: ExtrasError.self) { try await renderer.render(HTMLRenderRequest(html: Self.simple, width: 400)) }
        #expect(seconds(since: start) < 0.5)
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(renderer.queueDepth == 2)
        _ = await stuck.value
        let output = try await first.value
        #expect(output.contentHeight >= 120)
        #expect(renderer.queueDepth == 0)
    }

    @Test func deadlineReturnsAtTheLimitWhenWebKitNeverAnswers() async {
        let start = ContinuousClock.now
        await #expect(throws: HTMLVisualTimeout.self) {
            let _: Int = try await withWebKitDeadline(.script, limit: .milliseconds(100)) { _ in }
        }
        #expect(seconds(since: start) < 5)
        let late = Task { @MainActor in
            let _: Int = try await withWebKitDeadline(.script, limit: .seconds(60)) { _ in }
        }
        await Task.yield()
        late.cancel()
        await #expect(throws: CancellationError.self) { try await late.value }
    }
}
