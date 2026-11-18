import AppKit
import ComposerKit
import Engine

/// Builds the main menu in code. App commands come from `ShellCommand` and use a nil target, so they travel the
/// responder chain (text views first, then the window controller) and are validated there. Standard items use the
/// AppKit selectors so text editing, Undo, Find and window commands keep their native behaviour.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let appName = ProcessInfo.processInfo.processName
        let mainMenu = NSMenu()

        mainMenu.addItem(submenu: applicationMenu(appName: appName))
        mainMenu.addItem(submenu: fileMenu())
        mainMenu.addItem(submenu: editMenu())
        mainMenu.addItem(submenu: viewMenu())
        // Before Terminal: the menu bar is searched in order, so ⌘K reaches Command Palette (Go) unless it is disabled
        // because a terminal has focus, and then Clear Terminal (see `CommandContext.isEnabled`).
        mainMenu.addItem(submenu: goMenu())
        mainMenu.addItem(submenu: threadMenu())
        mainMenu.addItem(submenu: terminalMenu())
        mainMenu.addItem(submenu: changesMenu())
        mainMenu.addItem(submenu: gitLabMenu())
        mainMenu.addItem(submenu: gitMenu())
        mainMenu.addItem(submenu: BrowserMenu.make())

        let windowMenu = windowMenu()
        mainMenu.addItem(submenu: windowMenu)
        NSApp.windowsMenu = windowMenu

        let helpMenu = helpMenu(appName: appName)
        mainMenu.addItem(submenu: helpMenu)
        NSApp.helpMenu = helpMenu

        return mainMenu
    }

    private static func applicationMenu(appName: String) -> NSMenu {
        let menu = NSMenu(title: appName)
        menu.addItem(title: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), key: "")
        menu.addItem(.separator())
        menu.add(.showSettings)
        menu.add(.connectProvider)
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        menu.addItem(submenu: services, title: "Services")
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(title: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), key: "h")
        menu.addItem(
            title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h",
            modifiers: [.command, .option])
        menu.addItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), key: "")
        menu.addItem(.separator())
        menu.addItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), key: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.add(.newThread)
        menu.add(.newWindow)
        menu.add(.addProject)
        menu.addItem(.separator())
        menu.add(.reopenClosedThread)
        menu.addItem(.separator())
        menu.add(.togglePinProject)
        menu.add(.moveProjectUp)
        menu.add(.moveProjectDown)
        menu.add(.removeProject)
        menu.addItem(.separator())
        menu.add(.revealInFinder)
        // The header's "Open ⌄" menu also lists this (UX rule 2: every action is in the menu bar).
        menu.addItem(title: "Open in Terminal", action: #selector(MainWindowController.openProjectInTerminal(_:)), key: "")
        menu.add(.copyPath)
        menu.addItem(.separator())
        menu.addItem(title: "Close", action: #selector(NSWindow.performClose(_:)), key: "w")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(title: "Undo", action: Selector(("undo:")), key: "z")
        menu.addItem(title: "Redo", action: Selector(("redo:")), key: "z", modifiers: [.command, .shift])
        menu.addItem(.separator())
        menu.addItem(title: "Cut", action: #selector(NSText.cut(_:)), key: "x")
        menu.addItem(title: "Copy", action: #selector(NSText.copy(_:)), key: "c")
        menu.add(.copyMessage)
        menu.add(.copyAsMarkdown)
        menu.add(.copyCode)
        menu.addItem(title: "Paste", action: #selector(NSText.paste(_:)), key: "v")
        menu.addItem(
            title: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), key: "v",
            modifiers: [.command, .option, .shift])
        // The composer turns a large paste into a text attachment; this keeps it in the text.
        menu.addItem(title: "Paste Inline", action: #selector(ComposerTextView.pasteInline(_:)), key: "v", modifiers: [.command, .option])
        menu.addItem(title: "Delete", action: #selector(NSText.delete(_:)), key: "")
        menu.addItem(title: "Select All", action: #selector(NSText.selectAll(_:)), key: "a")
        menu.addItem(.separator())
        // Find acts on the transcript (docs/research/03, section D: ⌘F finds in the focused session).
        let find = NSMenu(title: "Find")
        find.add(.findInThread)
        find.add(.findNext)
        find.add(.findPrevious)
        find.add(.useSelectionForFind)
        find.addItem(.separator())
        find.add(.globalSearch)
        find.add(.filterSidebar)
        menu.addItem(submenu: find, title: "Find")
        // AppKit appends AutoFill, Writing Tools, Start Dictation and Emoji & Symbols to a menu titled "Edit".
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        // The window retitles these to Show/Hide Sidebar and Show/Hide Right Panel as the state changes. (No toolbar
        // items: the header bar is drawn by the window, so there is nothing to show, hide or customise.)
        menu.addItem(
            title: "Show Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), key: "s",
            modifiers: [.command, .control])
        menu.addItem(
            title: "Show Right Panel", action: #selector(NSSplitViewController.toggleInspector(_:)), key: "i",
            modifiers: [.command, .option])
        menu.add(.toggleTerminal)
        menu.addItem(.separator())
        menu.add(.groupByProject)
        menu.add(.showThreadsByState)
        menu.addItem(.separator())
        menu.add(.jumpToLatest)
        menu.add(.previousTurn)
        menu.add(.nextTurn)
        menu.add(.lastFailure)
        menu.addItem(.separator())
        menu.add(.focusComposer)
        menu.add(.focusNextRegion)
        menu.add(.focusPreviousRegion)
        menu.addItem(.separator())
        menu.addItem(
            title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control])
        return menu
    }

    private static func threadMenu() -> NSMenu {
        let menu = NSMenu(title: "Thread")
        menu.add(.sendMessage)
        menu.add(.queueFollowUp)
        menu.add(.steerFollowUp)
        menu.add(.stopRun)
        menu.add(.retryUnconfirmed)
        menu.addItem(.separator())
        menu.add(.chooseModel)
        menu.add(.permissionMode)
        menu.add(.togglePlan)
        menu.addItem(.separator())
        let requests = NSMenu(title: "Requests")
        for command in [ShellCommand.allowOnce, .allowAlways, .denyRequest, .submitAnswer] { requests.add(command) }
        requests.addItem(.separator())
        requests.add(.previousRequest)
        requests.add(.nextRequest)
        menu.addItem(submenu: requests, title: "Approvals and Questions")
        menu.addItem(.separator())
        menu.add(.togglePinThread)
        menu.add(.settleThread)
        let snooze = NSMenu(title: "Snooze")
        snooze.add(.snoozeLaterToday)
        snooze.add(.snoozeTomorrow)
        snooze.add(.snoozeNextWeek)
        snooze.add(.snoozeUntil)
        snooze.addItem(.separator())
        snooze.add(.wakeThread)
        for item in snooze.items {
            guard let action = item.action, let command = ShellCommand.command(for: action) else { continue }
            item.title = command == .snoozeUntil ? "Custom…" : SnoozePreset.title(for: command)
        }
        menu.addItem(submenu: snooze, title: "Snooze")
        menu.add(.toggleNeverAutoSettle)
        menu.addItem(.separator())
        menu.add(.renameThread)
        menu.add(.markUnread)
        menu.add(.archiveThread)
        menu.add(.deleteThread)
        menu.addItem(.separator())
        menu.add(.nextNeedsAttention)
        menu.addItem(.separator())
        // M3-A: the Agents panel (docs/features/orchestration.md).
        let agents = NSMenu(title: "Agents")
        for command in [ShellCommand.showAgents, .nextAgent, .previousAgent, .openAgent, .followUpAgent, .stopAgentTree] {
            agents.add(command)
        }
        agents.addItem(.separator())
        agents.add(.openParentThread)
        menu.addItem(submenu: agents, title: "Agents")
        // M3-B: linked merge requests (docs/features/orchestration-extras.md).
        menu.add(.showMergeRequests)
        return menu
    }

    /// Navigation: palette, quick open, history.
    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: "Go")
        menu.add(.commandPalette)
        menu.add(.quickOpen)
        menu.add(.globalSearch)
        menu.addItem(.separator())
        menu.add(.goBack)
        menu.add(.goForward)
        menu.addItem(.separator())
        menu.add(.nextNeedsAttention)
        return menu
    }

    private static func terminalMenu() -> NSMenu {
        let menu = NSMenu(title: "Terminal")
        menu.add(.newTerminal)
        menu.add(.splitTerminal)
        menu.add(.closeTerminal)
        menu.addItem(.separator())
        menu.add(.nextTerminal)
        menu.add(.previousTerminal)
        menu.addItem(.separator())
        menu.add(.renameTerminal)
        menu.add(.restartTerminal)
        menu.add(.moveTerminal)
        menu.addItem(.separator())
        menu.add(.clearTerminal)
        menu.add(.sendTerminalSelection)
        return menu
    }

    /// M2-C: diff navigation, review, revert, commit and workspace commands.
    private static func changesMenu() -> NSMenu {
        let menu = NSMenu(title: "Changes")
        menu.add(.showChanges)
        menu.addItem(.separator())
        menu.add(.nextChange)
        menu.add(.previousChange)
        menu.add(.nextChangedFile)
        menu.add(.previousChangedFile)
        menu.addItem(.separator())
        menu.add(.toggleDiffLayout)
        menu.add(.toggleDiffWhitespace)
        menu.add(.toggleDiffWrap)
        menu.addItem(.separator())
        menu.add(.addReviewComment)
        menu.add(.openInEditor)
        menu.addItem(.separator())
        menu.add(.revertHunk)
        menu.add(.revertFile)
        menu.add(.revertTurn)
        menu.addItem(.separator())
        menu.add(.commitChanges)
        menu.add(.pushBranch)
        menu.add(.createMergeRequest)
        menu.addItem(.separator())
        menu.add(.chooseWorkspace)
        menu.add(.chooseBranch)
        menu.add(.removeWorktree)
        return menu
    }

    /// GitLab 2: every GitLab action (review, merge request, pipeline, issues, to-dos) with a menu item; the palette
    /// lists them too (keyboard access for those without a shortcut).
    private static func gitLabMenu() -> NSMenu {
        let menu = NSMenu(title: "GitLab")
        menu.add(.showMergeRequests)
        menu.add(.linkMergeRequest)
        menu.add(.createMergeRequest)
        menu.add(.refreshMergeRequests)
        menu.add(.openMergeRequestInGitLab)
        menu.add(.toggleBabysit)
        menu.add(.unlinkMergeRequest)
        menu.addItem(.separator())
        menu.add(.reviewMergeRequest)
        let review = NSMenu(title: "Review")
        for command in [ShellCommand.nextReviewThread, .previousReviewThread, .replyToReviewThread, .toggleReviewThreadResolved, .addReviewThreadToAgent] {
            review.add(command)
        }
        review.addItem(.separator())
        review.add(.submitReview)
        review.add(.discardReviewDrafts)
        review.add(.closeReview)
        menu.addItem(submenu: review, title: "Review")
        menu.addItem(.separator())
        menu.add(.showFailingJobLog)
        menu.add(.sendFailureToAgent)
        menu.add(.retryFailedJob)
        menu.add(.playManualJob)
        menu.addItem(.separator())
        menu.add(.approveMergeRequest)
        menu.add(.mergeMergeRequest)
        menu.addItem(.separator())
        menu.add(.showIssues)
        menu.add(.startThreadFromIssue)
        menu.add(.linkIssueToThread)
        menu.addItem(.separator())
        menu.add(.showTodos)
        menu.add(.openTodo)
        menu.add(.markTodoDone)
        return menu
    }

    /// Git parity (docs/features/git-parity.md): the git actions, clone/publish and workspace policies.
    private static func gitMenu() -> NSMenu {
        let menu = NSMenu(title: "Git")
        menu.add(.gitQuickAction)
        menu.add(.showGitActions)
        menu.addItem(.separator())
        menu.add(.commitAndPush)
        menu.add(.pullBranch)
        menu.add(.pullRebase)
        menu.add(.fetchRemote)
        menu.add(.syncBranch)
        menu.addItem(.separator())
        menu.add(.abortGitOperation)
        menu.add(.restoreStashedChanges)
        menu.add(.moveToNewWorktree)
        menu.add(.editFromHere)
        menu.addItem(.separator())
        menu.add(.cloneFromGitLab)
        menu.add(.newGitProject)
        menu.add(.publishToGitLab)
        menu.add(.switchRemoteToHTTPS)
        menu.addItem(.separator())
        menu.add(.toggleAutoPull)
        menu.add(.toggleCleanupOnSettle)
        menu.add(.toggleCleanupOnArchive)
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m")
        menu.addItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), key: "")
        menu.addItem(.separator())
        menu.add(.showScheduledTasks)
        menu.add(.showContainers)
        menu.add(.showEnvironment)
        menu.add(.verifyIsolation)
        menu.add(.pruneContainerResources)
        menu.addItem(.separator())
        menu.addItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), key: "")
        return menu
    }

    private static func helpMenu(appName: String) -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(title: "\(appName) Help", action: #selector(NSApplication.showHelp(_:)), key: "?")
        menu.add(.showWelcome)
        return menu
    }
}

@MainActor
private extension NSMenu {
    @discardableResult
    func addItem(title: String, action: Selector?, key: String, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        addItem(item)
        return item
    }

    func add(_ command: ShellCommand) {
        let shortcut = command.shortcut
        addItem(title: command.title, action: command.selector, key: shortcut.key, modifiers: shortcut.modifiers)
    }

    func addItem(submenu: NSMenu, title: String? = nil) {
        let item = NSMenuItem(title: title ?? submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
