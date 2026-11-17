import AppKit
import BelloCore
import DesignSystem
import Engine
import Observation
import SwiftUI

// Seams where other modules mount their views. The shell owns layout, selection, focus and lifecycle; a surface
// owns its own view controller. To integrate a real module, change `ShellSurfaces.builtIn` below (one file):
//
//   transcript   → TranscriptKit   (TranscriptSurfaceController, Content/TranscriptSurface.swift)
//   requestStack → AgentUI         (RequestStackSurfaceController, Content/RequestStackSurface.swift)
//   composer     → ComposerKit     (ComposerSurfaceController, Content/ComposerSurface.swift)
//   rightPanel   → DiffKit / BrowserKit tabs (replaces the placeholder tabs)
//   terminal     → TerminalKit     (TerminalSurfaces, Content/TerminalSurface.swift: drawer + "Terminal" tab)
//
// A surface is created for one `ThreadSurfaceContext` (one displayed thread or draft) and released when the
// selection changes, so it must cancel its own observation/tasks when its view controller is deallocated or in
// `viewDidDisappear`. Surfaces never create or close `ThreadModel`s; the shell does.

/// The view controllers the shell mounts. Factories run on the main actor when a thread or draft is displayed.
@MainActor
struct ShellSurfaces {
    /// The message timeline. Shown for threads only (a draft has no transcript).
    var transcript: @MainActor (ThreadSurfaceContext) -> NSViewController
    /// Approvals and questions, pinned between the transcript and the composer (AGENTS.md UX rule 4). Its view sizes
    /// itself (intrinsic height, zero when nothing is pending).
    var requestStack: @MainActor (ThreadSurfaceContext) -> NSViewController
    /// The composer. Docked at the bottom for a thread, centred ("hero") for a draft. Sends through the context.
    var composer: @MainActor (ThreadSurfaceContext) -> NSViewController
    /// Right panel tabs (diff, files, browser, …).
    var rightPanelTabs: [RightPanelTab]
    /// The bottom drawer (terminal).
    var terminalDrawer: @MainActor () -> NSViewController
    /// DiffKit's "Changes" tab (Content/ChangesSurface.swift), bound by the window. nil: the tab is a placeholder.
    var changes: ChangesSurfaces? = nil

    static var builtIn: ShellSurfaces { builtIn(services: AppServices()) }

    static func builtIn(services: AppServices) -> ShellSurfaces {
        // TerminalKit (Content/TerminalSurface.swift): the drawer and the "Terminal" tab share one set per window.
        let terminals = TerminalSurfaces(services: services)
        // DiffKit (Content/ChangesSurface.swift): the "Changes" tab follows the displayed thread.
        let changes = ChangesSurfaces(services: services)
        return ShellSurfaces(
            transcript: { TranscriptSurfaceController(context: $0, settings: services.settings) },
            requestStack: { RequestStackSurfaceController(context: $0) },
            composer: { ComposerSurfaceController(context: $0, services: services) },
            rightPanelTabs: [
                RightPanelTab(id: "changes", title: "Changes", symbolName: "plusminus") { changes.makeController() },
                RightPanelTab(id: "files", title: "Files", symbolName: "folder") {
                    placeholder("Files", symbol: "folder", detail: "The project's files appear here.")
                },
                RightPanelTab(id: "browser", title: "Browser", symbolName: "globe") {
                    placeholder("Browser", symbol: "globe", detail: "The built-in browser appears here.")
                },
                RightPanelTab(id: "terminal", title: "Terminal", symbolName: "terminal") { terminals.makePanelController() },
            ],
            terminalDrawer: { terminals.makeDrawerController() }, changes: changes)
    }

    static func placeholder(_ title: String, symbol: String, detail: String) -> NSViewController {
        let controller = NSHostingController(rootView: PlaceholderPane(title, systemImage: symbol, detail: detail))
        controller.sizingOptions = []
        return controller
    }
}

/// One tab of the right panel.
@MainActor
struct RightPanelTab {
    var id: String
    var title: String
    var symbolName: String
    var make: @MainActor () -> NSViewController
}

/// Adopted by a surface's view controller to tell the shell which view takes focus for "Focus Composer" (⌥⌘M), new
/// threads and region cycling (F6). Without it the shell focuses the view controller's view.
@MainActor
protocol FocusableSurface: AnyObject {
    var preferredFocusView: NSView? { get }
}

/// Adopted by a composer to tell the shell whether Send (⌘↩) is available and to perform it from the menu.
@MainActor
protocol ComposerSurface: FocusableSurface {
    var hasSendableText: Bool { get }
    func performSend()
    /// Inserts text at the selection as one undoable edit and focuses the composer.
    func insertText(_ text: String)
}

/// Choices made in a new-thread draft, applied when its thread is created.
struct DraftThreadOptions: Hashable, Sendable {
    var agent: String?
    var model: ModelSelection?
    var permissionMode: PermissionMode?
    /// Where the thread is created when not the project's main checkout (a worktree prepared by the workspace picker).
    var directory: String?
}

/// Everything a surface needs about what is displayed, plus the actions a composer performs.
///
/// One context per displayed selection: a thread (`thread` set) or a draft in a project (`thread` nil until the first
/// send creates it). Threading: `@MainActor`, `@Observable`.
@MainActor
@Observable
final class ThreadSurfaceContext {
    let engine: Engine
    /// The directory the agent acts in: the session's directory once known, else the project's (a draft).
    var directory: String { thread?.session?.directory ?? projectDirectory }
    /// The project's directory (its root).
    let projectDirectory: String
    let projectName: String
    /// The open thread; nil for a draft.
    private(set) var thread: ThreadModel?
    /// A draft's thread is being created (show the message as sending; nothing is claimed delivered).
    private(set) var isCreatingThread = false
    /// A failure to show inline (for example "not connected; nothing was sent").
    private(set) var errorMessage: String?

    /// Draft text for a new thread (existing threads keep their draft in `ThreadModel.draft`).
    @ObservationIgnored var newThreadDraft: String
    @ObservationIgnored var onNewThreadDraftChange: ((String) -> Void)?
    /// Called after the first send of a draft created the thread: the shell switches the selection to it.
    @ObservationIgnored var onThreadCreated: ((SessionID) -> Void)?
    /// Opens (or reuses) a thread model; the shell owns their lifetime.
    @ObservationIgnored var openThread: ((SessionID) -> ThreadModel)?
    /// Shows another thread (a sub-agent's) in the window: the shell changes the selection.
    @ObservationIgnored var onOpenThread: ((SessionID) -> Void)?

    init(engine: Engine, directory: String, projectName: String, thread: ThreadModel?, newThreadDraft: String = "") {
        self.engine = engine
        projectDirectory = directory
        self.projectName = projectName
        self.thread = thread
        self.newThreadDraft = newThreadDraft
    }

    var isDraft: Bool { thread == nil }

    /// The composer's text.
    var draft: String {
        get { thread?.draft ?? newThreadDraft }
        set {
            if let thread {
                thread.draft = newValue
            } else {
                newThreadDraft = newValue
                onNewThreadDraftChange?(newValue)
            }
        }
    }

    var isRunning: Bool { thread?.isRunning ?? false }
    var isStopping: Bool { thread?.isStopping ?? false }

    /// The error to show: the context's own, else the thread's last command failure.
    var visibleError: String? { errorMessage ?? thread?.lastError?.userMessage }

    func clearError() {
        errorMessage = nil
        thread?.clearError()
    }

    /// Sends `text`. For a draft, creates the thread first (in `directory`), then sends, then asks the shell to show
    /// it. Returns whether the server accepted the prompt; on failure the text is back in the draft.
    @discardableResult
    func send(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isCreatingThread else { return false }
        errorMessage = nil
        if let thread {
            // Through the draft, so a failed send puts the text back in the composer.
            thread.draft = text
            return await thread.send() != nil
        }
        guard let model = await createThread() else { return false }
        // Through the model's draft so a failed send returns the text to the new thread's composer.
        model.draft = text
        return await model.send() != nil
    }

    /// Creates the thread for a draft with the agent, model and permission mode chosen in the draft, clears the
    /// draft text, and asks the shell to show it. Returns the open model, or nil (with `errorMessage` set).
    func createThread(_ options: DraftThreadOptions = DraftThreadOptions()) async -> ThreadModel? {
        guard thread == nil, !isCreatingThread else { return nil }
        errorMessage = nil
        isCreatingThread = true
        defer { isCreatingThread = false }
        do {
            let session = try await engine.createThread(in: options.directory ?? projectDirectory, agent: options.agent, model: options.model)
            guard let model = openThread?(session.id) else { return nil }
            if let mode = options.permissionMode { await model.setPermissionMode(mode) }
            newThreadDraft = ""
            onNewThreadDraftChange?("")
            onThreadCreated?(session.id)
            return model
        } catch {
            errorMessage = (error as? EngineError)?.userMessage ?? "The thread could not be created."
            return nil
        }
    }

    /// Stops the running turn (the thread shows "Stopping" until the server confirms).
    func stop() async {
        await thread?.stop()
    }
}
