import BelloCore
import Foundation

/// What a permission request asks, in the user's terms, plus what each reply authorises and for how long.
///
/// The contract leaves `action` open (`string`); built-in actions seen in opencode 2.3.0 have specific wording, and
/// anything else (plugins, MCP tools) falls back to a neutral description that still shows the raw action and
/// resources. The scope texts follow verified server behaviour: "always" saves a rule per *project* (every thread in
/// it, kept across restarts, listed under `GET /api/permission/saved`), not per thread.
public struct PermissionPresentation: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case command, edit, read, search, outsideProject, web, subagent, skill, browser, question, repetition, other
    }

    public struct Choice: Hashable, Sendable {
        public var title: String
        /// What the reply authorises, and for how long.
        public var detail: String
        public var isAvailable: Bool
    }

    public var kind: Kind
    /// SF Symbol name.
    public var symbolName: String
    /// Short imperative title: "Run a command".
    public var title: String
    /// One line: "npm test" / "Sources/App.swift and 2 more".
    public var summary: String
    /// The operation itself, one entry per resource, shown monospaced (commands, paths relative to the directory).
    public var targets: [String]
    /// Whether `targets` are shell commands (shown as a code block) rather than paths or names.
    public var targetsAreCommands: Bool
    /// A caution the user should read before allowing (secrets, outside the project, destructive command).
    public var caution: String?
    public var allowOnce: Choice
    public var allowAlways: Choice
    public var deny: Choice
    /// The patterns an "always" reply saves, as `action pattern` lines (raw form).
    public var alwaysRules: [String]
    /// VoiceOver announcement, once per request.
    public var announcement: String

    /// - Parameters:
    ///   - directory: the session's working directory; paths inside it are shown relative.
    ///   - projectName: shown in the "always" scope.
    public init(_ request: PermissionRequest, directory: String?, projectName: String?) {
        let action = request.action
        let resources = request.resources
        let relative = resources.map { Self.relativePath($0, to: directory) }
        let project = projectName.map { "“\($0)”" } ?? "this project"
        var caution: String?
        var commands = false
        switch action {
        case "shell", "bash":
            kind = .command
            symbolName = "terminal"
            title = resources.count > 1 ? "Run \(resources.count) commands" : "Run a command"
            targets = resources
            commands = true
            if resources.contains(where: Self.looksDestructive) { caution = "This command can delete or overwrite files." }
        case "edit", "write", "patch", "multiedit":
            kind = .edit
            symbolName = "pencil"
            title = resources.count > 1 ? "Edit \(resources.count) files" : "Edit a file"
            targets = relative
        case "read", "list":
            kind = .read
            symbolName = action == "list" ? "folder" : "doc.text"
            title = action == "list" ? "List a folder" : (resources.count > 1 ? "Read \(resources.count) files" : "Read a file")
            targets = relative
            if resources.contains(where: Self.isSecretFile) {
                caution = "Environment files often contain secrets such as API keys. The agent will see the contents."
            }
        case "glob", "grep", "codesearch":
            kind = .search
            symbolName = "magnifyingglass"
            title = action == "grep" ? "Search file contents" : (action == "glob" ? "Find files" : "Search code")
            targets = resources
        case "external_directory":
            kind = .outsideProject
            symbolName = "folder.badge.questionmark"
            title = "Work outside the project"
            targets = resources
            caution = "The agent wants to use files outside \(directory.map { Self.lastComponent($0) } ?? "the project folder")."
        case "webfetch":
            kind = .web
            symbolName = "globe"
            title = "Fetch a web page"
            targets = resources
        case "websearch":
            kind = .web
            symbolName = "globe"
            title = "Search the web"
            targets = resources
        case "subagent", "task":
            kind = .subagent
            symbolName = "person.2"
            title = "Start a sub-agent"
            targets = resources
        case "skill":
            kind = .skill
            symbolName = "sparkles"
            title = "Use a skill"
            targets = resources
        case "browser":
            kind = .browser
            symbolName = "safari"
            title = "Control the browser"
            targets = resources
        case "question":
            kind = .question
            symbolName = "questionmark.bubble"
            title = "Ask you a question"
            targets = resources
        case "doom_loop":
            kind = .repetition
            symbolName = "arrow.triangle.2.circlepath"
            title = "Keep repeating the same step"
            targets = resources
            caution = "The agent called the same tool with the same input several times in a row."
        default:
            kind = .other
            symbolName = "wrench.and.screwdriver"
            title = "Use “\(Self.humanize(action))”"
            targets = resources
        }
        self.caution = caution
        targetsAreCommands = commands
        let shownTargets = targets.filter { !$0.isEmpty && $0 != "*" }
        summary =
            switch shownTargets.count {
            case 0: request.message ?? "No details given"
            case 1: shownTargets[0]
            default: "\(shownTargets[0]) and \(shownTargets.count - 1) more"
            }

        let saved = request.alwaysScopes.isEmpty ? [] : request.alwaysScopes
        alwaysRules = saved.map { "\(action) \($0)" }
        let noun = Self.noun(kind, count: max(resources.count, 1))
        allowOnce = Choice(
            title: "Allow once", detail: "Allows only this \(noun). The agent asks again next time.", isAvailable: true)
        if saved.isEmpty {
            allowAlways = Choice(
                title: "Always allow", detail: "opencode offered no reusable rule for this request.", isAvailable: false)
        } else {
            let patterns = saved.map { "“\($0)”" }.joined(separator: ", ")
            allowAlways = Choice(
                title: "Always allow",
                detail: "Saves a rule for \(project): \(Self.verb(kind)) matching \(patterns) without asking, in every "
                    + "thread of the project, until you remove the rule.",
                isAvailable: true)
        }
        deny = Choice(
            title: "Deny", detail: "The \(noun) does not happen. The agent is told and decides what to do next.",
            isAvailable: true)
        announcement = "Approval needed: \(title). \(summary)"
    }

    // MARK: Helpers

    static func relativePath(_ path: String, to directory: String?) -> String {
        guard let directory, !directory.isEmpty else { return path }
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        if path.hasPrefix(base) { return String(path.dropFirst(base.count)) }
        if path == directory { return "." }
        return path
    }

    static func lastComponent(_ path: String) -> String { (path as NSString).lastPathComponent }

    static func isSecretFile(_ path: String) -> Bool {
        let name = lastComponent(path)
        if name == ".env.example" || name.hasSuffix(".example") { return false }
        return name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env")
    }

    static func looksDestructive(_ command: String) -> Bool {
        let tokens = command.lowercased().split(whereSeparator: { $0 == " " || $0 == ";" || $0 == "&" || $0 == "|" }).map(String.init)
        let destructive: Set<String> = ["rm", "rmdir", "mv", "dd", "mkfs", "shred", "truncate", "chmod", "chown"]
        if tokens.contains(where: destructive.contains) { return true }
        let lower = command.lowercased()
        return lower.contains("git reset --hard") || lower.contains("git clean") || lower.contains("git push --force")
            || lower.contains("> /") || lower.contains("sudo ")
    }

    static func humanize(_ action: String) -> String {
        action.replacingOccurrences(of: "__", with: " › ").replacingOccurrences(of: "_", with: " ")
    }

    static func noun(_ kind: Kind, count: Int) -> String {
        let plural = count > 1
        switch kind {
        case .command: return plural ? "set of commands" : "command"
        case .edit: return plural ? "set of edits" : "edit"
        case .read: return plural ? "set of reads" : "read"
        case .search: return "search"
        case .outsideProject: return "access"
        case .web: return "request"
        case .subagent: return "sub-agent"
        case .skill: return "skill use"
        case .browser: return "browser action"
        case .question: return "question"
        case .repetition: return "step"
        case .other: return "action"
        }
    }

    static func verb(_ kind: Kind) -> String {
        switch kind {
        case .command: "run commands"
        case .edit: "edit files"
        case .read: "read files"
        case .search: "search"
        case .outsideProject: "use folders"
        case .web: "fetch pages"
        case .subagent: "start sub-agents"
        case .skill: "use skills"
        case .browser: "control the browser"
        case .question: "ask questions"
        case .repetition: "repeat steps"
        case .other: "use it"
        }
    }
}
