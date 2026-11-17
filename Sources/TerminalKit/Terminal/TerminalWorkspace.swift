import AppKit
import Engine
import OpenCodeKit

/// What the host app does for terminals: open links (the built-in browser later; the default browser now), put
/// terminal text into the thread's composer, create the thread for a draft, and persist changed preferences.
@MainActor
public protocol TerminalWorkspaceDelegate: AnyObject {
    func terminalWorkspace(_ workspace: TerminalWorkspace, open link: TerminalLink)
    func terminalWorkspace(_ workspace: TerminalWorkspace, sendToComposer text: String, from record: TerminalRecord)
    /// The surface shows a draft (no thread yet) and the user asked for a terminal: create the thread and return
    /// its terminals, or nil (with the reason shown by the host).
    func terminalWorkspaceNeedsThread(_ workspace: TerminalWorkspace) async -> ThreadTerminals?
    func terminalWorkspace(_ workspace: TerminalWorkspace, didChange preferences: TerminalPreferences)
    /// New terminal output arrived: its last 4 KB as text (at most every 400 ms). For detecting dev-server URLs; the
    /// text is untrusted program output.
    func terminalWorkspace(_ workspace: TerminalWorkspace, screenText: String)
}

extension TerminalWorkspaceDelegate {
    public func terminalWorkspace(_ workspace: TerminalWorkspace, open link: TerminalLink) { link.openInDefaultBrowser() }
    public func terminalWorkspaceNeedsThread(_ workspace: TerminalWorkspace) async -> ThreadTerminals? { nil }
    public func terminalWorkspace(_ workspace: TerminalWorkspace, didChange preferences: TerminalPreferences) {}
    public func terminalWorkspace(_ workspace: TerminalWorkspace, screenText: String) {}
}

/// TerminalKit's entry point: makes the drawer and panel surfaces and keeps one emulator per terminal in a bounded
/// cache, so switching threads swaps terminal sets instantly without tearing down PTYs or scrollback.
///
/// ```swift
/// let terminals = TerminalWorkspace(service: engine.terminals, preferences: TerminalPreferences())
/// let drawer = terminals.makeSurface(.drawer)          // mount drawer.view in the bottom drawer
/// drawer.display(engine.terminals.terminals(for: sessionID), directory: session.directory)
/// ```
///
/// Threading: `@MainActor`. Ownership: one per window; `close()` detaches every emulator (PTYs keep running).
@MainActor
public final class TerminalWorkspace {
    /// Emulators kept for terminals that are not shown (least recently shown dropped first; each holds its
    /// scrollback, about 12 MiB at the default 10,000 rows).
    public static let paneCacheLimit = 16

    public let service: TerminalService
    public weak var delegate: (any TerminalWorkspaceDelegate)?
    public var preferences: TerminalPreferences {
        didSet {
            guard preferences != oldValue else { return }
            for pane in panes.values { pane.apply(preferences) }
        }
    }

    private var panes: [String: TerminalPaneController] = [:]
    private var recency: [String] = []
    private var surfaces: [WeakSurface] = []

    public init(service: TerminalService, preferences: TerminalPreferences = TerminalPreferences()) {
        self.service = service
        self.preferences = preferences
    }

    /// A drawer (tabs, split) or right-panel (tabs) surface.
    public func makeSurface(_ placement: TerminalPlacement) -> TerminalSurfaceController {
        let surface = TerminalSurfaceController(placement: placement, workspace: self)
        surfaces.removeAll { $0.surface == nil }
        surfaces.append(WeakSurface(surface: surface))
        return surface
    }

    /// Detaches every emulator and drops the cache. PTYs keep running on the server.
    public func close() {
        for pane in panes.values { pane.discard() }
        panes.removeAll()
        recency.removeAll()
    }

    /// Number of cached emulators (tests, diagnostics).
    public var cachedPaneCount: Int { panes.count }

    // MARK: Panes

    func pane(for record: TerminalRecord, in terminals: ThreadTerminals) -> TerminalPaneController {
        recency.removeAll { $0 == record.id }
        recency.append(record.id)
        if let pane = panes[record.id], pane.terminals === terminals { return pane }
        panes[record.id]?.discard()
        let pane = TerminalPaneController(record: record, terminals: terminals, workspace: self, service: service)
        panes[record.id] = pane
        evict()
        return pane
    }

    /// The cached emulator of a terminal, if it has one.
    public func existingPane(_ id: String) -> TerminalPaneController? { panes[id] }

    /// Panes shown by any surface are never evicted.
    private func evict() {
        let shown = Set(surfaces.compactMap(\.surface).flatMap(\.mountedIDs))
        while panes.count > Self.paneCacheLimit, let index = recency.firstIndex(where: { !shown.contains($0) }) {
            let id = recency.remove(at: index)
            panes.removeValue(forKey: id)?.discard()
        }
    }

    func discardPane(_ id: String) {
        recency.removeAll { $0 == id }
        panes.removeValue(forKey: id)?.discard()
    }

    // MARK: Commands shared by panes and surfaces

    func restart(_ id: String, in terminals: ThreadTerminals, size: PTYSize?) async {
        guard let record = await terminals.restart(id, size: size) else { return }
        discardPane(id)
        for surface in surfaces.compactMap(\.surface) where surface.terminals === terminals { surface.reload() }
        existingPane(record.id)?.focus()
    }

    func close(_ id: String, in terminals: ThreadTerminals) async {
        discardPane(id)
        await terminals.close(id)
        for surface in surfaces.compactMap(\.surface) where surface.terminals === terminals { surface.reload() }
    }

    private struct WeakSurface {
        weak var surface: TerminalSurfaceController?
    }
}
