// The demo window: one BrowserPaneController over a BrowserWorkspace with isolated (ephemeral) website data, plus
// helpers to run agent commands through the same host path the bridge uses, and to render the window to PNG with the
// web views' own snapshots composed in (cacheDisplay cannot see WebKit's remote layers).

import AppKit
import BelloCore
import OpenCodeKit
import WebKit

@testable import BrowserKit

@MainActor
final class Harness {
    let window: NSWindow
    let workspace: BrowserWorkspace
    let pane: BrowserPaneController
    let downloads: URL
    private(set) var set: BrowserTabSet

    init(workspace: BrowserWorkspace, set: BrowserTabSet, context: BrowserPaneContext, downloads: URL, size: NSSize = NSSize(width: 1100, height: 820)) {
        self.workspace = workspace
        self.set = set
        self.downloads = downloads
        pane = BrowserPaneController(workspace: workspace)
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "BelloCode browser"
        window.isReleasedWhenClosed = false
        window.contentViewController = pane
        window.setContentSize(size)
        pane.display(set, context: context)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func display(_ set: BrowserTabSet, context: BrowserPaneContext) {
        self.set = set
        pane.display(set, context: context)
    }

    // MARK: Agent commands (the bridge host path)

    @discardableResult
    func call(_ type: String, _ fields: [String: JSONValue] = [:], tabID: String? = nil, files: [BrowserFile] = [], generation: Int? = nil) async -> BrowserOutcome {
        var action = fields
        action["type"] = .string(type)
        if action["tabID"] == nil, let tabID { action["tabID"] = .string(tabID) }
        return await set.perform(BrowserCommand(action: .object(action), generation: generation, files: files))
    }

    func idle(_ milliseconds: Int = 60) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    // MARK: Rendering

    /// Renders the window (frame included) with every visible web view's snapshot composed at its place, then the
    /// agent overlays above them. Returns the PNG bytes.
    func renderPNG() async -> Data? {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let frameView = window.contentView?.superview,
              let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        var webViews: [BrowserWebView] = []
        var overlays: [NSView] = []
        func collect(_ view: NSView) {
            if let webView = view as? BrowserWebView, !webView.isHiddenOrHasHiddenAncestor, webView.window === window { webViews.append(webView) }
            if view is BrowserHighlightView || view is AgentCursorView, !view.isHiddenOrHasHiddenAncestor { overlays.append(view) }
            for child in view.subviews { collect(child) }
        }
        collect(frameView)
        var layers: [(NSImage, NSRect)] = []
        for webView in webViews {
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            guard let image = try? await webView.takeSnapshot(configuration: configuration) else { continue }
            layers.append((image, webView.convert(webView.bounds, to: frameView)))
        }
        for overlay in overlays {
            guard let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else { continue }
            overlay.cacheDisplay(in: overlay.bounds, to: rep)
            let image = NSImage(size: overlay.bounds.size)
            image.addRepresentation(rep)
            layers.append((image, overlay.convert(overlay.bounds, to: frameView)))
        }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // The bitmap is in the frame view's coordinates; convert flipped rects to bottom-left origin when needed.
        for (image, rect) in layers {
            var target = rect
            if frameView.isFlipped { target.origin.y = frameView.bounds.height - rect.maxY }
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: target).addClip()
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    func write(_ name: String, to directory: URL) async -> URL? {
        guard let data = await renderPNG() else { return nil }
        let url = directory.appending(path: "\(name).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

extension BrowserOutcome {
    var value: JSONValue? {
        if case .success(let result) = self { result.value } else { nil }
    }

    var failureCode: String? { failure?.code.rawValue }
}

infix operator &&& : LogicalConjunctionPrecedence
/// Non-short-circuiting `and`, so both sides may contain `await`.
func &&& (lhs: Bool, rhs: Bool) -> Bool { lhs && rhs }
