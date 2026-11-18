import Foundation

/// A best-effort static reading of a POSIX shell command line, for BelloCode's risk policy (docs/features/auto-mode.md).
///
/// It splits a command into simple commands (on `;`, `&&`, `||`, `|`, `&` and newlines), keeps words with their quoting
/// removed, collects redirections, and flags what it cannot see through: command or process substitution, `eval`,
/// `sh -c`, inline interpreter scripts, piping into a shell, encoded payloads, and parse errors. It is not a security
/// boundary: runtime behaviour (aliases, functions, scripts the command runs, files it reads) is invisible to it, which
/// is why anything it cannot classify goes to review or escalation, never to a deterministic allow.
public struct ShellAnalysis: Sendable, Equatable {
    public struct Redirect: Sendable, Equatable {
        public var op: String
        public var target: String
    }

    public struct Command: Sendable, Equatable {
        /// Words with quotes removed; leading `VAR=value` assignments are moved to `assignments`.
        public var words: [String]
        public var assignments: [String]
        public var redirects: [Redirect]
        /// The operator that connected this command to the previous one (`|`, `&&`, `;`, …; empty for the first).
        public var joiner: String
        /// A word that was not quoted contained `$` (variable expansion): its value is unknown statically.
        public var expandsVariables: Bool
        /// Unquoted glob characters in an argument.
        public var hasGlob: Bool

        public var program: String? { words.first.map { ($0 as NSString).lastPathComponent } }
        public var arguments: [String] { Array(words.dropFirst()) }
    }

    public var commands: [Command]
    /// Why the line cannot be analysed statically (empty when it can).
    public var opaque: [String]
    /// Variable names referenced with `$NAME` or `${NAME}` anywhere (quoted or not).
    public var variables: [String]

    public var isOpaque: Bool { !opaque.isEmpty }

    /// Interpreters that run inline code with these flags.
    static let inlineFlags: [String: Set<String>] = [
        "sh": ["-c"], "bash": ["-c"], "zsh": ["-c"], "dash": ["-c"], "ksh": ["-c"], "fish": ["-c"],
        "python": ["-c"], "python3": ["-c"], "python2": ["-c"], "node": ["-e", "--eval", "-p", "--print"],
        "bun": ["-e", "--eval"], "deno": ["eval"], "perl": ["-e", "-E"], "ruby": ["-e"], "php": ["-r"],
        "osascript": ["-e"], "lua": ["-e"], "Rscript": ["-e"], "pwsh": ["-c", "-Command"],
    ]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "pwsh"]
    static let interpreters: Set<String> = ["python", "python3", "python2", "node", "bun", "deno", "perl", "ruby", "php", "lua", "osascript"]

    public static func analyse(_ line: String) -> ShellAnalysis {
        var parser = Parser(Array(line))
        parser.run()
        var result = ShellAnalysis(commands: parser.commands, opaque: parser.opaque, variables: parser.variables)
        result.inspect()
        return result
    }

    /// Flags constructs that hide what runs.
    private mutating func inspect() {
        func flag(_ reason: String) { if !opaque.contains(reason) { opaque.append(reason) } }
        for (index, command) in commands.enumerated() {
            guard let program = command.program else { continue }
            var name = program
            var args = command.arguments
            // Wrappers that run their arguments as a command.
            while ["sudo", "doas", "env", "command", "nohup", "time", "nice", "exec", "builtin", "stdbuf", "timeout"].contains(name),
                let next = args.first
            {
                if name == "sudo" || name == "doas" { flag("runs with elevated privileges") }
                if name == "timeout", args.count > 1 { args.removeFirst() }
                if next.hasPrefix("-") || next.contains("=") {
                    args.removeFirst()
                    continue
                }
                name = (next as NSString).lastPathComponent
                args.removeFirst()
            }
            if name == "eval" { flag("eval") }
            if name == "source" || name == "." { flag("sources a script") }
            if name == "xargs" { flag("xargs runs commands built from input") }
            if let flags = Self.inlineFlags[name], args.contains(where: { arg in
                // Exact flags, or a shell's combined short flags (`-ec`, `-lc`).
                flags.contains(arg) || (Self.shells.contains(name) && arg.hasPrefix("-") && !arg.hasPrefix("--") && arg.contains("c"))
            }) {
                flag(Self.shells.contains(name) ? "runs an inline shell script" : "runs an inline \(name) script")
            }
            if Self.shells.contains(name) || Self.interpreters.contains(name) {
                if command.joiner == "|" { flag("pipes data into \(name)") }
                if command.redirects.contains(where: { $0.op.hasPrefix("<<") }) { flag("feeds a here-document to \(name)") }
                if index == 0, args.isEmpty, command.redirects.isEmpty { flag("starts \(name)") }
            }
            if name == "base64", args.contains(where: { $0 == "-d" || $0 == "--decode" || $0 == "-D" }) { flag("decodes an encoded payload") }
            if name == "xxd", args.contains("-r") { flag("decodes an encoded payload") }
            if name == "openssl", args.contains(where: { $0 == "-d" || $0 == "base64" }) { flag("decodes an encoded payload") }
            if name == "printf" || name == "echo", args.contains(where: { $0.contains("\\x") || $0.contains("\\u00") }) {
                if index + 1 < commands.count, commands[index + 1].joiner == "|" { flag("decodes an encoded payload") }
            }
            if command.words.first?.hasPrefix("$") == true { flag("runs a command named by a variable") }
        }
    }

    // MARK: Parser

    struct Parser {
        let text: [Character]
        var index = 0
        var commands: [Command] = []
        var opaque: [String] = []
        var variables: [String] = []
        var current = Command(words: [], assignments: [], redirects: [], joiner: "", expandsVariables: false, hasGlob: false)
        var word = ""
        var wordStarted = false
        var pendingRedirect: String?
        var nextJoiner = ""

        init(_ text: [Character]) { self.text = text }

        mutating func flag(_ reason: String) { if !opaque.contains(reason) { opaque.append(reason) } }

        mutating func endWord() {
            guard wordStarted else { return }
            if let op = pendingRedirect {
                current.redirects.append(Redirect(op: op, target: word))
                pendingRedirect = nil
            } else if current.words.isEmpty, isAssignment(word) {
                current.assignments.append(word)
            } else {
                current.words.append(word)
            }
            word = ""
            wordStarted = false
        }

        func isAssignment(_ value: String) -> Bool {
            guard let eq = value.firstIndex(of: "="), eq != value.startIndex else { return false }
            return value[..<eq].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }

        mutating func endCommand(_ joiner: String) {
            endWord()
            if pendingRedirect != nil {
                flag("incomplete redirection")
                pendingRedirect = nil
            }
            if !current.words.isEmpty || !current.redirects.isEmpty || !current.assignments.isEmpty {
                current.joiner = nextJoiner
                commands.append(current)
            }
            current = Command(words: [], assignments: [], redirects: [], joiner: "", expandsVariables: false, hasGlob: false)
            nextJoiner = joiner
        }

        func peek(_ offset: Int = 0) -> Character? { index + offset < text.count ? text[index + offset] : nil }

        mutating func readVariable(quoted: Bool) {
            // At `$`.
            index += 1
            guard let next = peek() else {
                word.append("$")
                return
            }
            if next == "(" {
                flag(peek(1) == "(" ? "arithmetic expansion" : "command substitution")
                word.append("$(")
                index += 1
                return
            }
            var name = ""
            if next == "{" {
                index += 1
                while let c = peek(), c != "}" {
                    name.append(c)
                    index += 1
                }
                index += 1
                if name.contains(where: { !($0.isLetter || $0.isNumber || $0 == "_") }) { flag("parameter expansion") }
            } else {
                while let c = peek(), c.isLetter || c.isNumber || c == "_" {
                    name.append(c)
                    index += 1
                }
            }
            if name.isEmpty {
                word.append("$")
                return
            }
            let bare = name.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            variables.append(String(bare))
            if !quoted { current.expandsVariables = true }
            word.append("$" + bare)
        }

        mutating func run() {
            while index < text.count {
                let c = text[index]
                switch c {
                case " ", "\t":
                    endWord()
                    index += 1
                case "\n":
                    endCommand(";")
                    index += 1
                case "#" where !wordStarted:
                    while let next = peek(), next != "\n" { index += 1 }
                case "\\":
                    if let next = peek(1) {
                        if next != "\n" {
                            word.append(next)
                            wordStarted = true
                        }
                        index += 2
                    } else {
                        index += 1
                    }
                case "'":
                    wordStarted = true
                    index += 1
                    var closed = false
                    while let next = peek() {
                        index += 1
                        if next == "'" {
                            closed = true
                            break
                        }
                        word.append(next)
                    }
                    if !closed { flag("unbalanced quotes") }
                case "\"":
                    wordStarted = true
                    index += 1
                    var closed = false
                    while let next = peek() {
                        if next == "\"" {
                            closed = true
                            index += 1
                            break
                        }
                        if next == "\\", let escaped = peek(1) {
                            word.append(escaped)
                            index += 2
                            continue
                        }
                        if next == "$" {
                            readVariable(quoted: true)
                            continue
                        }
                        if next == "`" { flag("command substitution") }
                        word.append(next)
                        index += 1
                    }
                    if !closed { flag("unbalanced quotes") }
                case "`":
                    flag("command substitution")
                    word.append(c)
                    wordStarted = true
                    index += 1
                case "$":
                    wordStarted = true
                    readVariable(quoted: false)
                case ";":
                    endCommand(peek(1) == ";" ? ";;" : ";")
                    index += peek(1) == ";" ? 2 : 1
                case "&":
                    if peek(1) == "&" {
                        endCommand("&&")
                        index += 2
                    } else if peek(1) == ">" {
                        endWord()
                        let append = peek(2) == ">"
                        pendingRedirect = append ? "&>>" : "&>"
                        index += append ? 3 : 2
                    } else {
                        endCommand("&")
                        index += 1
                    }
                case "|":
                    if peek(1) == "|" {
                        endCommand("||")
                        index += 2
                    } else {
                        endCommand("|")
                        index += peek(1) == "&" ? 2 : 1
                    }
                case "(", ")":
                    if c == "(", word.hasSuffix("<") || word.hasSuffix(">") { flag("process substitution") }
                    if c == "(" { flag("subshell") }
                    endCommand(";")
                    index += 1
                case ">", "<":
                    // A file-descriptor number right before the operator belongs to it (`2>`).
                    var op = String(c)
                    if wordStarted, !word.isEmpty, word.allSatisfy(\.isNumber) {
                        op = word + op
                        word = ""
                        wordStarted = false
                    } else {
                        endWord()
                    }
                    index += 1
                    if c == "<", peek() == "(" {
                        flag("process substitution")
                    }
                    if c == ">", peek() == "(" { flag("process substitution") }
                    while let next = peek(), next == ">" || next == "<" || next == "&" || next == "|" {
                        op.append(next)
                        index += 1
                    }
                    if op.hasSuffix("&") {
                        // `2>&1`: the descriptor follows; keep it as the target.
                        var fd = ""
                        while let next = peek(), next.isNumber || next == "-" {
                            fd.append(next)
                            index += 1
                        }
                        current.redirects.append(Redirect(op: op, target: fd))
                    } else {
                        pendingRedirect = op
                    }
                case "*", "?", "[":
                    current.hasGlob = true
                    word.append(c)
                    wordStarted = true
                    index += 1
                case "{":
                    if !wordStarted, peek(1) == " " || peek(1) == "\n" { flag("command group") }
                    word.append(c)
                    wordStarted = true
                    index += 1
                default:
                    word.append(c)
                    wordStarted = true
                    index += 1
                }
            }
            endCommand("")
        }
    }
}
