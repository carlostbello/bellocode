import AppKit
import BelloCore
import BrowserKit
import DesignSystem
import Engine
import SwiftUI
import WebKit

/// The "Chrome" right-panel tab and its detachable window (docs/features/shared-browser.md "Live view and takeover"):
/// the shared Chromium's desktop over noVNC in a WKWebView, connected only while visible, view-only until Take Over;
/// an overlay naming which thread is driving; a thread/tab-group switcher; downloads and explicit clipboard paste.
@MainActor
final class SharedChromeSurfaces {
    private let host = NSViewController()
    private(set) var pane: SharedChromePaneController?
    private(set) var context: ThreadSurfaceContext?
    private var window: NSWindowController?
    private var proxyLoop: ObservationLoop?
    /// Snapshot scenarios render a still image in place of the live stream (no container needed).
    var snapshotStream: NSImage?

    init() { host.view = NSView() }

    func makePanelController() -> NSViewController { host }

    func bind(engine: Engine) {
        guard pane == nil, let service = engine.sharedBrowser else { return }
        let pane = SharedChromePaneController(service: service, detached: false)
        pane.onOpenWindow = { [weak self] in self?.openWindow() }
        pane.snapshotStream = snapshotStream
        host.addChild(pane)
        pane.view.frame = host.view.bounds
        pane.view.autoresizingMask = [.width, .height]
        host.view.addSubview(pane.view)
        self.pane = pane
        // The built-in preview reaches the same canonical `*.bc` URLs through the shared browser's proxy front.
        proxyLoop = ObservationLoop {
            let endpoint = service.previewProxy
            CanonicalPreviewProxy.set(endpoint.map {
                CanonicalPreviewProxy.Endpoint(port: $0.port, username: $0.username, password: $0.password, authorityDER: $0.authorityDER)
            })
        }
        display(context)
    }

    func display(_ context: ThreadSurfaceContext?) {
        self.context = context
        pane?.display(context)
        (window?.contentViewController as? SharedChromePaneController)?.display(context)
    }

    /// The optional detachable window (its own viewer; the panel's disconnects while hidden).
    func openWindow() {
        if let window { window.showWindow(nil); return }
        guard let service = context?.engine.sharedBrowser ?? pane?.service else { return }
        let content = SharedChromePaneController(service: service, detached: true)
        content.display(context)
        let window = NSWindow(contentViewController: content)
        window.title = "Shared Chrome"
        window.setContentSize(NSSize(width: 1024, height: 720))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BelloCodeSharedChromeWindow")
        let controller = NSWindowController(window: window)
        self.window = controller
        controller.showWindow(nil)
    }
}

/// Observable state the SwiftUI parts read (selection, connection, errors).
@MainActor
final class SharedChromePaneState: ObservableObject {
    @Published var selectedSession: String?
    @Published var connected = false
    @Published var connectMilliseconds: Int?
    @Published var viewerError: String?
    @Published var context: ThreadSurfaceContext?
    @Published var confirmingStop = false
}

@MainActor
final class SharedChromePaneController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate {
    let service: SharedBrowserService
    let detached: Bool
    let state = SharedChromePaneState()
    var onOpenWindow: (() -> Void)?
    var snapshotStream: NSImage? { didSet { applySnapshotStream() } }
    private var webView: WKWebView?
    private let streamHost = NSView()
    private var stillView: NSImageView?
    private var toolbar: NSHostingController<SharedChromeToolbar>!
    private var overlay: NSHostingController<SharedChromeOverlay>!
    private var placeholder: NSHostingController<SharedChromePlaceholder>!
    private var visible = false
    private var loop: ObservationLoop?
    private var occlusion: (any NSObjectProtocol)?
    private var loadedURL: URL?

    init(service: SharedBrowserService, detached: Bool) {
        self.service = service
        self.detached = detached
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = DS.Color.canvas.cgColor
        toolbar = NSHostingController(rootView: SharedChromeToolbar(service: service, state: state, detached: detached, actions: actions))
        toolbar.sizingOptions = [.intrinsicContentSize]
        // The panel's width wins: the toolbar truncates its text instead of widening (and clipping) the pane.
        toolbar.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbar.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        overlay = NSHostingController(rootView: SharedChromeOverlay(service: service, state: state))
        overlay.sizingOptions = [.intrinsicContentSize]
        placeholder = NSHostingController(rootView: SharedChromePlaceholder(service: service, state: state, actions: actions))
        placeholder.sizingOptions = []
        for child in [toolbar!, placeholder!] as [NSViewController] { addChild(child) }
        addChild(overlay)
        streamHost.wantsLayer = true
        streamHost.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        for view in [toolbar.view, streamHost, placeholder.view, overlay.view] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.view.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            streamHost.topAnchor.constraint(equalTo: toolbar.view.bottomAnchor),
            streamHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            streamHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            streamHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            placeholder.view.topAnchor.constraint(equalTo: streamHost.topAnchor),
            placeholder.view.leadingAnchor.constraint(equalTo: streamHost.leadingAnchor),
            placeholder.view.trailingAnchor.constraint(equalTo: streamHost.trailingAnchor),
            placeholder.view.bottomAnchor.constraint(equalTo: streamHost.bottomAnchor),
            overlay.view.leadingAnchor.constraint(equalTo: streamHost.leadingAnchor, constant: DS.Space.s8),
            overlay.view.trailingAnchor.constraint(lessThanOrEqualTo: streamHost.trailingAnchor, constant: -DS.Space.s8),
            overlay.view.bottomAnchor.constraint(equalTo: streamHost.bottomAnchor, constant: -DS.Space.s8),
        ])
        view = root
        applySnapshotStream()
    }

    private var actions: SharedChromeActions {
        SharedChromeActions(
            takeOver: { [weak self] scope in self?.takeOver(scope) },
            giveBack: { [weak self] in self?.giveBack() },
            paste: { [weak self] in self?.pasteClipboard() },
            start: { [weak self] in Task { await self?.service.startBrowser() } },
            openWindow: { [weak self] in self?.onOpenWindow?() },
            exportDownload: { [weak self] name in self?.export(name) },
            refresh: { [weak self] in Task { await self?.service.refreshStatus() } })
    }

    func display(_ context: ThreadSurfaceContext?) {
        state.context = context
        state.selectedSession = context?.thread?.sessionID.rawValue
    }

    // MARK: Visibility: connect only while shown

    override func viewDidAppear() {
        super.viewDidAppear()
        occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: view.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
        updateVisibility()
        loop = ObservationLoop { [weak self] in self?.follow() }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        loop?.cancel()
        loop = nil
        setVisible(false)
    }

    private func updateVisibility() {
        let shown = view.window?.occlusionState.contains(.visible) ?? false
        setVisible(shown && view.window != nil && snapshotStream == nil)
    }

    private func setVisible(_ shown: Bool) {
        guard shown != visible else { return }
        visible = shown
        if shown {
            Task { await service.viewerAppeared() }
        } else {
            disconnect()
            Task { await service.viewerDisappeared() }
        }
    }

    /// Follows the service: loads the viewer page once the forward exists, shows the stream only when ready.
    private func follow() {
        let ready = service.phase.isReady && (service.viewerURL != nil || snapshotStream != nil)
        placeholder.view.isHidden = ready
        overlay.view.isHidden = !ready
        if visible, let url = service.viewerURL, url != loadedURL { load(url) }
        if service.viewerURL == nil, loadedURL != nil { disconnect() }
    }

    private func makeWebView() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        // A separate, non-persistent store: nothing of the viewer is written to disk or shared with the preview.
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(WeakScriptHandler(self), name: "bellocode")
        let webView = WKWebView(frame: streamHost.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.setAccessibilityLabel("Shared Chrome live view")
        streamHost.addSubview(webView)
        self.webView = webView
        return webView
    }

    private func load(_ url: URL) {
        loadedURL = url
        state.connected = false
        makeWebView().load(URLRequest(url: url))
    }

    private func disconnect() {
        webView?.evaluateJavaScript("window.bellocodeDisconnect && window.bellocodeDisconnect()")
        webView?.removeFromSuperview()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "bellocode")
        webView = nil
        loadedURL = nil
        state.connected = false
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // WebKit delivers script messages on the main thread; `body` is main-actor isolated, so it is read inside.
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], let event = body["event"] as? String else { return }
            handle(event: event, ms: body["ms"] as? Int, text: body["text"] as? String, reason: body["reason"] as? String)
        }
    }

    private func handle(event: String, ms: Int?, text: String?, reason: String?) {
        switch event {
        case "ready":
            Task {
                guard let password = await service.viewerPassword else { return }
                let viewOnly = service.humanControl.isEmpty
                let compact = service.settings.compactDisplay
                // The password reaches the page through a call, never a URL.
                let script = "window.bellocodeConnect(\(Self.jsString(password)), {viewOnly: \(viewOnly), quality: \(compact ? 5 : 6), compression: 2})"
                _ = try? await webView?.evaluateJavaScript(script)
            }
        case "connect":
            state.connected = true
            state.connectMilliseconds = ms
            state.viewerError = nil
        case "disconnect":
            state.connected = false
        case "securityfailure":
            state.viewerError = "The live view could not authenticate (\(reason ?? "unknown")). Restart the shared Chrome."
        case "clipboard":
            // Copied in Chrome while the person had control: offered to the Mac only then (explicit, per the spike).
            if !service.humanControl.isEmpty, let text {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        default: break
        }
    }

    static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }

    // MARK: Take Over

    func takeOver(_ scope: String) {
        Task {
            await service.takeOver(scope)
            _ = try? await webView?.evaluateJavaScript("window.bellocodeSetViewOnly(false); window.bellocodeFocus()")
        }
    }

    func giveBack() {
        Task {
            _ = try? await webView?.evaluateJavaScript("window.bellocodeSetViewOnly(true)")
            await service.giveBack("*")
        }
    }

    /// Sends the Mac clipboard's text to Chrome's clipboard (explicit; only with control).
    func pasteClipboard() {
        guard !service.humanControl.isEmpty, let text = NSPasteboard.general.string(forType: .string) else { return }
        webView?.evaluateJavaScript("window.bellocodePaste(\(Self.jsString(String(text.prefix(100_000)))))")
    }

    func export(_ name: String) {
        Task {
            let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(filePath: NSHomeDirectory())
            do {
                let url = try await service.exportDownload(name, to: folder)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                state.viewerError = "Could not save \(name): \(error.localizedDescription)"
            }
        }
    }

    private func applySnapshotStream() {
        guard isViewLoaded else { return }
        stillView?.removeFromSuperview()
        guard let snapshotStream else { return }
        let image = NSImageView(image: snapshotStream)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.frame = streamHost.bounds
        image.autoresizingMask = [.width, .height]
        streamHost.addSubview(image)
        stillView = image
        placeholder.view.isHidden = true
        overlay.view.isHidden = false
    }
}

/// Breaks the retain cycle between the content controller and the pane.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

struct SharedChromeActions {
    var takeOver: (String) -> Void
    var giveBack: () -> Void
    var paste: () -> Void
    var start: () -> Void
    var openWindow: () -> Void
    var exportDownload: (String) -> Void
    var refresh: () -> Void
}

// MARK: - SwiftUI parts

/// Status words with a glyph (never colour only).
struct SharedChromeStatusPill: View {
    let phase: BrowserPhase

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: DS.Size.iconPointMeta))
            Text(phase.title).font(.ds(.metaEmph))
        }
        .foregroundStyle(color)
        .padding(.horizontal, DS.Space.s6)
        .padding(.vertical, 2)
        .background(Capsule().fill(surface))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shared Chrome: \(phase.title)")
    }

    private var symbol: String {
        switch phase {
        case .ready: "checkmark.circle.fill"
        case .stopped: "pause.circle"
        case .preparingImage, .starting, .stopping, .recovering: "arrow.triangle.2.circlepath"
        case .failed: "xmark.octagon.fill"
        case .sandboxUnavailable: "exclamationmark.shield.fill"
        case .stopUnconfirmed: "exclamationmark.triangle.fill"
        }
    }

    private var color: SwiftUI.Color {
        switch phase {
        case .ready: .ds.successText
        case .failed, .sandboxUnavailable: .ds.dangerText
        case .recovering, .stopUnconfirmed: .ds.warningText
        default: .ds.text3
        }
    }

    private var surface: SwiftUI.Color {
        switch phase {
        case .ready: .ds.successSurface
        case .failed, .sandboxUnavailable: .ds.dangerSurface
        case .recovering, .stopUnconfirmed: .ds.warningSurface
        default: .ds.fillSubtle
        }
    }
}

struct SharedChromeToolbar: View {
    let service: SharedBrowserService
    @ObservedObject var state: SharedChromePaneState
    let detached: Bool
    let actions: SharedChromeActions

    private var controlled: Bool { !service.humanControl.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ViewThatFits(in: .horizontal) {
                controlsRow(showsTitle: true)
                controlsRow(showsTitle: false)
            }
            HStack(spacing: DS.Space.s6) {
                groupPicker
                Spacer(minLength: 0)
            }
            contextLine
            if let notice = service.notices.first, Date.now.timeIntervalSince(notice.date) < 900 {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(SwiftUI.Color.ds.warningText)
                    Text(notice.text).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text2).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
            if let error = state.viewerError ?? service.lastError {
                Text(error).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.dangerText).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.s12)
        .padding(.vertical, DS.Space.s6)
        .background(SwiftUI.Color.ds.canvas)
        .overlay(alignment: .bottom) { SwiftUI.Color.ds.border.frame(height: 1) }
        .transaction { $0.animation = nil }
    }

    /// Title, status and the controls; the title drops first when the panel is narrow.
    private func controlsRow(showsTitle: Bool) -> some View {
            HStack(spacing: DS.Space.s6) {
                Image(systemName: "globe").foregroundStyle(SwiftUI.Color.ds.icon).accessibilityLabel("Shared Chrome")
                if showsTitle {
                    Text("Shared Chrome").font(.ds(.bodyEmph)).foregroundStyle(SwiftUI.Color.ds.text).lineLimit(1).fixedSize()
                }
                SharedChromeStatusPill(phase: service.phase).fixedSize()
                Spacer(minLength: DS.Space.s4)
                if controlled {
                    Button { actions.paste() } label: { Image(systemName: "doc.on.clipboard") }
                        .buttonStyle(DSButtonStyle(.ghost, size: .small))
                        .fixedSize()
                        .help("Paste: send the Mac clipboard's text to Chrome")
                        .accessibilityLabel("Paste into Chrome")
                    Button { actions.giveBack() } label: { Label("Give Back", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(DSButtonStyle(.primary, size: .small))
                        .fixedSize()
                        .help("Return control to the agents")
                } else {
                    Menu {
                        Button("Whole Browser") { actions.takeOver("*") }
                        if let tab = selectedTab { Button("This Thread's Tab (\(tab))") { actions.takeOver(tab) } }
                    } label: {
                        Label("Take Over", systemImage: "hand.raised")
                    } primaryAction: {
                        actions.takeOver("*")
                    }
                    .menuStyle(.button)
                    .buttonStyle(DSButtonStyle(.outline, size: .small))
                    .fixedSize()
                    .disabled(!service.phase.isReady)
                    .help("Pause agent input and use the browser yourself")
                }
                downloadsMenu
                if !detached {
                    Button { actions.openWindow() } label: { Image(systemName: "macwindow.on.rectangle") }
                        .buttonStyle(DSButtonStyle(.ghost, size: .small))
                        .fixedSize()
                        .help("Open Shared Chrome in a Window")
                        .accessibilityLabel("Open in Window")
                }
            }
    }

    private var selectedTab: String? { state.selectedSession.flatMap { service.bindings[$0]?.selectedTab } }

    /// Project › thread, worktree folder and the canonical URL (UX rule 6); truncates rather than clips.
    private var contextLine: some View {
        let context = state.context
        let thread = context?.thread?.session?.displayTitle ?? (context == nil ? "No thread shown" : "New thread")
        let folder = context.map { URL(filePath: $0.directory).lastPathComponent } ?? ""
        let label = context.flatMap { service.labels[$0.projectDirectory] }
        var parts = ["\(context?.projectName ?? "No project") › \(thread)"]
        if !folder.isEmpty { parts.append(folder) }
        if let label { parts.append("https://\(label).bc:<port>/") }
        return Text(parts.joined(separator: " · "))
            .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(parts.joined(separator: "\n"))
    }

    private var groupPicker: some View {
        let bindings = service.bindings.values.sorted { $0.created > $1.created }.prefix(30)
        return Menu {
            if bindings.isEmpty { Text("No thread has used the shared Chrome yet") }
            ForEach(Array(bindings), id: \.sessionID) { binding in
                Button {
                    state.selectedSession = binding.sessionID
                } label: {
                    let title = service.threadTitle(session: binding.sessionID)
                    Text("\(title) — \(binding.group) (\(binding.tabs.count) tab\(binding.tabs.count == 1 ? "" : "s"))")
                }
            }
        } label: {
            let title = state.selectedSession.map { service.threadTitle(session: $0) } ?? "Tab groups"
            Label(title, systemImage: "rectangle.stack").lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(DSButtonStyle(.ghost, size: .small))
        .fixedSize()
        .help("Each thread works in its own tab group")
        .accessibilityLabel("Tab group by thread")
    }

    private var downloadsMenu: some View {
        Menu {
            if service.downloads.isEmpty { Text("No downloads") }
            ForEach(service.downloads.prefix(20)) { download in
                Button("Save “\(download.name)” to Downloads (\(ByteCountFormatter.string(fromByteCount: download.bytes, countStyle: .file)))") {
                    actions.exportDownload(download.name)
                }
            }
            Divider()
            Button("Refresh") { actions.refresh() }
        } label: {
            Image(systemName: "arrow.down.circle")
        }
        .menuStyle(.button)
        .buttonStyle(DSButtonStyle(.ghost, size: .small))
        .fixedSize()
        .help("Downloads in the shared Chrome")
        .accessibilityLabel("Downloads")
    }
}

/// Who is driving: names the thread running a call (and on which tab), the person's control, or view-only.
struct SharedChromeOverlay: View {
    let service: SharedBrowserService
    @ObservedObject var state: SharedChromePaneState

    var body: some View {
        HStack(spacing: DS.Space.s6) {
            Image(systemName: symbol).font(.system(size: DS.Size.iconPointMeta))
            Text(text).font(.ds(.metaEmph)).lineLimit(1)
        }
        .foregroundStyle(SwiftUI.Color.white)
        .padding(.horizontal, DS.Space.s8)
        .padding(.vertical, DS.Space.s4)
        .background(Capsule().fill(SwiftUI.Color.black.opacity(0.72)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
        .transaction { $0.animation = nil }
    }

    private var controlled: Bool { !service.humanControl.isEmpty }

    private var running: (tab: String, thread: String)? {
        service.tabActivity.sorted { $0.key < $1.key }.compactMap { key, value in value.running.map { (key, $0) } }.first
    }

    private var symbol: String {
        if controlled { return "hand.raised.fill" }
        if !service.takingOver.isEmpty { return "hourglass" }
        if running != nil { return "cursorarrow.motionlines" }
        return "eye"
    }

    private var text: String {
        if !service.takingOver.isEmpty, !controlled { return "Taking over · stopping agent calls first" }
        if controlled {
            return service.humanControl.contains("*") ? "You have control · agents paused" : "You control \(service.humanControl.sorted().joined(separator: ", ")) · its agent is paused"
        }
        if let running { return "Driving: \(running.thread) · \(running.tab)" }
        if let last = service.tabActivity.values.compactMap(\.lastUsedBy).first { return "View only · last used by \(last)" }
        return "View only · Take Over to interact"
    }
}

/// Every state other than a running stream: empty, starting/building, stopped, failed, sandbox unavailable.
struct SharedChromePlaceholder: View {
    let service: SharedBrowserService
    @ObservedObject var state: SharedChromePaneState
    let actions: SharedChromeActions

    var body: some View {
        VStack(spacing: DS.Space.s8) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(SwiftUI.Color.ds.icon)
            Text(title).font(.ds(.bodyEmph)).foregroundStyle(SwiftUI.Color.ds.text)
            Text(detail).font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3).multilineTextAlignment(.center).frame(maxWidth: 380)
            if showsStart {
                Button("Start Shared Chrome") { actions.start() }.buttonStyle(DSButtonStyle(.outline, size: .small))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.s16)
        .background(SwiftUI.Color.ds.canvas)
        .transaction { $0.animation = nil }
    }

    private var showsStart: Bool {
        switch service.phase {
        case .stopped, .failed: service.isAvailable
        default: false
        }
    }

    private var symbol: String {
        switch service.phase {
        case .sandboxUnavailable: "exclamationmark.shield"
        case .failed: "xmark.octagon"
        case .preparingImage, .starting, .recovering, .stopping: "hourglass"
        default: "globe"
        }
    }

    private var title: String {
        guard service.isAvailable else { return "Shared Chrome needs containers" }
        switch service.phase {
        case .stopped: return "Shared Chrome is stopped"
        case .preparingImage: return "Preparing the browser image"
        case .starting: return "Starting the shared Chrome"
        case .ready: return "Connecting the live view"
        case .stopping(let reason): return "Stopping (\(reason))"
        case .recovering(let detail): return "Restarting: \(detail)"
        case .failed: return "The shared Chrome could not start"
        case .sandboxUnavailable: return "Chromium's sandbox is unavailable"
        case .stopUnconfirmed: return "The shared Chrome may still be running"
        }
    }

    private var detail: String {
        guard service.isAvailable else { return "Turn on container execution with Rancher Desktop to use one shared Chromium for every thread." }
        switch service.phase {
        case .stopped:
            return "One Chromium in a container for every thread, with your sign-ins kept. It starts on first use or here, and stops after \(service.settings.idleMinutes) idle minutes."
        case .preparingImage(let line): return line
        case .starting, .ready: return "Usually under a second once the image exists."
        case .stopping: return "Chrome is closing its profile so sign-ins are saved."
        case .recovering: return "Threads that were using it are told; their tabs need to be opened again."
        case .failed(let message): return message
        case .sandboxUnavailable: return BrowserStartError.sandboxUnavailable.description + " See Settings ▸ Browser."
        case .stopUnconfirmed(let message): return message
        }
    }
}

// MARK: - Menu (Browser ▸ Shared Chrome)

/// Menu items for the shared Chrome, appended to the Browser menu: every action has a menu item (UX rule 2).
@MainActor
enum SharedChromeMenu {
    enum Command: String, CaseIterable {
        case show, openWindow, takeOver, giveBack, start, stop

        var title: String {
            switch self {
            case .show: "Show Shared Chrome"
            case .openWindow: "Open Shared Chrome in Window"
            case .takeOver: "Take Over Shared Chrome"
            case .giveBack: "Give Shared Chrome Back to Agents"
            case .start: "Start Shared Chrome"
            case .stop: "Stop Shared Chrome"
            }
        }
    }

    static func append(to menu: NSMenu) {
        menu.addItem(.separator())
        for command in Command.allCases {
            let item = NSMenuItem(title: command.title, action: #selector(SharedChromeMenuRouter.perform(_:)), keyEquivalent: command == .show ? "b" : "")
            if command == .show { item.keyEquivalentModifierMask = [.command, .control, .option] }
            item.representedObject = command.rawValue
            item.target = SharedChromeMenuRouter.shared
            menu.addItem(item)
        }
    }
}

@MainActor
final class SharedChromeMenuRouter: NSObject, NSMenuItemValidation {
    static let shared = SharedChromeMenuRouter()

    private var window: MainWindowController? {
        ((NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? MainWindowController)
            ?? NSApp.windows.compactMap { $0.windowController as? MainWindowController }.first
    }

    private var service: SharedBrowserService? { window?.workspace.engine.sharedBrowser }

    @objc func perform(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = SharedChromeMenu.Command(rawValue: raw) else { return }
        switch command {
        case .show: window?.showSharedChromePanel()
        case .openWindow: window?.sharedChrome?.openWindow()
        case .takeOver:
            window?.showSharedChromePanel()
            window?.sharedChrome?.pane?.takeOver("*")
        case .giveBack: window?.sharedChrome?.pane?.giveBack()
        case .start: Task { await service?.startBrowser() }
        case .stop: Task { await service?.stopBrowser() }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let raw = menuItem.representedObject as? String, let command = SharedChromeMenu.Command(rawValue: raw), let service else { return false }
        switch command {
        case .show, .openWindow: return service.isAvailable
        case .takeOver: return service.phase.isReady && service.humanControl.isEmpty
        case .giveBack: return !service.humanControl.isEmpty
        case .start: return service.isAvailable && !service.phase.isReady
        case .stop: return service.phase.isReady || service.phase.isStopUnconfirmed
        }
    }
}
