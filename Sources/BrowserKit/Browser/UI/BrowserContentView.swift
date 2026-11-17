import AppKit
import DesignSystem

/// The page area: the selected tab's web view (or its snapshot while it is being restored), sized to fill the pane or
/// to a responsive preset (scaled down to fit, with a size label), the new-tab and failure states, and the agent's
/// overlays (element outline and cursor).
@MainActor
final class BrowserContentView: NSView {
    /// Hosts the web view; its bounds are the page's CSS viewport, its frame what fits on screen.
    private let viewportHost = BrowserFlippedView()
    private let snapshotView = NSImageView()
    private let highlight = BrowserHighlightView()
    private let cursor = AgentCursorView()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let empty = EmptyStateView(symbolName: "globe", title: "New Tab", detail: "Type an address or a search above, or ask the agent to open a page.")
    private let failure = EmptyStateView(symbolName: "exclamationmark.triangle", title: "Can’t open this page", detail: "", actionTitle: "Try Again", action: nil)
    private weak var mounted: BrowserWebView?
    private var tab: BrowserTab?
    private var cursorHide: Task<Void, Never>?
    var onRetry: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        viewportHost.wantsLayer = true
        snapshotView.imageScaling = .scaleAxesIndependently
        snapshotView.isHidden = true
        sizeLabel.font = DS.Typography.current.caption
        sizeLabel.textColor = DS.Palette.secondaryText
        sizeLabel.alignment = .center
        failure.button.target = self
        failure.button.action = #selector(retry)
        for view in [viewportHost, snapshotView, empty, failure, sizeLabel, highlight, cursor] as [NSView] { addSubview(view) }
        highlight.isHidden = true
        cursor.isHidden = true
        refreshBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override nonisolated var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBackground()
    }

    private func refreshBackground() {
        let viewportMode = tab?.viewport != nil
        layer?.backgroundColor = (viewportMode ? DS.Palette.groupFill : DS.Palette.contentBackground).cgColor
    }

    /// The size pages lay out at in fill mode (parked web views use it too).
    var contentSize: NSSize { bounds.size }

    func display(_ tab: BrowserTab?) {
        self.tab = tab
        let webView = tab?.webView
        if mounted !== webView {
            mounted?.removeFromSuperview()
            if let webView {
                webView.removeFromSuperview()
                webView.autoresizingMask = []
                viewportHost.addSubview(webView)
            }
            mounted = webView
        }
        let isBlank = tab.map { ($0.url ?? $0.pendingURL) == nil && !$0.isLoading } ?? true
        empty.isHidden = !isBlank || tab == nil
        if tab == nil {
            empty.isHidden = false
            empty.title.stringValue = "No Tabs"
            empty.detail.stringValue = "Open a tab with ⌥⌘T, or ask the agent to open a page. Tabs belong to this thread."
        } else {
            empty.title.stringValue = tab?.isPrivate == true ? "Private Tab" : "New Tab"
            empty.detail.stringValue = tab?.isPrivate == true
                ? "Nothing is saved, and the agent never sees this tab."
                : "Type an address or a search above, or ask the agent to open a page."
        }
        if let error = tab?.loadError, !(tab?.isLoading ?? false) {
            failure.isHidden = false
            failure.title.stringValue = tab?.crashed == true ? "This page stopped working" : "Can’t open this page"
            failure.detail.stringValue = error
            failure.button.title = tab?.crashed == true ? "Reload" : "Try Again"
        } else {
            failure.isHidden = true
        }
        viewportHost.isHidden = isBlank || !failure.isHidden
        if let snapshot = tab?.snapshot {
            snapshotView.image = snapshot
            snapshotView.isHidden = false
        } else {
            snapshotView.isHidden = true
        }
        refreshBackground()
        needsLayout = true
        updateOverlays()
    }

    override func layout() {
        super.layout()
        let area = bounds
        empty.frame = area
        failure.frame = area
        guard let tab else {
            viewportHost.frame = area
            return
        }
        if let preset = tab.viewport {
            let label: CGFloat = 22
            let available = NSSize(width: max(area.width - 24, 50), height: max(area.height - label - 16, 50))
            let page = NSSize(width: preset.width, height: preset.height)
            let scale = min(1, available.width / page.width, available.height / page.height)
            let fitted = NSSize(width: (page.width * scale).rounded(), height: (page.height * scale).rounded())
            let origin = NSPoint(x: ((area.width - fitted.width) / 2).rounded(), y: label + ((available.height - fitted.height) / 2).rounded() + 4)
            viewportHost.frame = NSRect(origin: origin, size: fitted)
            viewportHost.bounds = NSRect(origin: .zero, size: page)
            sizeLabel.isHidden = false
            let percent = Int((scale * 100).rounded())
            sizeLabel.stringValue = "\(preset.name) · \(preset.width) × \(preset.height) · \(preset.scale.formatted())× device (page sees the display's)\(percent < 100 ? " · \(percent)%" : "")"
            sizeLabel.frame = NSRect(x: 0, y: 4, width: area.width, height: 16)
            viewportHost.layer?.borderWidth = 1
            viewportHost.layer?.borderColor = DS.Palette.separator.cgColor
            viewportHost.layer?.cornerRadius = 0
        } else {
            viewportHost.frame = area
            viewportHost.bounds = NSRect(origin: .zero, size: area.size)
            viewportHost.layer?.borderWidth = 0
            sizeLabel.isHidden = true
        }
        mounted?.frame = viewportHost.bounds
        snapshotView.frame = viewportHost.frame
        updateOverlays()
    }

    /// Positions the agent's outline and cursor (web view coordinates → this view).
    func updateOverlays() {
        guard let tab, let webView = mounted, !viewportHost.isHidden else {
            highlight.isHidden = true
            cursor.isHidden = true
            return
        }
        if let set = tab.set, let highlightState = set.highlight, highlightState.tabID == tab.id, highlightState.until > Date() {
            highlight.frame = convert(highlightState.rect, from: webView).insetBy(dx: -3, dy: -3)
            highlight.isHidden = false
            let remaining = highlightState.until.timeIntervalSinceNow
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(remaining * 1000) + 30))
                self?.updateOverlays()
            }
        } else {
            highlight.isHidden = true
        }
        if let point = tab.agentCursor, let last = tab.lastAgentAction, Date().timeIntervalSince(last) < 4 || tab.agentActivity != nil {
            let location = convert(point, from: webView)
            cursor.place(at: location)
            cursor.isHidden = false
            cursorHide?.cancel()
            cursorHide = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.cursor.isHidden = true
            }
        } else if tab.agentActivity == nil {
            cursor.isHidden = true
        }
    }

    @objc private func retry() { onRetry?() }
}

/// The outline around the element the agent acts on.
final class BrowserHighlightView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The agent's pointer: an arrow with an "Agent" tag where it last clicked. It jumps (no travel animation) and shows a
/// short ring pulse unless Reduce Motion is on.
@MainActor
final class AgentCursorView: NSView {
    private let arrow = NSImageView()
    private let badge = NSTextField(labelWithString: "Agent")
    private let ring = CALayer()

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 80, height: 44))
        wantsLayer = true
        arrow.image = NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: "Agent pointer")?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .bold).applying(.init(paletteColors: [.white])))
        arrow.frame = NSRect(x: 0, y: 0, width: 22, height: 26)
        arrow.shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 3
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            return shadow
        }()
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .white
        badge.drawsBackground = true
        badge.backgroundColor = .controlAccentColor
        badge.isBordered = false
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.masksToBounds = true
        badge.frame = NSRect(x: 18, y: 20, width: 40, height: 16)
        badge.alignment = .center
        ring.borderColor = NSColor.controlAccentColor.cgColor
        ring.borderWidth = 2
        ring.frame = CGRect(x: -10, y: -10, width: 20, height: 20)
        ring.cornerRadius = 10
        ring.opacity = 0
        layer?.addSublayer(ring)
        addSubview(arrow)
        addSubview(badge)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Agent pointer")
    }

    required init?(coder: NSCoder) { nil }

    override nonisolated var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func place(at point: NSPoint) {
        frame.origin = NSPoint(x: point.x - 4, y: point.y - 2)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.6
        pulse.toValue = 1.8
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [pulse, fade]
        group.duration = 0.45
        ring.add(group, forKey: "pulse")
    }
}
