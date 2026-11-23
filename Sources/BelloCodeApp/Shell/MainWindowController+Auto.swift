import AppKit
import BelloCore
import Engine

// Auto mode, risk notices and interrupts (docs/features/auto-mode.md): mode commands, the "Auto" audit tab, the
// tray banners' actions and Resume.

extension MainWindowController {
    func autoCommandState() -> AutoCommandState { Self.autoCommandState(for: container.context?.thread, auto: workspace.engine.auto) }

    /// Keyed by the thread's own ID, never its loaded session: an offline or not yet hydrated thread with cached risk
    /// notices still offers Mark Risk Notices Reviewed (NV15).
    static func autoCommandState(for thread: ThreadModel?, auto: AutoModeService?) -> AutoCommandState {
        guard let thread else { return AutoCommandState() }
        return AutoCommandState(noticesPending: (auto?.noticeCount(thread.sessionID) ?? 0) > 0, canResume: thread.heldInterrupt != nil)
    }

    func showAutoAuditPanel() {
        if split.panelItem.isCollapsed { split.setCollapsed(split.panelItem, false) }
        rightPanel.select("auto")
        workspace.updateLayout(rightPanelTab: "auto")
    }

    /// Wires the displayed thread's tray banners (called from the display hook).
    func attachAuto(_ context: ThreadSurfaceContext?) {
        container.interruptedBanner?.openThread = { [weak self] id in self?.container.context?.onOpenThread?(id) }
        container.riskNoticeBanner?.showAudit = { [weak self] in self?.showAutoAuditPanel() }
    }

    func performAuto(_ command: ShellCommand) {
        switch command {
        case .modeAsk: setMode(.ask)
        case .modeAutoEdit: setMode(.autoEdit)
        case .modeAuto: setMode(.auto)
        case .modeFullAccess: setMode(.fullAccess)
        case .showAutoAudit: showAutoAuditPanel()
        case .reviewRiskNotices:
            if let id = container.context?.thread?.sessionID { workspace.engine.auto?.markReviewed(id) }
        case .resumeInterrupted:
            guard let thread = container.context?.thread else { return NSSound.beep() }
            Task { _ = await thread.resumeAfterInterrupt() }
        default: break
        }
    }

    private func setMode(_ mode: PermissionMode) {
        guard let composer = container.composerController else { return NSSound.beep() }
        composer.setPermissionMode(mode)
    }

    @objc func setModeAsk(_ sender: Any?) { perform(.modeAsk) }
    @objc func setModeAutoEdit(_ sender: Any?) { perform(.modeAutoEdit) }
    @objc func setModeAuto(_ sender: Any?) { perform(.modeAuto) }
    @objc func setModeFullAccess(_ sender: Any?) { perform(.modeFullAccess) }
    @objc func showAutoAudit(_ sender: Any?) { perform(.showAutoAudit) }
    @objc func reviewRiskNotices(_ sender: Any?) { perform(.reviewRiskNotices) }
    @objc func resumeInterruptedThread(_ sender: Any?) { perform(.resumeInterrupted) }
}
