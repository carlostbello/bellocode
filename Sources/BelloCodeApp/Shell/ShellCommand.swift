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
    func chooseModel(_ sender: Any?)
    func choosePermissionMode(_ sender: Any?)
    func togglePlanMode(_ sender: Any?)
    func allowRequestOnce(_ sender: Any?)
    func allowRequestAlways(_ sender: Any?)
    func denyRequest(_ sender: Any?)
    func submitRequestAnswer(_ sender: Any?)
    func showPreviousRequest(_ sender: Any?)
    func showNextRequest(_ sender: Any?)
}

/// Every app command with its menu title and shortcut (docs/research/03-ux-patterns.md, section D), including the
/// composer's and AgentUI's. The menu, the context menus, validation and docs/features/shell.md all come from this one
/// table; `everyCommandHasAUniqueSelectorAndShortcut` checks it has no conflicts.
enum ShellCommand: String, CaseIterable, Sendable {
    case newThread, addProject
    case renameThread, archiveThread, deleteThread, markUnread
    case togglePinProject, removeProject, revealInFinder, copyPath
    case nextNeedsAttention, focusComposer, focusNextRegion, focusPreviousRegion, toggleTerminal
    case sendMessage, queueFollowUp, steerFollowUp, stopRun
    case chooseModel, permissionMode, togglePlan
    case allowOnce, allowAlways, denyRequest, submitAnswer, previousRequest, nextRequest
    case showSettings, connectProvider, showWelcome

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
        case .chooseModel: #selector(MainWindowController.chooseModel(_:))
        case .permissionMode: #selector(MainWindowController.choosePermissionMode(_:))
        case .togglePlan: #selector(MainWindowController.togglePlanMode(_:))
        case .allowOnce: #selector(MainWindowController.allowRequestOnce(_:))
        case .allowAlways: #selector(MainWindowController.allowRequestAlways(_:))
        case .denyRequest: #selector(MainWindowController.denyRequest(_:))
        case .submitAnswer: #selector(MainWindowController.submitRequestAnswer(_:))
        case .previousRequest: #selector(MainWindowController.showPreviousRequest(_:))
        case .nextRequest: #selector(MainWindowController.showNextRequest(_:))
        case .showSettings: #selector(AppDelegate.showSettings(_:))
        case .connectProvider: #selector(AppDelegate.connectProvider(_:))
        case .showWelcome: #selector(AppDelegate.showWelcome(_:))
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
        case .deleteThread: "Delete Thread…"
        case .markUnread: "Mark as Unread"
        case .togglePinProject: "Pin Project"
        case .removeProject: "Remove Project from Sidebar"
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
        case .chooseModel: "Choose Model…"
        case .permissionMode: "Permission Mode…"
        case .togglePlan: "Plan Mode"
        case .allowOnce: "Allow Once"
        case .allowAlways: "Always Allow"
        case .denyRequest: "Deny or Dismiss"
        case .submitAnswer: "Submit Answer"
        case .previousRequest: "Previous Request"
        case .nextRequest: "Next Request"
        case .showSettings: "Settings…"
        case .connectProvider: "Connect Provider…"
        case .showWelcome: "Welcome to BelloCode…"
        }
    }

    /// Key equivalent and modifiers. Empty key: no shortcut (still reachable from the menu, and by keyboard in the
    /// sidebar where noted in docs/features/shell.md). Request and picker shortcuts are AgentUI's (`AgentShortcut`).
    var shortcut: (key: String, modifiers: NSEvent.ModifierFlags) {
        let f6 = String(UnicodeScalar(UInt16(NSF6FunctionKey))!)
        let backspace = String(UnicodeScalar(UInt16(NSBackspaceCharacter))!)
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
        case .showSettings: (",", .command)
        case .connectProvider, .showWelcome: ("", [])
        }
    }

    /// Shortcuts that are also text-editing keys: disabled while a text view has focus so text keeps them
    /// (AGENTS.md UX rule 2). A disabled menu item does not consume its key equivalent.
    var conflictsWithTextEditing: Bool {
        switch self {
        case .archiveThread, .deleteThread: true
        default: false
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
    /// Request commands the displayed thread's front request accepts now.
    var availableRequestCommands: Set<RequestCommand> = []

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
        case .chooseModel, .permissionMode, .togglePlan: return composerVisible
        case .allowOnce, .allowAlways, .denyRequest, .submitAnswer, .previousRequest, .nextRequest:
            return command.requestCommand.map(availableRequestCommands.contains) ?? false
        case .showSettings, .connectProvider, .showWelcome: return true
        }
    }

    /// Titles that depend on state ("Unpin Project", "Hide Terminal").
    func title(for command: ShellCommand) -> String {
        switch command {
        case .togglePinProject: targetProjectPinned ? "Unpin Project" : "Pin Project"
        case .toggleTerminal: isTerminalVisible ? "Hide Terminal" : "Show Terminal"
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
