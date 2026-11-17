import AppKit
import DesignSystem
import Engine
import SwiftUI

/// The blocked-command banner (docs/features/containers.md) for one project, shown above a thread's composer and over
/// the terminal drawer: "Start Rancher Desktop", "Switch the container engine to dockerd", "Choose an image", "Sign in
/// to the registry", with Retry. Collapses to nothing while commands can run. The agent sees the same message as a tool
/// failure (bellocode-exec), so a blocked command is never silent.
@MainActor
final class EnvironmentBannerHost: NSView {
    private let engine: Engine
    private let directory: () -> String?
    private var hosting: NSHostingView<AnyView>?
    private var collapsed: NSLayoutConstraint!
    private var loop: ObservationLoop?
    /// Opens Settings on a pane ("containers", "environment").
    var openSettings: (String) -> Void = { pane in
        (NSApp.delegate as? AppDelegate)?.openSettings(pane: pane)
    }

    init(engine: Engine, directory: @escaping () -> String?) {
        self.engine = engine
        self.directory = directory
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        collapsed = heightAnchor.constraint(equalToConstant: 0)
        setAccessibilityElement(false)
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { loop?.cancel() }

    var isShowing: Bool { notice != nil }

    private var notice: (EnvironmentNotice, ProjectEnvironment)? {
        let service = engine.environments
        guard service.isEnabled, let directory = directory(), let environment = service.project(containing: directory) else { return nil }
        return environment.notice.map { ($0, environment) }
    }

    private func render() {
        guard let (notice, environment) = notice else {
            hosting?.removeFromSuperview()
            hosting = nil
            isHidden = true
            collapsed.isActive = true
            return
        }
        let progress: Double? = if case .pulling(let value) = environment.phase { value.fraction } else { nil }
        let service = engine.environments
        let open = openSettings
        let directory = environment.directory
        let view = AnyView(EnvironmentBannerView(
            notice: notice, progress: progress,
            fix: { fix in
                EnvironmentSettingsModel.preferredDirectory = directory
                EnvironmentFixes.perform(fix, directory: directory, engine: self.engine, openSettings: open)
            },
            retry: { Task { await service.retry(directory) } }
        ).padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s4))
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
                hosting.topAnchor.constraint(equalTo: topAnchor),
                hosting.bottomAnchor.constraint(equalTo: bottomAnchor).withPriority(.defaultHigh),
            ])
            self.hosting = hosting
        }
        isHidden = false
        collapsed.isActive = false
    }
}

/// Above the terminals: "Container · <image>" (glyph + text) while terminals open in the project's container, or the
/// blocked banner when they cannot.
@MainActor
final class TerminalEnvironmentStrip: NSView {
    private let engine: Engine
    private let directory: () -> String?
    private let banner: EnvironmentBannerHost
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let line = NSStackView()
    private var loop: ObservationLoop?

    init(engine: Engine, directory: @escaping () -> String?) {
        self.engine = engine
        self.directory = directory
        banner = EnvironmentBannerHost(engine: engine, directory: directory)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        glyph.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)
        glyph.contentTintColor = DS.Color.text3
        label.font = .ds(.meta)
        label.textColor = DS.Color.text3
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        line.setViews([glyph, label], in: .leading)
        line.spacing = DS.Space.s4
        line.edgeInsets = NSEdgeInsets(top: DS.Space.s2, left: DS.Space.s8, bottom: DS.Space.s2, right: DS.Space.s8)
        let stack = NSStackView(views: [banner, line])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            banner.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { loop?.cancel() }

    private func render() {
        let environment = directory().flatMap { engine.environments.project(containing: $0) }
        guard let environment, environment.notice == nil else {
            line.isHidden = true
            return
        }
        line.isHidden = false
        let text = "Container · \(environment.image ?? "no image") · \(environment.phase.label)"
        label.stringValue = text
        label.setAccessibilityLabel("Terminals run in the project's container: \(environment.image ?? "no image"), \(environment.phase.label)")
    }
}

/// The runtime status item in the toolbar: glyph + text ("Containers ready", "Containers: Not running"); a click opens
/// Settings ▸ Containers with the details and the fix. Hidden when container execution is off (mock mode).
@MainActor
final class RuntimeStatusButton: NSView {
    private let service: EnvironmentService
    private var hosting: NSHostingView<AnyView>?
    private var loop: ObservationLoop?

    init(service: EnvironmentService) {
        self.service = service
        super.init(frame: .zero)
        isHidden = !service.isEnabled
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { loop?.cancel() }

    private func render() {
        let runtime = service.runtime
        let isolation = service.isolation
        let view = AnyView(
            Button {
                (NSApp.delegate as? AppDelegate)?.showContainers(nil)
            } label: {
                RuntimeStatusLabel(runtime: runtime, enabled: service.isEnabled)
            }
            .buttonStyle(DSButtonStyle(.ghost, size: .small))
            .help(isolation.map { "Isolation: \($0.summary)" } ?? (runtime?.userMessage ?? "Checking Rancher Desktop"))
        )
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: leadingAnchor), hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
                hosting.topAnchor.constraint(equalTo: topAnchor), hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            self.hosting = hosting
        }
        setAccessibilityLabel(RuntimeStatusLabel(runtime: runtime, enabled: service.isEnabled).text)
    }
}
