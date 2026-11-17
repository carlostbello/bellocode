import AgentUI
import AppKit
import BelloCore

/// Action methods the window answers. Menu items and toolbar items use a nil target, so these travel the responder
/// chain (first responder → … → window → `MainWindowController`); text views see Edit commands first. The composer's
/// own actions (`sendPrompt:`, `queuePrompt:`, `steerPrompt:`, `stopAgent:`, `focusComposer:`) have the same names, so
/// a focused composer answers them itself and the window forwards them otherwise.
@MainActor
@objc protocol ShellActions {
    func newThread(_ sender: Any?)
    func addProject(_ sender: Any?)
    func renameThread(_ sender: Any?)
    func archiveThread(_ sender: Any?)
    func deleteThread(_ sender: Any?)
    func markUnread(_ sender: Any?)
    func togglePinProject(_ sender: Any?)
    func removeProject(_ sender: Any?)
    func revealInFinder(_ sender: Any?)
    func copyPath(_ sender: Any?)
    func nextNeedsAttention(_ sender: Any?)
    func focusComposer(_ sender: Any?)
    func focusNextRegion(_ sender: Any?)
    func focusPreviousRegion(_ sender: Any?)
    func toggleTerminal(_ sender: Any?)
    func sendPrompt(_ sender: Any?)
    func queuePrompt(_ sender: Any?)
    func steerPrompt(_ sender: Any?)
    func stopAgent(_ sender: Any?)
    func retryUnconfirmedSend(_ sender: Any?)
    func chooseModel(_ sender: Any?)
    func choosePermissionMode(_ sender: Any?)
    func togglePlanMode(_ sender: Any?)
    func allowRequestOnce(_ sender: Any?)
    func allowRequestAlways(_ sender: Any?)
    func denyRequest(_ sender: Any?)
    func submitRequestAnswer(_ sender: Any?)
    func showPreviousRequest(_ sender: Any?)
    func showNextRequest(_ sender: Any?)
    func newTerminal(_ sender: Any?)
    func closeTerminal(_ sender: Any?)
    func splitTerminal(_ sender: Any?)
    func selectNextTerminal(_ sender: Any?)
    func selectPreviousTerminal(_ sender: Any?)
    func clearTerminal(_ sender: Any?)
    func renameTerminal(_ sender: Any?)
    func restartTerminal(_ sender: Any?)
    func moveTerminal(_ sender: Any?)
    func sendTerminalSelectionToComposer(_ sender: Any?)
    // M2-D: sidebar organisation, palette, search, history and windows (docs/features/navigation.md).
    func togglePinThread(_ sender: Any?)
    func settleThread(_ sender: Any?)
    func snoozeLaterToday(_ sender: Any?)
    func snoozeTomorrow(_ sender: Any?)
    func snoozeNextWeek(_ sender: Any?)
    func snoozeUntil(_ sender: Any?)
    func wakeThread(_ sender: Any?)
    func toggleNeverAutoSettle(_ sender: Any?)
    func groupThreadsByProject(_ sender: Any?)
    func showThreadsByState(_ sender: Any?)
    func filterSidebar(_ sender: Any?)
    func moveProjectUp(_ sender: Any?)
    func moveProjectDown(_ sender: Any?)
    func showCommandPalette(_ sender: Any?)
    func showQuickOpen(_ sender: Any?)
    func showGlobalSearch(_ sender: Any?)
    func goBackInHistory(_ sender: Any?)
    func goForwardInHistory(_ sender: Any?)
    func reopenClosedThread(_ sender: Any?)
}

/// Every app command with its menu title and shortcut (docs/research/03-ux-patterns.md, section D), including the
/// composer's and AgentUI's. The menu, the context menus, validation and docs/features/shell.md all come from this one
/// table; `everyCommandHasAUniqueSelectorAndShortcut` checks it has no conflicts.
enum ShellCommand: String, CaseIterable, Sendable {
    case newThread, addProject
    case renameThread, archiveThread, deleteThread, markUnread
    case togglePinProject, removeProject, revealInFinder, copyPath
    case nextNeedsAttention, focusComposer, focusNextRegion, focusPreviousRegion, toggleTerminal
    case sendMessage, queueFollowUp, steerFollowUp, stopRun, retryUnconfirmed
    case chooseModel, permissionMode, togglePlan
    case allowOnce, allowAlways, denyRequest, submitAnswer, previousRequest, nextRequest
    case findInThread, findNext, findPrevious, useSelectionForFind
    case copyMessage, copyAsMarkdown, copyCode, jumpToLatest, previousTurn, nextTurn, lastFailure
    case showSettings, connectProvider, showWelcome
    case newTerminal, closeTerminal, splitTerminal, nextTerminal, previousTerminal, clearTerminal, renameTerminal
    case restartTerminal, moveTerminal, sendTerminalSelection
    // M2-D (docs/features/navigation.md).
    case togglePinThread, settleThread, snoozeLaterToday, snoozeTomorrow, snoozeNextWeek, snoozeUntil, wakeThread
    case toggleNeverAutoSettle, groupByProject, showThreadsByState, filterSidebar, moveProjectUp, moveProjectDown
    case commandPalette, quickOpen, globalSearch, goBack, goForward, reopenClosedThread, newWindow

    @MainActor var selector: Selector {
        switch self {
        case .newThread: #selector(MainWindowController.newThread(_:))
        case .addProject: #selector(MainWindowController.addProject(_:))
        case .renameThread: #selector(MainWindowController.renameThread(_:))
        case .archiveThread: #selector(MainWindowController.archiveThread(_:))
        case .deleteThread: #selector(MainWindowController.deleteThread(_:))
        case .markUnread: #selector(MainWindowController.markUnread(_:))
        case .togglePinProject: #selector(MainWindowController.togglePinProject(_:))
        case .removeProject: #selector(MainWindowController.removeProject(_:))
        case .revealInFinder: #selector(MainWindowController.revealInFinder(_:))
        case .copyPath: #selector(MainWindowController.copyPath(_:))
        case .nextNeedsAttention: #selector(MainWindowController.nextNeedsAttention(_:))
        case .focusComposer: #selector(MainWindowController.focusComposer(_:))
        case .focusNextRegion: #selector(MainWindowController.focusNextRegion(_:))
        case .focusPreviousRegion: #selector(MainWindowController.focusPreviousRegion(_:))
        case .toggleTerminal: #selector(MainWindowController.toggleTerminal(_:))
        case .sendMessage: #selector(MainWindowController.sendPrompt(_:))
        case .queueFollowUp: #selector(MainWindowController.queuePrompt(_:))
        case .steerFollowUp: #selector(MainWindowController.steerPrompt(_:))
        case .stopRun: #selector(MainWindowController.stopAgent(_:))
        case .retryUnconfirmed: #selector(MainWindowController.retryUnconfirmedSend(_:))
        case .chooseModel: #selector(MainWindowController.chooseModel(_:))
        case .permissionMode: #selector(MainWindowController.choosePermissionMode(_:))
        case .togglePlan: #selector(MainWindowController.togglePlanMode(_:))
        case .allowOnce: #selector(MainWindowController.allowRequestOnce(_:))
        case .allowAlways: #selector(MainWindowController.allowRequestAlways(_:))
        case .denyRequest: #selector(MainWindowController.denyRequest(_:))
        case .submitAnswer: #selector(MainWindowController.submitRequestAnswer(_:))
        case .previousRequest: #selector(MainWindowController.showPreviousRequest(_:))
        case .nextRequest: #selector(MainWindowController.showNextRequest(_:))
        // The transcript's table answers these itself when focused; the window forwards them otherwise.
        case .findInThread: #selector(MainWindowController.findInTranscript(_:))
        case .findNext: #selector(MainWindowController.findNextInTranscript(_:))
        case .findPrevious: #selector(MainWindowController.findPreviousInTranscript(_:))
        case .useSelectionForFind: #selector(MainWindowController.useSelectionForTranscriptFind(_:))
        case .copyMessage: #selector(MainWindowController.copyTranscriptMessage(_:))
        case .copyAsMarkdown: #selector(MainWindowController.copyTranscriptMarkdown(_:))
        case .copyCode: #selector(MainWindowController.copyTranscriptCode(_:))
        case .jumpToLatest: #selector(MainWindowController.jumpToLatestOutput(_:))
        case .previousTurn: #selector(MainWindowController.showPreviousTurn(_:))
        case .nextTurn: #selector(MainWindowController.showNextTurn(_:))
        case .lastFailure: #selector(MainWindowController.showLastFailure(_:))
        case .showSettings: #selector(AppDelegate.showSettings(_:))
        case .connectProvider: #selector(AppDelegate.connectProvider(_:))
        case .showWelcome: #selector(AppDelegate.showWelcome(_:))
        case .newTerminal: #selector(MainWindowController.newTerminal(_:))
        case .closeTerminal: #selector(MainWindowController.closeTerminal(_:))
        case .splitTerminal: #selector(MainWindowController.splitTerminal(_:))
        case .nextTerminal: #selector(MainWindowController.selectNextTerminal(_:))
        case .previousTerminal: #selector(MainWindowController.selectPreviousTerminal(_:))
        // The focused terminal answers these two itself (same selectors on TerminalPaneView).
        case .clearTerminal: #selector(MainWindowController.clearTerminal(_:))
        case .renameTerminal: #selector(MainWindowController.renameTerminal(_:))
        case .restartTerminal: #selector(MainWindowController.restartTerminal(_:))
        case .moveTerminal: #selector(MainWindowController.moveTerminal(_:))
        case .sendTerminalSelection: #selector(MainWindowController.sendTerminalSelectionToComposer(_:))
        case .togglePinThread: #selector(MainWindowController.togglePinThread(_:))
        case .settleThread: #selector(MainWindowController.settleThread(_:))
        case .snoozeLaterToday: #selector(MainWindowController.snoozeLaterToday(_:))
        case .snoozeTomorrow: #selector(MainWindowController.snoozeTomorrow(_:))
        case .snoozeNextWeek: #selector(MainWindowController.snoozeNextWeek(_:))
        case .snoozeUntil: #selector(MainWindowController.snoozeUntil(_:))
        case .wakeThread: #selector(MainWindowController.wakeThread(_:))
        case .toggleNeverAutoSettle: #selector(MainWindowController.toggleNeverAutoSettle(_:))
        case .groupByProject: #selector(MainWindowController.groupThreadsByProject(_:))
        case .showThreadsByState: #selector(MainWindowController.showThreadsByState(_:))
        case .filterSidebar: #selector(MainWindowController.filterSidebar(_:))
        case .moveProjectUp: #selector(MainWindowController.moveProjectUp(_:))
        case .moveProjectDown: #selector(MainWindowController.moveProjectDown(_:))
        case .commandPalette: #selector(MainWindowController.showCommandPalette(_:))
        case .quickOpen: #selector(MainWindowController.showQuickOpen(_:))
        case .globalSearch: #selector(MainWindowController.showGlobalSearch(_:))
        case .goBack: #selector(MainWindowController.goBackInHistory(_:))
        case .goForward: #selector(MainWindowController.goForwardInHistory(_:))
        case .reopenClosedThread: #selector(MainWindowController.reopenClosedThread(_:))
        // Answered by the app delegate (works with no window open).
        case .newWindow: #selector(AppDelegate.newMainWindow(_:))
        }
    }

    @MainActor static func command(for selector: Selector) -> ShellCommand? {
        allCases.first { $0.selector == selector }
    }

    var title: String {
        switch self {
        case .newThread: "New Thread"
        case .addProject: "Add Project…"
        case .renameThread: "Rename Thread"
        case .archiveThread: "Archive Thread"
        case .deleteThread: "Delete Thread"
        case .markUnread: "Mark as Unread"
        case .togglePinProject: "Pin Project"
        case .removeProject: "Archive Project"
        case .revealInFinder: "Reveal in Finder"
        case .copyPath: "Copy Path"
        case .nextNeedsAttention: "Next Needs Attention"
        case .focusComposer: "Focus Composer"
        case .focusNextRegion: "Move Focus to Next Region"
        case .focusPreviousRegion: "Move Focus to Previous Region"
        case .toggleTerminal: "Show Terminal"
        case .sendMessage: "Send"
        case .queueFollowUp: "Queue After This Turn"
        case .steerFollowUp: "Steer at Next Step"
        case .stopRun: "Stop Agent"
        case .retryUnconfirmed: "Retry Unconfirmed Message"
        case .chooseModel: "Choose Model…"
        case .permissionMode: "Permission Mode…"
        case .togglePlan: "Plan Mode"
        case .allowOnce: "Allow Once"
        case .allowAlways: "Always Allow"
        case .denyRequest: "Deny or Dismiss"
        case .submitAnswer: "Submit Answer"
        case .previousRequest: "Previous Request"
        case .nextRequest: "Next Request"
        case .findInThread: "Find in Thread…"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .useSelectionForFind: "Use Selection for Find"
        case .copyMessage: "Copy Message"
        case .copyAsMarkdown: "Copy as Markdown"
        case .copyCode: "Copy Code"
        case .jumpToLatest: "Jump to Latest"
        case .previousTurn: "Previous Prompt"
        case .nextTurn: "Next Prompt"
        case .lastFailure: "Go to Last Failure"
        case .showSettings: "Settings…"
        case .connectProvider: "Connect Provider…"
        case .showWelcome: "Welcome to BelloCode…"
        case .newTerminal: "New Terminal"
        case .closeTerminal: "Close Terminal"
        case .splitTerminal: "Split Terminal"
        case .nextTerminal: "Next Terminal"
        case .previousTerminal: "Previous Terminal"
        case .clearTerminal: "Clear Terminal"
        case .renameTerminal: "Rename Terminal…"
        case .restartTerminal: "Restart Terminal"
        case .moveTerminal: "Move Terminal to Right Panel"
        case .sendTerminalSelection: "Send Selection to Composer"
        case .togglePinThread: "Pin Thread"
        case .settleThread: "Settle Thread"
        case .snoozeLaterToday: "Snooze Until Later Today"
        case .snoozeTomorrow: "Snooze Until Tomorrow"
        case .snoozeNextWeek: "Snooze Until Next Week"
        case .snoozeUntil: "Snooze Until…"
        case .wakeThread: "Wake Now"
        case .toggleNeverAutoSettle: "Never Auto-Settle"
        case .groupByProject: "Group Threads by Project"
        case .showThreadsByState: "Show All Threads by State"
        case .filterSidebar: "Filter Threads…"
        case .moveProjectUp: "Move Project Up"
        case .moveProjectDown: "Move Project Down"
        case .commandPalette: "Command Palette…"
        case .quickOpen: "Quick Open…"
        case .globalSearch: "Search Messages…"
        case .goBack: "Back"
        case .goForward: "Forward"
        case .reopenClosedThread: "Reopen Closed Thread"
        case .newWindow: "New Window"
        }
    }

    /// Key equivalent and modifiers. Empty key: no shortcut (still reachable from the menu, and by keyboard in the
    /// sidebar where noted in docs/features/shell.md). Request and picker shortcuts are AgentUI's (`AgentShortcut`).
    var shortcut: (key: String, modifiers: NSEvent.ModifierFlags) {
        let f6 = String(UnicodeScalar(UInt16(NSF6FunctionKey))!)
        let backspace = String(UnicodeScalar(UInt16(NSBackspaceCharacter))!)
        let up = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
        let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        func agent(_ shortcut: AgentShortcut) -> (String, NSEvent.ModifierFlags) {
            (shortcut.menuKeyEquivalent, shortcut.menuModifierMask)
        }
        return switch self {
        case .newThread: ("n", .command)
        case .addProject: ("o", [.command, .shift])
        case .renameThread: ("", [])
        case .archiveThread: (backspace, .command)
        case .deleteThread: (backspace, [.command, .option])
        case .markUnread: ("u", [.command, .shift])
        case .togglePinProject, .removeProject: ("", [])
        case .revealInFinder: ("r", [.command, .option])
        case .copyPath: ("c", [.command, .control, .shift])
        case .nextNeedsAttention: ("a", [.command, .option])
        case .focusComposer: ("m", [.command, .option])
        case .focusNextRegion: (f6, [])
        case .focusPreviousRegion: (f6, .shift)
        case .toggleTerminal: ("`", .control)
        // While the composer has focus it handles ⌘↩ itself (its send-key policy); this applies elsewhere.
        case .sendMessage: ("\r", .command)
        // No default shortcut (research 03, section D): Return/⌘↩ in the composer do the default follow-up.
        case .queueFollowUp, .steerFollowUp: ("", [])
        // Not Escape: Escape only dismisses transient UI.
        case .stopRun: (".", .command)
        case .chooseModel: agent(.modelPicker)
        case .permissionMode: agent(.permissionMode)
        case .togglePlan: agent(.togglePlan)
        case .allowOnce: agent(.allowOnce)
        case .allowAlways: agent(.allowAlways)
        case .denyRequest: agent(.deny)
        case .submitAnswer: agent(.submitAnswer)
        case .previousRequest: agent(.previousRequest)
        case .nextRequest: agent(.nextRequest)
        case .findInThread: ("f", .command)
        case .findNext: ("g", .command)
        case .findPrevious: ("g", [.command, .shift])
        case .useSelectionForFind: ("e", .command)
        case .copyMessage, .copyCode: ("", [])
        case .copyAsMarkdown: ("c", [.command, .option, .shift])
        case .jumpToLatest: ("j", [.command, .shift])
        case .previousTurn: (up, [.command, .option])
        case .nextTurn: (down, [.command, .option])
        case .lastFailure: ("l", [.command, .option])
        case .showSettings: (",", .command)
        case .connectProvider, .showWelcome, .retryUnconfirmed: ("", [])
        // Terminal.app's keys where they exist; all use ⌘ so a focused terminal keeps its control sequences.
        case .newTerminal: ("t", .command)
        case .closeTerminal: ("w", [.command, .shift])
        case .splitTerminal: ("d", .command)
        case .nextTerminal: ("}", .command)
        case .previousTerminal: ("{", .command)
        case .clearTerminal: ("k", .command)
        case .sendTerminalSelection: ("l", [.command, .shift])
        case .renameTerminal, .restartTerminal, .moveTerminal: ("", [])
        // T3 Code's keys where they do not collide (research 04, section 3).
        case .togglePinThread: ("p", [.command, .shift])
        case .settleThread: ("s", [.command, .shift])
        case .snoozeUntil: ("s", [.command, .option])
        case .snoozeLaterToday, .snoozeTomorrow, .snoozeNextWeek, .wakeThread, .toggleNeverAutoSettle: ("", [])
        case .groupByProject, .showThreadsByState, .moveProjectUp, .moveProjectDown: ("", [])
        case .filterSidebar: ("f", [.command, .option])
        // ⌘K is shared with Clear Terminal, focus-aware: exactly one of the two is enabled at a time (see
        // `CommandContext.isEnabled`); a focused terminal keeps ⌘K as in Terminal.app.
        case .commandPalette: ("k", .command)
        case .quickOpen: ("p", .command)
        case .globalSearch: ("f", [.command, .shift])
        case .goBack: ("[", .command)
        case .goForward: ("]", .command)
        case .reopenClosedThread: ("t", [.command, .shift])
        case .newWindow: ("n", [.command, .shift])
        }
    }

    /// Commands that act on several selected sidebar threads at once.
    var actsOnSelection: Bool {
        switch self {
        case .archiveThread, .deleteThread, .markUnread, .togglePinThread, .settleThread, .snoozeLaterToday, .snoozeTomorrow,
            .snoozeNextWeek, .snoozeUntil, .wakeThread, .toggleNeverAutoSettle:
            true
        default: false
        }
    }

    /// Shortcuts without ⌘ that still reach the app while a terminal has focus. Every other non-⌘ key (F6 for
    /// region cycling included) goes to the program in the terminal (AGENTS.md UX rule 2); leave a terminal with ⌃`
    /// or ⌥⌘M (Focus Composer).
    var isKeptWhileTerminalFocused: Bool { self == .toggleTerminal }

    /// Shortcuts that are also text-editing keys: disabled while a text view has focus so text keeps them
    /// (AGENTS.md UX rule 2). A disabled menu item does not consume its key equivalent.
    var conflictsWithTextEditing: Bool {
        switch self {
        case .archiveThread, .deleteThread: true
        default: false
        }
    }

    /// Checkmark state in menus (nil: no checkmark).
    func isChecked(in context: CommandContext) -> Bool? {
        switch self {
        case .toggleNeverAutoSettle: context.targetsNeverAutoSettle
        case .groupByProject: context.grouping == .byProject
        case .showThreadsByState: context.grouping == .byState
        default: nil
        }
    }

    /// The AgentUI request action behind a request command.
    var requestCommand: RequestCommand? {
        switch self {
        case .allowOnce: .allowOnce
        case .allowAlways: .allowAlways
        case .denyRequest: .deny
        case .submitAnswer: .submitAnswer
        case .previousRequest: .previous
        case .nextRequest: .next
        default: nil
        }
    }
}

/// What a command would act on: the clicked row (context menu) or the selection.
enum CommandTarget: Equatable, Sendable {
    case thread(SessionID, directory: String, isRunning: Bool)
    case project(directory: String, isPinned: Bool)
    /// The new-thread draft of a project.
    case draft(directory: String, isPinned: Bool)

    var directory: String {
        switch self {
        case .thread(_, let directory, _), .project(let directory, _), .draft(let directory, _): directory
        }
    }

    var threadID: SessionID? {
        if case .thread(let id, _, _) = self { id } else { nil }
    }
}

/// Inputs to menu validation, gathered by the window from its current state. Pure, so validation is tested.
struct CommandContext: Equatable, Sendable {
    var hasProjects = false
    var target: CommandTarget?
    /// The project directory a thread target belongs to is pinned (for the Pin/Unpin title).
    var targetProjectPinned = false
    var textInputFocused = false
    var attentionCount = 0
    var composerVisible = false
    var composerHasText = false
    /// The displayed thread runs (the composer offers queue, steer and stop).
    var composerRunning = false
    var isTerminalVisible = false
    /// The displayed thread has a send whose delivery is unknown (Retry checks and resends under the same ID).
    var hasUnconfirmedSend = false
    /// Request commands the displayed thread's front request accepts now.
    var availableRequestCommands: Set<RequestCommand> = []
    /// A thread or draft is displayed and the terminals are bound (New Terminal can act).
    var terminalAvailable = false
    /// The terminal surface commands act on has a selected terminal.
    var terminalSelected = false
    var terminalHasSelectedText = false
    var terminalSplit = false
    /// The terminal commands act on is in the right panel.
    var terminalInPanel = false
    /// Transcript commands the displayed transcript can run now.
    var availableTranscriptCommands: Set<ShellCommand> = []
    /// Keyboard focus is inside a terminal (it keeps ⌘K for Clear).
    var terminalFocused = false
    /// Threads a selection command acts on (the sidebar's multi-selection, else the target).
    var selectedThreadCount = 0
    /// Organisation of the targeted threads: all pinned / settled / snoozed / never auto-settle.
    var targetsPinned = false
    var targetsSettled = false
    var targetsSnoozed = false
    var targetsNeverAutoSettle = false
    var grouping: SidebarGrouping = .byProject
    var canGoBack = false
    var canGoForward = false
    var canReopenClosedThread = false
    var projectCanMoveUp = false
    var projectCanMoveDown = false

    func isEnabled(_ command: ShellCommand) -> Bool {
        if command.conflictsWithTextEditing, textInputFocused { return false }
        switch command {
        case .newThread: return hasProjects
        case .addProject, .focusNextRegion, .focusPreviousRegion, .toggleTerminal: return true
        case .renameThread, .archiveThread, .deleteThread, .markUnread: return target?.threadID != nil
        case .togglePinProject, .removeProject, .revealInFinder, .copyPath: return target != nil
        case .nextNeedsAttention: return attentionCount > 0
        case .focusComposer: return composerVisible
        case .sendMessage: return composerVisible && composerHasText
        case .queueFollowUp, .steerFollowUp: return composerVisible && composerHasText && composerRunning
        case .stopRun:
            if case .thread(_, _, true) = target { return true }
            return false
        case .retryUnconfirmed: return hasUnconfirmedSend
        case .chooseModel, .permissionMode, .togglePlan: return composerVisible
        case .allowOnce, .allowAlways, .denyRequest, .submitAnswer, .previousRequest, .nextRequest:
            return command.requestCommand.map(availableRequestCommands.contains) ?? false
        case .findInThread, .findNext, .findPrevious, .useSelectionForFind, .copyMessage, .copyAsMarkdown, .copyCode, .jumpToLatest,
            .previousTurn, .nextTurn, .lastFailure:
            return availableTranscriptCommands.contains(command)
        case .showSettings, .connectProvider, .showWelcome: return true
        case .newTerminal, .splitTerminal: return terminalAvailable
        // Clear Terminal owns ⌘K only while a terminal has focus (the palette has it elsewhere).
        case .clearTerminal: return terminalSelected && terminalFocused
        case .closeTerminal, .nextTerminal, .previousTerminal, .renameTerminal, .restartTerminal, .moveTerminal:
            return terminalSelected
        case .sendTerminalSelection: return terminalHasSelectedText && composerVisible
        case .togglePinThread, .settleThread, .snoozeLaterToday, .snoozeTomorrow, .snoozeNextWeek, .snoozeUntil,
            .toggleNeverAutoSettle:
            return target?.threadID != nil || selectedThreadCount > 0
        case .wakeThread: return targetsSnoozed
        case .groupByProject, .showThreadsByState: return true
        case .filterSidebar: return hasProjects
        case .moveProjectUp: return projectCanMoveUp
        case .moveProjectDown: return projectCanMoveDown
        // Focus-aware ⌘K: the palette steps aside while a terminal has focus.
        case .commandPalette: return !terminalFocused
        case .quickOpen, .globalSearch, .newWindow: return true
        case .goBack: return canGoBack
        case .goForward: return canGoForward
        case .reopenClosedThread: return canReopenClosedThread
        }
    }

    /// Why a command is disabled, for the palette (nil when enabled).
    func disabledReason(for command: ShellCommand) -> String? {
        guard !isEnabled(command) else { return nil }
        if command.conflictsWithTextEditing, textInputFocused { return "Text editing uses this key" }
        switch command {
        case .newThread, .filterSidebar: return "Add a project first"
        case .renameThread, .archiveThread, .deleteThread, .markUnread, .togglePinThread, .settleThread, .snoozeLaterToday,
            .snoozeTomorrow, .snoozeNextWeek, .snoozeUntil, .toggleNeverAutoSettle:
            return "Select a thread"
        case .wakeThread: return "The thread is not snoozed"
        case .togglePinProject, .removeProject, .revealInFinder, .copyPath: return "Select a project or thread"
        case .moveProjectUp, .moveProjectDown: return "Select a project that can move"
        case .nextNeedsAttention: return "Nothing needs you"
        case .focusComposer, .chooseModel, .permissionMode, .togglePlan: return "Open a thread"
        case .sendMessage: return composerVisible ? "The composer is empty" : "Open a thread"
        case .queueFollowUp, .steerFollowUp: return composerRunning ? "The composer is empty" : "The agent is not running"
        case .stopRun: return "The agent is not running"
        case .retryUnconfirmed: return "No message is waiting for confirmation"
        case .allowOnce, .allowAlways, .denyRequest, .submitAnswer, .previousRequest, .nextRequest:
            return "No approval or question is pending"
        case .findInThread, .findNext, .findPrevious, .useSelectionForFind, .copyMessage, .copyAsMarkdown, .copyCode,
            .jumpToLatest, .previousTurn, .nextTurn, .lastFailure:
            return "Open a thread with messages"
        case .newTerminal, .splitTerminal: return "Open a thread"
        case .clearTerminal: return terminalSelected ? "Click in the terminal first (⌘K clears it there)" : "No terminal is open"
        case .closeTerminal, .nextTerminal, .previousTerminal, .renameTerminal, .restartTerminal, .moveTerminal:
            return "No terminal is open"
        case .sendTerminalSelection: return "Select text in a terminal"
        case .commandPalette: return "A terminal has focus (⌘K clears it); use ⌘P and type >"
        case .goBack: return "No earlier thread"
        case .goForward: return "No later thread"
        case .reopenClosedThread: return "No thread was closed"
        default: return "Not available now"
        }
    }

    /// Titles that depend on state ("Unpin Project", "Hide Terminal").
    func title(for command: ShellCommand) -> String {
        switch command {
        case .togglePinProject: targetProjectPinned ? "Unpin Project" : "Pin Project"
        case .toggleTerminal: isTerminalVisible ? "Hide Terminal" : "Show Terminal"
        case .splitTerminal: terminalSplit ? "Unsplit Terminal" : "Split Terminal"
        case .moveTerminal: terminalInPanel ? "Move Terminal to Drawer" : "Move Terminal to Right Panel"
        case .togglePinThread:
            (targetsPinned ? "Unpin " : "Pin ") + (selectedThreadCount > 1 ? "\(selectedThreadCount) Threads" : "Thread")
        case .settleThread:
            (targetsSettled ? "Un-settle " : "Settle ") + (selectedThreadCount > 1 ? "\(selectedThreadCount) Threads" : "Thread")
        case .archiveThread: selectedThreadCount > 1 ? "Archive \(selectedThreadCount) Threads" : command.title
        case .deleteThread: selectedThreadCount > 1 ? "Delete \(selectedThreadCount) Threads" : command.title
        default: command.title
        }
    }
}

/// "Next needs attention": the item after `current` in the attention list, wrapping; the first when `current` is not
/// in the list.
func nextAttention(after current: SessionID?, in items: [SessionID]) -> SessionID? {
    guard !items.isEmpty else { return nil }
    guard let current, let index = items.firstIndex(of: current) else { return items.first }
    return items[(index + 1) % items.count]
}
