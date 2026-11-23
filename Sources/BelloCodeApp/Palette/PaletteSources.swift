import AppKit
import BelloCore
import BrowserKit
import DesignSystem
import Engine

/// Builds the palette's local candidates from the window's state, once per opening.
@MainActor
enum PaletteSourceBuilder {
    /// Commands the palette never lists (it is open already, or they only make sense from a key).
    static let hiddenCommands: Set<ShellCommand> = [.commandPalette, .quickOpen]

    static let keywords: [ShellCommand: [String]] = [
        .newThread: ["create", "session", "chat"],
        .addProject: ["open folder", "repository"],
        .archiveThread: ["hide", "remove"],
        .deleteThread: ["remove", "trash"],
        .settleThread: ["done", "complete", "finish"],
        .snoozeUntil: ["remind", "later"],
        .togglePinThread: ["favorite", "star"],
        .toggleTerminal: ["console", "shell"],
        .globalSearch: ["find", "grep"],
        .findInThread: ["search"],
        .showSettings: ["preferences", "options"],
        .stopRun: ["cancel", "interrupt"],
        .nextNeedsAttention: ["blocked", "approval", "inbox"],
        .reopenClosedThread: ["undo close", "restore"],
        .goBack: ["previous", "history"],
        .goForward: ["next", "history"],
        .newWindow: ["window"],
        .filterSidebar: ["search sidebar"],
    ]

    static func symbol(for command: ShellCommand) -> String {
        switch command {
        case .newThread: "square.and.pencil"
        case .addProject: "folder.badge.plus"
        case .archiveThread: "archivebox"
        case .deleteThread: "trash"
        case .togglePinThread, .togglePinProject: "pin"
        case .settleThread: "checkmark.circle"
        case .snoozeLaterToday, .snoozeTomorrow, .snoozeNextWeek, .snoozeUntil: "moon.zzz"
        case .wakeThread: "sun.max"
        case .toggleTerminal, .newTerminal, .clearTerminal, .closeTerminal, .splitTerminal: "terminal"
        case .globalSearch, .findInThread, .filterSidebar: "magnifyingglass"
        case .showSettings: "gearshape"
        case .stopRun: "stop.circle"
        case .sendMessage, .queueFollowUp, .steerFollowUp: "paperplane"
        case .goBack: "chevron.backward"
        case .goForward: "chevron.forward"
        case .newWindow: "macwindow.badge.plus"
        case .nextNeedsAttention: "exclamationmark.bubble"
        case .chooseModel: "cpu"
        case .allowOnce, .allowAlways: "checkmark.shield"
        case .denyRequest: "xmark.shield"
        default: "command"
        }
    }

    static func build(window: MainWindowController, now: Date = Date()) -> PaletteSources {
        let workspace = window.workspace
        var sources = PaletteSources()
        let context = window.commandContext()
        sources.commands = ShellCommand.allCases.filter { !hiddenCommands.contains($0) }.map { command in
            let shortcut = command.shortcut
            let item = PaletteItem(
                id: "command:\(command.rawValue)", kind: .command, payload: .command(command), title: context.title(for: command),
                subtitle: nil, shortcut: ShortcutText.display(key: shortcut.key, modifiers: shortcut.modifiers),
                disabledReason: context.disabledReason(for: command), symbolName: symbol(for: command))
            return PaletteCandidate(item, keywords: keywords[command] ?? [])
        }
        sources.commands += browserCommands(window: window)
        let root = workspace.engine.root
        let hidden = workspace.hiddenThreads
        var threads: [(Session, PaletteItem)] = []
        for project in root.projects {
            guard let model = workspace.projectModel(project) else { continue }
            for id in model.sessionIDs + model.archivedSessionIDs where !hidden.contains(id) {
                guard let row = model.row(id) else { continue }
                let session = row.session
                let organisation = root.organisation[id] ?? .none
                var detail = [project.name, RelativeTime.short((session.idleAt ?? session.busySince ?? session.updated).date, now: now)]
                if session.isArchived {
                    detail.append("Archived")
                } else if let status = row.status?.status, status != .idle {
                    detail.append(StatusGlyph(status).label)
                } else if organisation.isSnoozed {
                    detail.append("Snoozed")
                } else if organisation.settled {
                    detail.append("Settled")
                }
                let item = PaletteItem(
                    id: "thread:\(id.rawValue)", kind: .thread, payload: .thread(id), title: session.displayTitle,
                    subtitle: detail.joined(separator: " · "), symbolName: session.isArchived ? "archivebox" : (organisation.pinned ? "pin" : "bubble.left"))
                threads.append((session, item))
            }
        }
        threads.sort { lhs, rhs in
            let a = lhs.0.idleAt ?? lhs.0.busySince ?? lhs.0.updated
            let b = rhs.0.idleAt ?? rhs.0.busySince ?? rhs.0.updated
            return a != b ? a > b : lhs.1.id < rhs.1.id
        }
        sources.threads = threads.map { PaletteCandidate($0.1) }
        sources.projects = (root.projects + root.hiddenProjects).map { project in
            let archived = project.entry.archived
            let item = PaletteItem(
                id: "project:\(project.directory)", kind: .project,
                payload: .project(directory: project.directory, isArchived: archived), title: project.name,
                subtitle: (project.directory as NSString).abbreviatingWithTildeInPath + (archived ? " · Archived" : ""),
                symbolName: project.isPinned ? "pin" : "folder")
            return PaletteCandidate(item, secondary: project.directory)
        }
        if let work = workspace.engine.extras?.gitLabWork {
            // The cached list; the open palette refreshes it in the background (`refreshTodos`).
            sources.todos = todoItems(work.allTodos, now: now)
        }
        return sources
    }

    /// Reloads the person's GitLab to-dos (bounded by the service's two-minute cache) and returns them as rows; nil
    /// without GitLab. The palette shows them in place while it is open (NF20).
    static func refreshTodos(window: MainWindowController, now: @escaping () -> Date = Date.init) async -> [PaletteCandidate]? {
        guard let work = window.workspace.engine.extras?.gitLabWork else { return nil }
        let service = work.mergeRequests
        for instance in service.instances where service.instancesWithToken.contains(instance.baseURL) {
            guard !Task.isCancelled else { return nil }
            await work.loadTodos(instance)
        }
        return todoItems(work.allTodos, now: now())
    }

    /// The Browser menu's commands (built-in browser and shared Chrome), so every one is reachable from ⌘K (NF20).
    static func browserCommands(window: MainWindowController) -> [PaletteCandidate] {
        var items: [PaletteCandidate] = []
        let browser = window.browser
        let show = PaletteItem(
            id: "command:browser.show", kind: .command, payload: .browser(nil), title: "Show Browser", subtitle: "Browser",
            shortcut: ShortcutText.display(key: "b", modifiers: [.command, .control]),
            disabledReason: browser == nil ? "This window has no browser" : nil, symbolName: "safari")
        items.append(PaletteCandidate(show, keywords: ["web", "preview"]))
        for entry in BrowserMenu.items.flatMap({ $0 }) {
            let item = PaletteItem(
                id: "command:browser.\(entry.command.rawValue)", kind: .command, payload: .browser(entry.command), title: entry.title,
                subtitle: "Browser", shortcut: ShortcutText.display(key: entry.key, modifiers: entry.modifiers),
                disabledReason: browser?.canPerform(entry.command) == true ? nil : "Not available in the browser now", symbolName: "safari")
            items.append(PaletteCandidate(item, keywords: ["browser", "web"]))
        }
        let service = window.workspace.engine.sharedBrowser
        for command in SharedChromeMenu.Command.allCases {
            let enabled = service.map { SharedChromeMenuRouter.isEnabled(command, service: $0) } ?? false
            let item = PaletteItem(
                id: "command:sharedChrome.\(command.rawValue)", kind: .command, payload: .sharedChrome(command), title: command.title,
                subtitle: "Browser ▸ Shared Chrome",
                shortcut: command == .show ? ShortcutText.display(key: "b", modifiers: [.command, .control, .option]) : nil,
                disabledReason: enabled ? nil : "Not available for the shared Chrome now", symbolName: "globe.americas")
            items.append(PaletteCandidate(item, keywords: ["chrome", "chromium", "browser"]))
        }
        return items
    }

    /// GitLab to-dos as palette rows: "Review requested: !42 Add launch checklist" · project · author · age.
    static func todoItems(_ todos: [(instance: String, todo: GitLabTodo)], now: Date) -> [PaletteCandidate] {
        todos.map { entry in
            let todo = entry.todo
            let detail = [todo.projectPath, todo.author.isEmpty ? nil : "@\(todo.author)", todo.created.map { RelativeTime.short($0, now: now) }].compactMap { $0 }
            let item = PaletteItem(
                id: "todo:\(entry.instance)#\(todo.id)", kind: .todo, payload: .todo(instance: entry.instance, id: todo.id),
                title: "\(todo.actionLabel): \(todo.targetLabel) \(todo.targetTitle)", subtitle: detail.joined(separator: " · "), symbolName: "checklist")
            return PaletteCandidate(item, keywords: ["todo", "gitlab"], secondary: todo.projectPath)
        }
    }

    static func fileItems(_ paths: [String], directory: String) -> [PaletteCandidate] {
        paths.map { path in
            let name = (path as NSString).lastPathComponent
            let folder = (path as NSString).deletingLastPathComponent
            let item = PaletteItem(
                id: "file:\(directory)/\(path)", kind: .file, payload: .file(directory: directory, path: path), title: name,
                subtitle: folder.isEmpty ? nil : folder, symbolName: "doc")
            return PaletteCandidate(item, secondary: path)
        }
    }
}
