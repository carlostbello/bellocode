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

/// Above the terminals: "Container · <image> · <state>" (glyph + text) while terminals open in the project's
/// container, or the blocked banner when they cannot.
@MainActor
final class TerminalEnvironmentStrip: NSView {
    private let engine: Engine
    private let directory: () -> String?
    private var hosting: NSHostingView<AnyView>?
    private var loop: ObservationLoop?

    init(engine: Engine, directory: @escaping () -> String?) {
        self.engine = engine
        self.directory = directory
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    private func show(_ view: AnyView) {
        if let hosting {
            hosting.rootView = view
            return
        }
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor), hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor), hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.hosting = hosting
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { loop?.cancel() }

    /// The displayed thread changed: follow its project.
    func refresh() {
        loop?.cancel()
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    private func render() {
        let service = engine.environments
        guard let environment = directory().flatMap({ service.project(containing: $0) }) else {
            hosting?.removeFromSuperview()
            hosting = nil
            isHidden = true
            return
        }
        isHidden = false
        let engine = engine
        let directory = environment.directory
        if let notice = environment.notice {
            let progress: Double? = if case .pulling(let value) = environment.phase { value.fraction } else { nil }
            show(AnyView(EnvironmentBannerView(
                notice: notice, progress: progress,
                fix: { fix in
                    EnvironmentSettingsModel.preferredDirectory = directory
                    EnvironmentFixes.perform(fix, directory: directory, engine: engine, openSettings: { pane in
                        (NSApp.delegate as? AppDelegate)?.openSettings(pane: pane)
                    })
                },
                retry: { Task { await service.retry(directory) } }
            ).padding(.horizontal, DS.Space.s8).padding(.vertical, DS.Space.s4)))
        } else {
            let text = environment.mode == .hostDocker
                ? "Host docker only · terminals are not available in this mode"
                : "\(environment.mode == .sharedWorkspace ? "Shared workspace" : "Container") · \(environment.image ?? "no image") · \(environment.phase.label)"
            show(AnyView(
                HStack(spacing: DS.Space.s4) {
                    Image(systemName: environment.phase.symbolName).foregroundStyle(DSColor.text3).accessibilityHidden(true)
                    Text(text).font(.ds(.meta)).foregroundStyle(DSColor.text3).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Space.s8).frame(height: 22)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Terminals run in the project's container: \(environment.image ?? "no image"), \(environment.phase.label)")))
        }
    }
}

/// The runtime status item in the header bar: a ghost small button with glyph + word ("Containers ready",
/// "Containers: Not running"); a click opens Settings ▸ Containers with the details and the fix. AppKit (the header
/// places its items by frame). Hidden when container execution is off (mock mode).
@MainActor
final class RuntimeStatusButton: DSButton {
    private let service: EnvironmentService
    private var loop: ObservationLoop?

    init(service: EnvironmentService) {
        self.service = service
        super.init(title: "", variant: .ghost, size: .small, symbolName: "shippingbox")
        isMuted = true
        target = self
        action = #selector(openContainers)
        isHidden = !service.isEnabled
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit { loop?.cancel() }

    private func render() {
        let label = RuntimeStatusLabel(runtime: service.runtime, enabled: service.isEnabled)
        if title != label.text { title = label.text }
        if symbolName != label.symbol { symbolName = label.symbol }
        toolTip = service.isolation.map { "Isolation: \($0.verdict.word). \($0.summary)" } ?? (service.runtime?.userMessage ?? "Checking Rancher Desktop")
        isHidden = !service.isEnabled
        // The header bar places this item by its fitting size: re-run its layout when the label changes.
        superview?.needsLayout = true
    }

    @objc private func openContainers() { (NSApp.delegate as? AppDelegate)?.showContainers(nil) }
}
