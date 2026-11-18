import AppKit
import BrowserKit
import Engine
import ImageIO
import TranscriptKit
import UniformTypeIdentifiers

// HTML visuals in the transcript (docs/features/orchestration-extras.md). The transcript draws each visual as a cached
// snapshot image (`VisualImageLoader`), so off-screen visuals cost a bitmap and the transcript stays virtualised. A
// click makes a visual live: `VisualOverlay` lays a sandboxed web view over it, at most `maxLive` per transcript, and
// drops it when it scrolls away. Title-line actions: Open in Browser (the built-in browser, as a data: URL carrying the
// same CSP) and Save Image.

/// Loads `bellocode-visual://<id>?scheme=light|dark` from the visual service; everything else as usual.
struct VisualImageLoader: TranscriptImageLoading {
    let snapshot: @MainActor @Sendable (String, Bool) async -> Data?
    let fallback = DefaultImageLoader()

    func load(_ source: String) async -> LoadedImage? {
        guard source.hasPrefix(VisualCardContent.scheme + "://"), let components = URLComponents(string: source), let id = components.host
        else { return await fallback.load(source) }
        let dark = components.queryItems?.first { $0.name == "scheme" }?.value == "dark"
        guard let data = await snapshot(id, dark), let image = Self.decode(data) else { return nil }
        return image
    }

    static func decode(_ data: Data) -> LoadedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return LoadedImage(image: image, pixelSize: CGSize(width: image.width, height: image.height))
    }
}

/// Live, interactive visuals laid over their transcript rows (bounded; snapshots elsewhere).
@MainActor
final class VisualOverlay {
    static let maxLive = 2

    private let controller: TranscriptController
    private let visuals: VisualService
    private var live: [String: HTMLVisualWebView] = [:]
    private var order: [String] = []
    private var observers: [any NSObjectProtocol] = []
    private var revisionLoop: ObservationLoop?
    private var lastRevision = -1
    var openExternally: (URL) -> Void = { NSWorkspace.shared.open($0) }

    init(controller: TranscriptController, visuals: VisualService) {
        self.controller = controller
        self.visuals = visuals
        let center = NotificationCenter.default
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            observers.append(
                center.addObserver(forName: name, object: controller.scrollView.contentView, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reposition() }
                })
        }
        revisionLoop = ObservationLoop { [weak self] in
            guard let self else { return }
            let revision = self.visuals.revision
            if revision != self.lastRevision {
                self.lastRevision = revision
                self.reloadAll()
            }
        }
    }

    isolated deinit {
        revisionLoop?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for view in live.values { view.discard() }
    }

    /// Makes a visual live (the person clicked it). The oldest live one returns to its snapshot beyond `maxLive`.
    func focus(_ id: String) {
        guard live[id] == nil, let html = visuals.html(id) else {
            if let view = live[id] { controller.tableView.window?.makeFirstResponder(view.webView) }
            return
        }
        let sandbox = HTMLVisualWebView()
        sandbox.openExternally = { [weak self] url in self?.openExternally(url) }
        live[id] = sandbox
        order.append(id)
        while order.count > Self.maxLive { drop(order.removeFirst()) }
        controller.tableView.addSubview(sandbox.webView)
        reposition()
        let dark = controller.tableView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let hosts = visuals.allowedHosts(id)
        Task { @MainActor [weak self, weak sandbox] in
            await sandbox?.load(html, theme: .for(dark: dark), allowedHosts: hosts)
            guard let self, let sandbox, self.live[id] === sandbox else { return }
            self.controller.tableView.window?.makeFirstResponder(sandbox.webView)
        }
    }

    /// Keeps live views on their rows; a visual that left the screen goes back to its snapshot.
    func reposition() {
        guard !live.isEmpty else { return }
        let frames = Dictionary(controller.visibleVisualFrames().map { ($0.visualID, $0.frame) }, uniquingKeysWith: { first, _ in first })
        for (id, view) in live {
            if let frame = frames[id] {
                if view.webView.frame != frame { view.webView.frame = frame }
            } else {
                drop(id)
            }
        }
    }

    private func drop(_ id: String) {
        // Discard, not only remove: a visual looping in a script keeps its content process spinning otherwise.
        live[id]?.discard()
        live[id] = nil
        order.removeAll { $0 == id }
    }

    private func reloadAll() {
        for id in Array(live.keys) {
            drop(id)
            focus(id)
        }
    }

    var liveCount: Int { live.count }
}

/// The title-line actions of a visual (`bellocode-visual-action://<verb>/<id>`).
@MainActor
enum VisualActions {
    static func handle(
        _ url: URL, visuals: VisualService, overlay: VisualOverlay?, dark: Bool, openInBrowser: (URL) -> Bool, window: NSWindow?
    ) -> Bool {
        guard url.scheme == VisualCardContent.actionScheme, let verb = url.host else { return false }
        let id = url.lastPathComponent
        guard !id.isEmpty, id != "/" else { return true }
        switch verb {
        case "focus":
            overlay?.focus(id)
        case "open":
            guard let html = visuals.html(id) else { return true }
            let page = HTMLVisualDocument.compose(html, theme: .for(dark: dark), allowedHosts: visuals.allowedHosts(id))
            if let data = URL(string: "data:text/html;charset=utf-8;base64," + Data(page.utf8).base64EncodedString()), !openInBrowser(data) {
                NSSound.beep()
            }
        case "save":
            Task { @MainActor in
                guard let file = await visuals.exportPNG(id, dark: dark) else { return }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = (visuals.record(id)?.title ?? "Visual") + ".png"
                let save: (NSApplication.ModalResponse) -> Void = { response in
                    guard response == .OK, let target = panel.url else { return }
                    try? FileManager.default.removeItem(at: target)
                    try? FileManager.default.copyItem(at: file, to: target)
                }
                if let window { panel.beginSheetModal(for: window, completionHandler: save) } else { save(panel.runModal()) }
            }
        default:
            break
        }
        return true
    }
}
