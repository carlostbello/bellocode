import BelloCore
import Foundation

/// BelloCode's deterministic risk policy (docs/features/auto-mode.md). Pure: no I/O except resolving symlinks of
/// paths, no actors. Auto uses `decide`; Full access uses `notices`.
///
/// Precedence (a model can override neither list): configured hard denies → mandatory escalations → deterministic
/// allows → the reviewer for the remainder. opencode's own configured denies are applied before any of this (the
/// server never asks for them). Static analysis of shell commands is best effort: whatever it cannot see through is
/// escalated or reviewed, never allowed deterministically.
public enum RiskPolicy {
    /// Bumped whenever a list or rule changes. Every Auto decision and audit entry records it.
    public static let version = "bellocode-auto-5"

    /// Where the session works, and what it must never touch.
    public struct Context: Sendable, Equatable {
        /// The session's directory (relative paths and `cd` start here).
        public var directory: String
        /// The project root and its worktrees: inside these is "in the project".
        public var roots: [String]
        public var home: String
        /// BelloCode's and opencode's own data and configuration: touching them is a hard deny.
        public var protected: [String]

        /// Configured code roots (`CodeRoots`): folders the developer works across. Inside one is in scope (no
        /// escalation or notice for location alone; secrets and risky actions still count).
        public var trusted: [String]

        public init(
            directory: String, roots: [String], home: String = NSHomeDirectory(), protected: [String] = [], trusted: [String] = []
        ) {
            self.directory = directory
            self.roots = roots.isEmpty ? [directory] : roots
            self.home = home
            self.protected = protected + Self.standardProtected(home: home)
            self.trusted = trusted
            self.canonicalRoots = self.roots.map { Paths.canonical($0, base: "/", home: home) }
            self.canonicalProtected = self.protected.map { Paths.canonical($0, base: "/", home: home) }
            self.canonicalTrusted = trusted.filter { !$0.isEmpty }.map { Paths.canonical($0, base: "/", home: home) }.filter { $0 != "/" }
        }

        let canonicalRoots: [String]
        let canonicalProtected: [String]
        let canonicalTrusted: [String]

        static func standardProtected(home: String) -> [String] {
            [
                home + "/.config/opencode", home + "/.local/share/opencode", home + "/.local/state/opencode",
                home + "/Library/Application Support/BelloCode", home + "/Library/Keychains", home + "/.rd/docker.sock",
                "/var/run/docker.sock",
            ]
        }

        public static func == (lhs: Context, rhs: Context) -> Bool {
            lhs.directory == rhs.directory && lhs.roots == rhs.roots && lhs.home == rhs.home && lhs.protected == rhs.protected
                && lhs.trusted == rhs.trusted
        }

        /// In this project or its worktrees.
        func inProject(_ canonical: String) -> Bool { canonicalRoots.contains { Paths.contains($0, canonical) } }
        /// In scope: the project, its worktrees, or a configured code root.
        func inside(_ canonical: String) -> Bool { inProject(canonical) || inCodeRoot(canonical) }
        func inCodeRoot(_ canonical: String) -> Bool { canonicalTrusted.contains { Paths.contains($0, canonical) } }
        func isProtected(_ canonical: String) -> Bool {
            canonicalProtected.contains { Paths.contains($0, canonical) } || canonical.hasSuffix("/docker.sock")
                || (canonical as NSString).lastPathComponent == "bellocode-exec.json"
        }
        /// A short label for a path: project-relative inside, `~/…` under home, absolute otherwise.
        func label(_ canonical: String) -> String {
            for root in canonicalRoots where Paths.contains(root, canonical) {
                let relative = String(canonical.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return relative.isEmpty ? "." : relative
            }
            let home = Paths.canonical(self.home, base: "/", home: self.home)
            if Paths.contains(home, canonical) { return "~" + canonical.dropFirst(home.count) }
            return canonical
        }
    }

    /// An action to judge: a permission request (action + resources) and, when known, the tool call's input.
    public struct Action: Sendable, Equatable {
        /// opencode's permission action (`read`, `edit`, `shell`, `external_directory`, `webfetch`, an MCP tool's
        /// `server_tool`, …) or, for a notice, the tool's name.
        public var action: String
        public var resources: [String]
        /// From the tool call, when the request names one.
        public var tool: String?
        public var command: String?
        public var paths: [String]
        public var urls: [String]

        public init(action: String, resources: [String] = [], tool: String? = nil, command: String? = nil, paths: [String] = [], urls: [String] = []) {
            self.action = action
            self.resources = resources
            self.tool = tool
            self.command = command
            self.paths = paths
            self.urls = urls
        }
    }

    public enum Verdict: Sendable, Equatable {
        /// Refused outright (a policy violation); the reason is shown to the agent.
        case deny(RiskFinding)
        /// Mandatory: the person decides.
        case escalate([RiskFinding])
        /// Deterministic allow (`reasonCode`, short explanation).
        case allow(String, String)
        /// Neither: the reviewer decides (a short description of what it is).
        case review(String)

        public var isAllow: Bool { if case .allow = self { true } else { false } }
    }

    // MARK: - Auto

    ///
    /// Reads the file system (path resolution, and the tree a `grep -r` searches): call it off the main actor.
    public static func decide(_ action: Action, in context: Context) -> Verdict {
        var findings = self.findings(action, in: context)
        if findings.isEmpty, action.action == "shell" { findings = recursiveSearchFindings(action, in: context) }
        if let violation = findings.first(where: { $0.category == .policyViolation }) { return .deny(violation) }
        let mandatory = findings.filter { $0.category != .policyViolation }
        if !mandatory.isEmpty { return .escalate(unique(mandatory)) }
        if let allow = deterministicAllow(action, in: context) { return .allow(allow.0, allow.1) }
        return .review(describe(action))
    }

    // MARK: - Recursive searches

    /// Entries a `grep -r` tree check reads before it gives up (and escalates).
    static let searchScanLimit = 20_000

    /// Recursive reads (N05, AF14): `grep -r` reads every file under the folders it searches, hidden, ignored and
    /// dependency folders (`.git`, `node_modules`) included; so do `diff -r`, `git diff --no-index` and a `git grep`
    /// told to search untracked or ignored files. When one of them looks like a secret (`.env`, keys, credentials), or
    /// the tree is too large to tell, the person decides. For grep, `--include`/`--exclude`/`--exclude-dir` (and BSD
    /// `--include-dir`) are applied in order, the last matching rule winning, as GNU and BSD grep both do; a file
    /// counts as read when either implementation would read it. The command is read with both implementations'
    /// option grammars, abbreviations included, and an option neither knows counts as recursive with and without a
    /// value (GW02, AF14). Links are followed as grep follows them. Operands the shell would glob are expanded;
    /// anything whose effect cannot be established statically (a variable, a brace expansion, a glob the shell would
    /// expand in an option or the pattern, an operand or folder that cannot be examined) is a finding of its own, so
    /// the person decides (GV03). Bounded.
    static func recursiveSearchFindings(_ action: Action, in context: Context) -> [RiskFinding] {
        let lines = action.command.map { [$0] } ?? action.resources
        var found: [RiskFinding] = []
        for line in lines {
            var cwd = context.directory
            for command in ShellAnalysis.analyse(line).commands {
                guard let name = command.program else { continue }
                let args = command.arguments
                if name == "cd" {
                    cwd = args.first(where: { !$0.hasPrefix("-") }).map { Paths.canonical($0, base: cwd, home: context.home) } ?? context.home
                    continue
                }
                if let finding = otherRecursiveReadFinding(name, args, command: command, cwd: cwd, in: context) {
                    found.append(finding)
                    continue
                }
                guard ["grep", "egrep", "fgrep"].contains(name) else { continue }
                let readings = GrepSearch.readings(args)
                guard !readings.isEmpty else { continue }
                if command.expandsVariables {
                    // Unknown words could be operands or options: what it reads cannot be established.
                    found.append(RiskFinding(.secretRead, "grep -r with a shell variable (secret files could not be ruled out)"))
                    continue
                }
                if !command.braceWords.isEmpty {
                    // `{a,b}` becomes several words (operands, options or the pattern): not what was written.
                    found.append(RiskFinding(.secretRead, "grep -r with a brace expansion (secret files could not be ruled out)"))
                    continue
                }
                // Every reading must be clean: the first finding of any of them is the command's.
                for search in readings {
                    if let finding = grepFinding(search, args: args, command: command, cwd: cwd, in: context) {
                        found.append(finding)
                        break
                    }
                }
            }
        }
        return found
    }

    /// What one reading of a recursive grep reads that the person must decide on, if anything.
    static func grepFinding(_ search: GrepSearch, args: [String], command: ShellAnalysis.Command, cwd: String, in context: Context) -> RiskFinding? {
        // Word indices in `args` are one less than in `words` (the program is word 0).
        let globArgs = Set(command.globWords.filter { $0 > 0 }.map { $0 - 1 })
        for index in globArgs.sorted() where !search.operandIndices.contains(index) {
            // A glob in an option, its value or the pattern: the shell may replace it with file names and shift every
            // word after it.
            let pattern = Paths.canonical(args[index], base: cwd, home: context.home)
            if expandGlob(pattern, dotfiles: false) != [pattern] {
                return RiskFinding(.secretRead, "grep -r with an option or pattern the shell expands to file names (secret files could not be ruled out)")
            }
        }
        var roots: [(path: String, spelled: [String])] = []
        let operands = search.operandIndices.isEmpty ? [(index: -1, text: ".")] : search.operandIndices.map { (index: $0, text: args[$0]) }
        for operand in operands {
            let path = Paths.canonical(operand.text, base: cwd, home: context.home)
            if globArgs.contains(operand.index) {
                // As the shell expands it, and (in case `dotglob` is set) with hidden names as well.
                for match in expandGlob(path, dotfiles: true) { roots.append((match, [match])) }
            } else {
                roots.append((path, [operand.text, path]))
            }
        }
        return secretFile(under: roots, search: search, context: context).map { RiskFinding(.secretRead, $0) }
    }

    /// `diff -r`, `git diff --no-index` and `git grep --no-index`/`--untracked`/`--no-exclude-standard` read whole
    /// trees, untracked and ignored files included: a secret-looking file in them asks (AF14's class). Every word that
    /// names an existing path counts as a tree (a superset of the operands), and for `git grep` the current folder too.
    static func otherRecursiveReadFinding(_ name: String, _ args: [String], command: ShellAnalysis.Command, cwd: String, in context: Context) -> RiskFinding? {
        let recursive: Bool
        var includeCurrent = false
        switch name {
        case "diff":
            recursive = args.contains { OptionSyntax.cluster($0, contains: ["r"]) || OptionSyntax.abbreviates($0, ["recursive"]) }
        case "git":
            guard let sub = args.first else { return nil }
            let tail = args.dropFirst()
            if sub == "diff" {
                recursive = tail.contains { OptionSyntax.abbreviates($0, ["no-index"]) }
            } else if sub == "grep" {
                recursive = tail.contains { OptionSyntax.abbreviates($0, ["no-index", "untracked", "no-exclude-standard"]) }
                includeCurrent = true
            } else {
                return nil
            }
        default:
            return nil
        }
        guard recursive else { return nil }
        if command.expandsVariables || !command.braceWords.isEmpty || command.hasGlob {
            return RiskFinding(.secretRead, "\(name) over a tree with words the shell rewrites (secret files could not be ruled out)")
        }
        var roots: [(path: String, spelled: [String])] = includeCurrent ? [(cwd, [cwd])] : []
        for arg in args where !arg.hasPrefix("-") {
            let path = Paths.canonical(arg, base: cwd, home: context.home)
            if FileManager.default.fileExists(atPath: path) { roots.append((path, [arg, path])) }
        }
        var search = GrepSearch()
        search.followsLinks = name == "diff"  // GNU diff follows links unless told not to
        return secretFile(under: roots, search: search, context: context).map { RiskFinding(.secretRead, $0) }
    }

    /// The parts of a recursive grep that decide what it reads, in one reading of its arguments.
    struct GrepSearch: Equatable {
        /// An `--include`/`--exclude` (files) or `--include-dir`/`--exclude-dir` (folders) rule, in command-line order.
        /// A nil glob never matches: `--exclude-from` rules this check does not read (they can only exclude more).
        struct Rule: Equatable {
            var include: Bool
            var glob: String?

            func matches(_ candidates: [String]) -> Bool {
                guard let glob else { return false }
                return candidates.contains { fnmatch(glob, $0, 0) == 0 }
            }
        }

        /// Indices into the arguments of the operands (the files and folders searched).
        var operandIndices: [Int] = []
        var fileRules: [Rule] = []
        var folderRules: [Rule] = []
        /// `-R` (`--dereference-recursive`, or BSD `-S`): links met inside the tree are followed too. Plain `-r`
        /// follows only links named on the command line.
        var followsLinks = false

        /// How far one reading has got.
        private struct Reading {
            var index = 0
            var recursive = false
            var patternGiven = false
            var positional: [Int] = []
            var search = GrepSearch()

            mutating func apply(_ option: String, _ value: String?) {
                switch option {
                case "recursive", "r": recursive = true
                case "dereference-recursive", "R":
                    recursive = true
                    search.followsLinks = true
                case "S": search.followsLinks = true
                // GNU accepts an abbreviation of `recurse`, BSD any case: anything but `read` or `skip` may recurse.
                case "directories", "d": if !["read", "skip"].contains(value?.lowercased() ?? "") { recursive = true }
                case "regexp", "file", "e", "f": patternGiven = true
                case "include": search.fileRules.append(Rule(include: true, glob: value))
                case "exclude": search.fileRules.append(Rule(include: false, glob: value))
                case "exclude-from": search.fileRules.append(Rule(include: false, glob: nil))
                case "exclude-dir": search.folderRules.append(Rule(include: false, glob: value))
                case "include-dir": search.folderRules.append(Rule(include: true, glob: value))
                default: break
                }
            }
        }

        /// Readings beyond which the command is not worth telling apart: it is read as searching everything.
        static let readingLimit = 64

        /// Every way grep could read `args` that searches recursively; empty when none does. Each implementation's
        /// grammar (GNU, BSD) gives one reading; an option a grammar does not know, or abbreviates ambiguously, is read
        /// both with and without a value, and as recursive (another version could know it).
        static func readings(_ args: [String]) -> [GrepSearch] {
            var results: [GrepSearch] = []
            func add(_ search: GrepSearch) { if !results.contains(search) { results.append(search) } }
            for grammar in [GrepGrammar.gnu, .bsd] {
                var pending = [Reading()]
                var processed = 0
                while var reading = pending.popLast() {
                    processed += 1
                    if processed > readingLimit {
                        // Too many unknown options to follow: every word could be an operand, and links are followed.
                        var everything = GrepSearch()
                        everything.operandIndices = args.indices.filter { !args[$0].hasPrefix("-") }
                        everything.followsLinks = true
                        add(everything)
                        break
                    }
                    while reading.index < args.count {
                        let arg = args[reading.index]
                        let next = reading.index + 1 < args.count ? args[reading.index + 1] : nil
                        if arg == "--" {
                            reading.positional += Array((reading.index + 1)..<args.count)
                            break
                        }
                        if let name = OptionSyntax.longName(arg) {
                            let attached = arg.firstIndex(of: "=").map { String(arg[arg.index(after: $0)...]) }
                            let candidates = grammar.resolve(name)
                            guard candidates.count == 1 else {
                                reading.recursive = true
                                reading.search.followsLinks = true
                                if attached == nil, next != nil {
                                    var withValue = reading
                                    withValue.index += 2
                                    pending.append(withValue)
                                }
                                reading.index += 1
                                continue
                            }
                            let option = candidates[0]
                            if attached == nil, option.value == .required {
                                reading.apply(option.meaning, next)
                                reading.index += 2
                            } else {
                                reading.apply(option.meaning, attached)
                                reading.index += 1
                            }
                            continue
                        }
                        if OptionSyntax.isShortCluster(arg) {
                            let letters = Array(arg.dropFirst())
                            var width = 1
                            for (position, letter) in letters.enumerated() {
                                let rest = position + 1 < letters.count ? String(letters[(position + 1)...]) : nil
                                if grammar.shortRequired.contains(letter) {
                                    if rest == nil { width = 2 }
                                    reading.apply(String(letter), rest ?? next)
                                    break
                                }
                                if grammar.shortOptional.contains(letter) {
                                    reading.apply(String(letter), rest)
                                    break
                                }
                                reading.apply(String(letter), nil)
                            }
                            reading.index += width
                            continue
                        }
                        reading.positional.append(reading.index)
                        reading.index += 1
                    }
                    guard reading.recursive else { continue }
                    var search = reading.search
                    search.operandIndices = reading.patternGiven ? reading.positional : Array(reading.positional.dropFirst())
                    add(search)
                }
            }
            return results
        }

        /// The last matching rule's verdict (include or not), or nil when none matches any of `candidates`.
        private static func lastMatch(_ rules: [Rule], _ candidates: [String]) -> Bool? {
            rules.last { $0.matches(candidates) }?.include
        }

        /// Whether grep reads the file `name`. `spelled` are the ways grep can spell its path (as given on the command
        /// line, and canonical); `commandLine` is true for a file named as an operand.
        /// GNU: last matching rule wins; with none, the file is read unless the first rule is an `--include`. Below an
        /// operand it matches the base name, for an operand any name suffix after a `/`. BSD (measured, 2.6.0-FreeBSD
        /// on macOS): the same order rule, matched against the base name and the whole path. Read when either reads.
        func reads(_ name: String, spelled: [String] = [], commandLine: Bool = false) -> Bool {
            guard let first = fileRules.first else { return true }
            let fallback = !first.include
            var gnuNames = [name]
            if commandLine {
                for path in spelled {
                    var rest = Substring(path)
                    gnuNames.append(String(rest))
                    while let slash = rest.firstIndex(of: "/") {
                        rest = rest[rest.index(after: slash)...]
                        if let next = rest.first, next != "/" { gnuNames.append(String(rest)) }
                    }
                }
            }
            let gnu = Self.lastMatch(fileRules, gnuNames) ?? fallback
            let bsd = (spelled.isEmpty ? [[name]] : spelled.map { [name, $0] }).contains { Self.lastMatch(fileRules, $0) ?? fallback }
            return gnu || bsd
        }

        /// Whether grep enters the folder `name` below an operand (operands are always treated as entered). GNU skips
        /// a folder any `--exclude-dir` matches (it has no `--include-dir`); BSD applies the order rule (the last
        /// matching rule wins; with none, entered unless the first rule is `--include-dir`). Entered when either enters.
        func enters(_ name: String) -> Bool {
            let gnu = !folderRules.contains { !$0.include && $0.matches([name]) }
            let bsd = Self.lastMatch(folderRules, [name]) ?? !(folderRules.first?.include ?? false)
            return gnu || bsd
        }
    }

    /// The paths the shell gives for an operand with glob characters (the operand itself when nothing matches, as the
    /// shell leaves it). With `dotfiles`, names starting with a dot are matched too in the last component (as with
    /// bash's `dotglob`), so a setting the preflight cannot see never hides a file from it.
    static func expandGlob(_ pattern: String, dotfiles: Bool) -> [String] {
        func run(_ pattern: String) -> [String] {
            var result = glob_t()
            defer { globfree(&result) }
            guard glob(pattern, 0, nil, &result) == 0 else { return [] }
            return (0..<Int(result.gl_pathc)).compactMap { result.gl_pathv[$0].map { String(cString: $0) } }
        }
        var paths = run(pattern)
        if dotfiles {
            let folder = (pattern as NSString).deletingLastPathComponent
            let last = (pattern as NSString).lastPathComponent
            if let first = last.first, "*?[".contains(first) {
                let hidden = run((folder as NSString).appendingPathComponent("." + last)).filter {
                    let base = ($0 as NSString).lastPathComponent
                    return base != "." && base != ".."
                }
                paths += hidden.filter { !paths.contains($0) }
            }
        }
        return paths.isEmpty ? [pattern] : paths
    }

    /// The first secret-looking file a recursive grep would read, or a note that the tree is too large or cannot be
    /// examined. Traverses as grep does: every folder the folder rules let in; operands through their links; links
    /// inside the tree only with `-R` (each folder once, so a link cycle ends). A link that grep would skip is still
    /// reported when its name looks like a secret (grep implementations differ; the person decides). An operand that
    /// does not exist, or a folder or entry that cannot be read, is reported too: what grep reads there is unknown.
    static func secretFile(under roots: [(path: String, spelled: [String])], search: GrepSearch, context: Context) -> String? {
        let unknown = "grep -r over a path that could not be examined (secret files could not be ruled out)"
        var seen = 0
        var visited = Set<[UInt64]>()
        // Each entry: the path, how grep spells it, and whether it is an operand.
        var pending: [(path: String, spelled: [String], isRoot: Bool)] = roots.map { ($0.path, $0.spelled, true) }
        while let (path, spelled, isRoot) = pending.popLast() {
            var info = stat()
            // Operands are followed; inside the tree only with -R.
            guard (isRoot || search.followsLinks ? stat(path, &info) : lstat(path, &info)) == 0 else {
                if isRoot { return unknown }
                continue
            }
            if info.st_mode & S_IFMT != S_IFDIR {
                let name = (path as NSString).lastPathComponent
                if secretName(name) != nil, search.reads(name, spelled: spelled, commandLine: isRoot) { return context.label(path) }
                continue
            }
            guard visited.insert([UInt64(bitPattern: Int64(info.st_dev)), UInt64(info.st_ino)]).inserted else { continue }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return unknown }
            for name in names {
                seen += 1
                if seen > searchScanLimit { return "grep -r over more than \(searchScanLimit) files (secret files could not be ruled out)" }
                let child = (path as NSString).appendingPathComponent(name)
                let childSpelled = spelled.map { $0.hasSuffix("/") ? $0 + name : $0 + "/" + name }
                var childInfo = stat()
                guard lstat(child, &childInfo) == 0 else { return unknown }
                var kind = childInfo.st_mode & S_IFMT
                if kind == S_IFLNK {
                    if secretName(name) != nil, search.reads(name, spelled: childSpelled) { return context.label(child) }
                    guard search.followsLinks else { continue }
                    var target = stat()
                    guard stat(child, &target) == 0 else { continue }
                    kind = target.st_mode & S_IFMT
                    // grep reads the target: a link named innocently can still point at a secret.
                    let targetName = URL(fileURLWithPath: child).resolvingSymlinksInPath().lastPathComponent
                    if kind != S_IFDIR, secretName(targetName) != nil, search.reads(name, spelled: childSpelled) { return context.label(child) }
                }
                if kind == S_IFDIR {
                    if search.enters(name) { pending.append((child, childSpelled, false)) }
                } else if secretName(name) != nil, search.reads(name, spelled: childSpelled) {
                    return context.label(child)
                }
            }
        }
        return nil
    }

    // MARK: - Full access notices

    /// What Full access surfaces for a finished or attempted tool call: the same detectors, best effort.
    public static func notices(tool: String, input: [String: Any?], evaluated: [(action: String, resources: [String])], in context: Context) -> [RiskFinding] {
        var actions = [toolAction(tool: tool, input: input)]
        for item in evaluated { actions.append(Action(action: item.action, resources: item.resources, tool: tool)) }
        var all: [RiskFinding] = []
        for action in actions { all += findings(action, in: context) }
        return unique(all)
    }

    /// The `Action` a tool call's input describes (shell command, file path, URL).
    public static func toolAction(tool: String, input: [String: Any?]) -> Action {
        func string(_ key: String) -> String? { (input[key] ?? nil) as? String }
        var action = Action(action: tool, tool: tool)
        switch tool {
        case "shell", "bash":
            action.action = "shell"
            action.command = string("command")
            if let workdir = string("workdir") ?? string("cwd") { action.paths.append(workdir) }
        case "read", "write", "edit", "patch", "multiedit", "list", "ls":
            action.action = (tool == "read" || tool == "list" || tool == "ls") ? "read" : "edit"
            for key in ["filePath", "path", "file"] { if let value = string(key) { action.paths.append(value) } }
        case "grep", "glob":
            action.action = tool
            if let path = string("path") { action.paths.append(path) }
            if let include = string("include") { action.resources.append(include) }
            if let pattern = string("pattern") { action.resources.append(pattern) }
        case "webfetch":
            if let url = string("url") { action.urls.append(url) }
        default: break
        }
        return action
    }

    // MARK: - Findings

    static func findings(_ action: Action, in context: Context) -> [RiskFinding] {
        var found: [RiskFinding] = []
        let verb = action.action
        // Actions that are themselves the risk.
        switch verb {
        case "external_directory":
            // Outside the project; in scope again when every directory is inside a configured code root.
            let canonical = action.resources.map { Paths.canonical(stripGlob($0), base: context.directory, home: context.home) }
            if let outside = canonical.first(where: { !context.inside($0) }) ?? (canonical.isEmpty ? "" : nil) {
                found.append(RiskFinding(.outsidePath, outside.isEmpty ? "" : context.label(outside)))
            }
        case "bellocode_other_project":
            // Another project's threads: in scope when that project is inside a configured code root.
            // Only a directory target can be in a root (the plugin sends the project's directory; an ID cannot).
            let paths = action.resources.filter { $0.hasPrefix("/") || $0.hasPrefix("~/") }
            let canonical = paths.map { Paths.canonical($0, base: context.directory, home: context.home) }
            if paths.count != action.resources.count || canonical.isEmpty || canonical.contains(where: { !context.inCodeRoot($0) }) {
                found.append(RiskFinding(.crossProject, action.resources.first.map { ($0 as NSString).lastPathComponent } ?? ""))
            }
        default: break
        }
        // Paths: from file actions' resources and from the tool input.
        var paths = action.paths
        if ["read", "edit", "list", "write", "patch"].contains(verb) { paths += action.resources }
        let writes = verb == "edit" || verb == "write" || verb == "patch"
        for raw in paths where !raw.isEmpty {
            found += pathFindings(raw, writes: writes, in: context, base: context.directory)
        }
        if verb == "grep" || verb == "glob" {
            // A grep's include or path naming secret files returns their contents.
            for pattern in action.resources where verb == "grep" && secretName(pattern) != nil { found.append(RiskFinding(.secretRead, pattern)) }
        }
        // Shell: every simple command.
        if verb == "shell" {
            if let command = action.command { found += commandFindings(command, in: context) }
            else { for resource in action.resources { found += commandFindings(resource, in: context) } }
        }
        // URLs: credentials in the URL itself.
        var urls = action.urls
        if verb == "webfetch" { urls += action.resources }
        for url in urls where urlCarriesCredentials(url) { found.append(RiskFinding(.credentialNetwork, host(of: url))) }
        // MCP configuration through any tool.
        if verb.hasPrefix("opencode_") == false, verb.contains("mcp"), verb.contains("add") || verb.contains("enable") {
            found.append(RiskFinding(.mcpServer, verb))
        }
        return found
    }

    static func pathFindings(_ raw: String, writes: Bool, in context: Context, base: String, shell: Bool = false) -> [RiskFinding] {
        let canonical = Paths.canonical(stripGlob(raw), base: base, home: context.home)
        var found: [RiskFinding] = []
        if context.isProtected(canonical) { return [RiskFinding(.policyViolation, context.label(canonical))] }
        if let secret = secretPath(canonical, home: context.home) { found.append(RiskFinding(.secretRead, context.label(canonical).isEmpty ? secret : context.label(canonical))) }
        let exempt = shell && Paths.shellScratch.contains { Paths.contains($0, canonical) }
        if !context.inside(canonical), !exempt { found.append(RiskFinding(.outsidePath, context.label(canonical))) }
        if writes, let policy = policyFile(canonical, in: context) {
            found.append(RiskFinding(policy.lowercased().contains("mcp") ? .mcpServer : .policyChange, policy))
        }
        return found
    }

    // MARK: Secrets

    /// Basenames and suffixes that look like secrets. `.env.example`-style templates are not.
    static let secretNames: Set<String> = [
        ".env", ".envrc", ".netrc", "_netrc", ".npmrc", ".pypirc", ".git-credentials", ".dockercfg", ".htpasswd", ".pgpass",
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credentials", "credentials.json", "credentials.yml", "credentials.yaml",
        "secrets.json", "secrets.yml", "secrets.yaml", "secrets.toml", "secret.json", "service-account.json", "kubeconfig",
        "token", "token.json", "tokens.json", ".token", "auth.json", "master.key", "terraform.tfvars", "vault-token", ".vault-token",
        "keystore.jks", "known_hosts.secret",
    ]
    static let secretSuffixes = [".pem", ".key", ".p12", ".pfx", ".keychain", ".keychain-db", ".kdbx", ".asc", ".gpg", ".jks", ".keystore", ".ovpn", ".tfvars", ".secret", ".secrets"]
    static let templateMarkers = ["example", "sample", "template", "dist", "defaults", "schema"]
    /// Directories whose contents are credentials (relative to home).
    static let secretDirectories = [".ssh", ".aws", ".gnupg", ".config/gcloud", ".azure", ".kube", ".docker", ".config/gh", ".config/glab-cli", "Library/Keychains", ".password-store", ".terraform.d"]

    /// The secret-looking name in `path`, if any.
    static func secretName(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        guard !name.isEmpty else { return nil }
        if templateMarkers.contains(where: { name.contains($0) }) { return nil }
        if name.hasSuffix(".pub") { return nil }
        if secretNames.contains(name) { return name }
        if name.hasPrefix(".env") { return name }  // .env.local, .env.production, .env*
        if name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") || name.hasPrefix("id_ecdsa") { return name }
        if let suffix = secretSuffixes.first(where: { name.hasSuffix($0) }) { return suffix == ".asc" && !name.contains("key") ? nil : name }
        if name.hasPrefix("secrets.") || name.hasPrefix("credentials.") { return name }
        return nil
    }

    static func secretPath(_ canonical: String, home: String) -> String? {
        if let name = secretName(canonical) { return name }
        let home = Paths.canonical(home, base: "/", home: home)
        for directory in secretDirectories {
            let root = home + "/" + directory
            if Paths.contains(root, canonical) {
                if directory == ".docker", !canonical.hasSuffix("config.json") { continue }
                if directory == ".ssh", canonical.hasSuffix(".pub") || canonical.hasSuffix("/known_hosts") { continue }
                return "~/" + directory
            }
        }
        return nil
    }

    /// Environment variables whose values look like credentials.
    static func secretVariable(_ name: String) -> Bool {
        let upper = name.uppercased()
        if ["PATH", "HOME", "PWD", "USER", "SHELL", "TERM", "LANG", "TMPDIR", "OLDPWD", "HOSTNAME", "CI"].contains(upper) { return false }
        return ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASS", "CREDENTIAL", "APIKEY", "API_KEY", "PRIVATE", "AUTH", "SESSION", "COOKIE", "ACCESS_KEY", "_KEY"]
            .contains { upper.contains($0) }
    }

    // MARK: Policy files

    /// Repository files that configure agents, tools, network or isolation.
    static func policyFile(_ canonical: String, in context: Context) -> String? {
        let label = context.label(canonical)
        let name = (canonical as NSString).lastPathComponent
        if ["opencode.json", "opencode.jsonc", ".mcp.json", "mcp.json", ".envrc", "devcontainer.json", ".devcontainer.json"].contains(name) { return label }
        let parts = label.split(separator: "/").map(String.init)
        if parts.contains(".opencode") || parts.contains(".devcontainer") || parts.contains(".bellocode") || parts.contains(".claude") { return label }
        if parts.count >= 2, parts[0] == ".git", parts[1] == "hooks" || parts[1] == "config" { return label }
        // The same files in another repository under a code root.
        if let git = parts.firstIndex(of: ".git"), git + 1 < parts.count, parts[git + 1] == "hooks" || parts[git + 1] == "config" { return label }
        if label.hasPrefix(".git/hooks") || label == ".git/config" { return label }
        return nil
    }

    // MARK: URLs

    static func urlCarriesCredentials(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else { return false }
        if components.user != nil || components.password != nil { return true }
        let keys = ["token", "access_token", "api_key", "apikey", "key", "secret", "password", "passwd", "sig", "signature", "auth", "private_token", "client_secret"]
        return components.queryItems?.contains { item in keys.contains(item.name.lowercased()) && !(item.value ?? "").isEmpty } ?? false
    }

    static func host(of value: String) -> String { URLComponents(string: value)?.host ?? "a URL" }

    // MARK: Shell

    static let installCommands: [String: Set<String>] = [
        "npm": ["install", "i", "ci", "add", "rebuild", "exec", "x", "update", "upgrade"], "pnpm": ["install", "i", "add", "dlx", "update", "rebuild", "exec"],
        "yarn": ["install", "add", "dlx", "up", "upgrade"], "bun": ["install", "i", "add", "x", "update"],
        "pip": ["install", "download"], "pip3": ["install", "download"], "pipx": ["install", "run"], "uv": ["add", "sync", "install", "tool", "run"],
        "poetry": ["add", "install", "update"], "gem": ["install", "update"], "bundle": ["install", "update", "add"],
        "cargo": ["install", "add", "update"], "go": ["install", "get"], "brew": ["install", "upgrade", "reinstall", "tap"],
        "apt": ["install", "upgrade"], "apt-get": ["install", "upgrade"], "apk": ["add", "upgrade"], "dnf": ["install"], "yum": ["install"],
        "composer": ["install", "require", "update"], "mvn": ["install"], "dotnet": ["add", "restore", "tool"], "conda": ["install", "create"],
        "deno": ["install", "add"], "swift": ["package"],
    ]
    static let alwaysInstall: Set<String> = ["npx", "bunx", "pnpx"]
    static let publishCommands: [String: Set<String>] = [
        "npm": ["publish", "unpublish", "deprecate", "dist-tag"], "pnpm": ["publish"], "yarn": ["publish", "npm"], "bun": ["publish"],
        "cargo": ["publish", "yank"], "gem": ["push", "yank"], "twine": ["upload"], "poetry": ["publish"], "docker": ["push", "login"],
        "podman": ["push"], "kubectl": ["apply", "delete", "create", "replace", "patch", "rollout", "scale"], "helm": ["install", "upgrade", "uninstall", "delete"],
        "terraform": ["apply", "destroy", "import"], "tofu": ["apply", "destroy"], "pulumi": ["up", "destroy"], "vercel": [], "netlify": ["deploy"],
        "fly": ["deploy"], "flyctl": ["deploy"], "firebase": ["deploy"], "serverless": ["deploy"], "sls": ["deploy"], "heroku": [],
        "gh": [], "glab": [], "aws": ["s3", "deploy", "cloudformation", "lambda", "ecs"], "gcloud": ["deploy", "app", "run", "functions"],
        "az": ["deployment", "webapp"], "wrangler": ["deploy", "publish"],
    ]
    static let networkCommands: Set<String> = ["curl", "wget", "http", "https", "httpie", "xh", "nc", "ncat", "netcat", "telnet", "ssh", "scp", "sftp", "ftp", "rsync", "socat"]
    static let deleteCommands: Set<String> = ["shred", "srm", "wipe", "mkfs", "dd", "truncate", "diskutil", "fdisk"]
    static let networkPolicyVariables: Set<String> = [
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "NODE_TLS_REJECT_UNAUTHORIZED", "GIT_SSL_NO_VERIFY", "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE",
        "NODE_EXTRA_CA_CERTS", "PIP_INDEX_URL", "NPM_CONFIG_REGISTRY", "OPENCODE_CONFIG", "OPENCODE_CONFIG_CONTENT",
    ]

    static func commandFindings(_ line: String, in context: Context) -> [RiskFinding] {
        let analysis = ShellAnalysis.analyse(line)
        var found: [RiskFinding] = []
        for reason in analysis.opaque { found.append(RiskFinding(.unknownCommand, reason)) }
        for variable in analysis.variables where secretVariable(variable) { found.append(RiskFinding(.secretRead, "$" + variable)) }
        var cwd = context.directory
        for command in analysis.commands {
            for assignment in command.assignments {
                let name = String(assignment.prefix { $0 != "=" })
                if networkPolicyVariables.contains(name) { found.append(RiskFinding(.policyChange, name)) }
            }
            guard var name = command.program else {
                for redirect in command.redirects { found += redirectFindings(redirect, cwd: cwd, in: context) }
                continue
            }
            var args = command.arguments
            while ["sudo", "doas", "env", "command", "nohup", "time", "nice", "exec", "builtin", "stdbuf", "timeout"].contains(name), let next = args.first {
                if name == "timeout", args.count > 1, !next.hasPrefix("-") { args.removeFirst() ; continue }
                if next.hasPrefix("-") || next.contains("=") {
                    let assignment = String(next.prefix { $0 != "=" })
                    if networkPolicyVariables.contains(assignment) { found.append(RiskFinding(.policyChange, assignment)) }
                    args.removeFirst()
                    continue
                }
                name = (next as NSString).lastPathComponent
                args.removeFirst()
            }
            found += programFindings(name, args, command: command, cwd: cwd, in: context)
            // Paths in arguments (options' values too), relative to the current directory. A program that is not
            // read-only may write what it names (cp, mv, tee, sed -i, install, ln, touch, …): naming a policy file
            // (opencode.json, .mcp.json, .git/hooks, …) then needs the person (N05).
            let mayWrite = !readOnlyPrograms.contains(name) || writingReadOnlyUse(name, args)
            for arg in args {
                let value = arg.hasPrefix("-") ? (arg.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? "") : arg
                if value.hasPrefix("@") { found += argPathFindings(String(value.dropFirst()), cwd: cwd, in: context, writes: mayWrite) }
                else if looksLikePath(value) || policyName(value) { found += argPathFindings(value, cwd: cwd, in: context, writes: mayWrite) }
                // A value attached to a short option (`grep -f.env`, `-o.git/config`): where the option ends is not
                // known, so only what such a path could never be is kept (a secret, a protected store, a policy file).
                if OptionSyntax.isShortCluster(arg), !arg.contains("="), arg.count > 2 {
                    let attached = String(arg.dropFirst(2))
                    if looksLikePath(attached) || policyName(attached) {
                        found += argPathFindings(attached, cwd: cwd, in: context, writes: mayWrite).filter { $0.category != .outsidePath }
                    }
                }
            }
            for path in writtenPaths(name, args) { found += argPathFindings(path, cwd: cwd, in: context, writes: true) }
            found += searchFindings(name, args, command: command)
            for redirect in command.redirects { found += redirectFindings(redirect, cwd: cwd, in: context) }
            if name == "cd", let target = args.first(where: { !$0.hasPrefix("-") }) {
                cwd = Paths.canonical(target, base: cwd, home: context.home)
            } else if name == "cd" {
                cwd = context.home
                found.append(RiskFinding(.outsidePath, "~"))
            }
        }
        return found
    }

    static func argPathFindings(_ value: String, cwd: String, in context: Context, writes: Bool = false) -> [RiskFinding] {
        if value.contains("://") { return [] }
        if ["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/stdin", "/dev/tty", "-"].contains(value) { return [] }
        return pathFindings(value, writes: writes, in: context, base: cwd, shell: true)
    }

    /// Output redirections write their target (N05): `> opencode.json` and `>> .git/hooks/pre-commit` change policy.
    static func redirectFindings(_ redirect: ShellAnalysis.Redirect, cwd: String, in context: Context) -> [RiskFinding] {
        if redirect.op.hasPrefix("<<") { return [] }
        if redirect.op.hasSuffix("&") {
            // `>&file` (bash): a file, not a descriptor; descriptors (`2>&1`, `>&-`) are fine.
            return redirect.target.isEmpty && redirect.op.contains(">") ? [RiskFinding(.unknownCommand, "redirects output with >& to a file")] : []
        }
        if redirect.target.isEmpty { return [] }
        return argPathFindings(redirect.target, cwd: cwd, in: context, writes: redirect.op.contains(">"))
    }

    /// Uses of read-only programs that write a file. Options are matched in every spelling the program reads (GW02):
    /// any abbreviation of a long option (`sort --out=FILE`), and a short option anywhere in a cluster (`sort -ro FILE`).
    static func writingReadOnlyUse(_ name: String, _ args: [String]) -> Bool {
        switch name {
        case "sort": args.contains { OptionSyntax.cluster($0, contains: ["o"]) || OptionSyntax.abbreviates($0, ["output"]) }
        // `-R` reruns tree into `00Tree.html` files in every folder.
        case "tree": args.contains { OptionSyntax.cluster($0, contains: ["o", "R"]) }
        // A second operand is the output file. `-` is an operand (stdin), and every word after `--` is one (GR3-01):
        // `uniq - FILE` and `xxd - FILE` write FILE.
        case "uniq": operandCount(args) >= 2
        case "file": args.contains { OptionSyntax.cluster($0, contains: ["C"]) || OptionSyntax.abbreviates($0, ["compile"]) }
        // xxd matches its options by prefix, with one dash or two (`-r`, `-revert`, `--r`).
        case "xxd": args.contains { $0.hasPrefix("-r") || $0.hasPrefix("--r") } || operandCount(args, optionsEndAtFirstOperand: true) >= 2
        default: false
        }
    }

    /// Words a getopt-style program takes as operands: a bare `-` and anything not starting with `-`, and every word
    /// after `--`. Option values (`uniq -f 1`) count too, which only makes the count larger: never an allow. vim's xxd
    /// stops reading options at its first operand, so with `optionsEndAtFirstOperand` every later word is an operand
    /// (`xxd in -out` writes `-out`).
    static func operandCount(_ args: [String], optionsEndAtFirstOperand: Bool = false) -> Int {
        var count = 0
        var afterTerminator = false
        for arg in args {
            if afterTerminator || (optionsEndAtFirstOperand && count > 0) {
                count += 1
            } else if arg == "--" {
                afterTerminator = true
            } else if arg == "-" || !arg.hasPrefix("-") {
                count += 1
            }
        }
        return count
    }

    /// The files a read-only program's writing options name (`sort -oFILE`, `sort -ro FILE`, `sort --out=FILE`): each
    /// is checked as a write, so a policy file or a protected store asks or is refused however it is spelled.
    static func writtenPaths(_ name: String, _ args: [String]) -> [String] {
        switch name {
        case "sort": OptionSyntax.shortValues(args, "o") + OptionSyntax.longValues(args, ["output"])
        case "tree": OptionSyntax.shortValues(args, "o")
        default: []
        }
    }

    /// Uses of read-only programs that change the system: setting the clock (`date -s`, `date --se=…`, or an operand
    /// that is not a `+format`, which both GNU and BSD date read as the time to set).
    static func changingReadOnlyUse(_ name: String, _ args: [String]) -> Bool {
        guard name == "date" else { return false }
        var index = 0
        while index < args.count {
            let arg = args[index]
            if OptionSyntax.cluster(arg, contains: ["s"]) || OptionSyntax.abbreviates(arg, ["set"]) { return true }
            if arg == "--" { return args[(index + 1)...].contains { !$0.hasPrefix("+") } }
            if OptionSyntax.isShortCluster(arg) {
                // `-d STRING`, `-f FILE`, `-r FILE` (GNU) and `-f FMT`, `-r SECONDS`, `-v ADJ`, `-z ZONE` (BSD) take the next word.
                index += (arg.last.map { "dfrvz".contains($0) } ?? false) && arg.count == 2 ? 2 : 1
                continue
            }
            if OptionSyntax.longName(arg) != nil {
                index += !arg.contains("=") && OptionSyntax.abbreviates(arg, ["date", "file", "reference"]) ? 2 : 1
                continue
            }
            if !arg.hasPrefix("+") { return true }
            index += 1
        }
        return false
    }

    /// A bare policy-file name (`opencode.json`), which `looksLikePath` does not take for a path.
    static func policyName(_ value: String) -> Bool {
        ["opencode.json", "opencode.jsonc", ".mcp.json", "mcp.json", ".envrc", "devcontainer.json", ".devcontainer.json", ".opencode",
         ".devcontainer", ".git"].contains(value)
    }

    /// Programs that print file contents (a hidden-file glob such as `.*` reaches `.env`).
    static let contentReaders: Set<String> = [
        "cat", "head", "tail", "grep", "egrep", "fgrep", "rg", "ag", "strings", "xxd", "hexdump", "od", "nl", "sort", "uniq", "cut",
        "diff", "cmp", "comm", "join", "paste", "fold", "expand", "rev", "column", "less", "more", "jq", "md5", "md5sum", "shasum", "sha256sum",
    ]

    /// Searches that read secret files' contents (N05): `rg`/`ag` told to search hidden or ignored files (where `.env`
    /// and keys live), and hidden-file globs given to content readers. (`grep -r` is checked against the tree it
    /// searches, in `decide`: `recursiveSearchFindings`.)
    /// Options are matched in every spelling (GW02): ag's getopt_long takes abbreviations, and rg's are matched the
    /// same way in case a version does.
    static func searchFindings(_ name: String, _ args: [String], command: ShellAnalysis.Command) -> [RiskFinding] {
        var found: [RiskFinding] = []
        switch name {
        case "rg":
            let long = ["unrestricted", "hidden", "no-ignore", "no-ignore-vcs", "no-ignore-dot", "no-ignore-files", "no-ignore-global", "no-ignore-parent", "no-ignore-exclude"]
            if args.contains(where: { OptionSyntax.cluster($0, contains: ["u", "."]) || OptionSyntax.abbreviates($0, long) }) {
                found.append(RiskFinding(.secretRead, "rg over hidden or ignored files (such as .env)"))
            }
        case "ag":
            let long = ["unrestricted", "hidden", "skip-vcs-ignores", "all-text", "all-types"]
            if args.contains(where: { OptionSyntax.cluster($0, contains: ["u", "U", "t", "a"]) || OptionSyntax.abbreviates($0, long) }) {
                found.append(RiskFinding(.secretRead, "ag over hidden or ignored files (such as .env)"))
            }
        default:
            break
        }
        if contentReaders.contains(name), command.hasGlob,
           let glob = args.first(where: { arg in !arg.hasPrefix("-") && (arg as NSString).lastPathComponent.hasPrefix(".") && arg.contains(where: { "*?[".contains($0) }) }) {
            found.append(RiskFinding(.secretRead, "\(name) \(glob) (matches hidden files such as .env)"))
        }
        return found
    }

    static func looksLikePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains("://") else { return false }
        if value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix("./") || value.hasPrefix("../") || value == ".." { return true }
        if value.contains("/") , !value.contains(" "), !value.hasPrefix("$") { return true }
        return secretName(value) != nil
    }

    static func programFindings(_ name: String, _ args: [String], command: ShellAnalysis.Command, cwd: String, in context: Context) -> [RiskFinding] {
        var found: [RiskFinding] = []
        let positional = args.filter { !$0.hasPrefix("-") }
        let sub = positional.first ?? ""
        switch name {
        case "git":
            found += gitFindings(args, cwd: cwd, in: context)
        case "rm", "unlink", "rmdir":
            let flags = args.filter { $0.hasPrefix("-") }.joined()
            if name == "rm", flags.contains("r") || flags.contains("R") || flags.contains("f") || args.contains(where: { OptionSyntax.abbreviates($0, ["recursive", "force"]) }) || command.hasGlob {
                found.append(RiskFinding(.irreversibleDelete, "rm " + args.filter { $0.hasPrefix("-") }.joined(separator: " ")))
            } else if positional.count > 3 {
                found.append(RiskFinding(.irreversibleDelete, "rm of \(positional.count) files"))
            }
        case "find":
            if args.contains("-delete") || args.contains(where: { ["-exec", "-execdir", "-ok", "-okdir"].contains($0) }) {
                found.append(RiskFinding(args.contains("-delete") ? .irreversibleDelete : .unknownCommand, args.contains("-delete") ? "find -delete" : "find -exec"))
            }
        case "security":
            if ["dump-keychain", "find-generic-password", "find-internet-password", "export", "find-certificate"].contains(sub) {
                let reveals = args.contains("-w") || args.contains("-g") || sub == "dump-keychain" || sub == "export"
                found.append(RiskFinding(reveals ? .policyViolation : .secretRead, "security \(sub)"))
            }
        case "env", "printenv", "export", "set", "declare":
            if positional.isEmpty || (name == "export" && args.contains("-p")) { found.append(RiskFinding(.secretRead, "the environment")) }
            // `printenv ANTHROPIC_API_KEY` prints one secret (N05).
            for arg in positional where name == "printenv" && secretVariable(arg) { found.append(RiskFinding(.secretRead, "$" + arg)) }
            for arg in positional where name == "export" {
                let variable = String(arg.prefix { $0 != "=" })
                if networkPolicyVariables.contains(variable) { found.append(RiskFinding(.policyChange, variable)) }
            }
        case "jq":
            // `jq -n env`, `$ENV`: the whole environment (N05).
            if args.contains(where: { arg in arg.contains("$ENV") || arg.range(of: #"(^|[^A-Za-z0-9_$.])env($|[^A-Za-z0-9_])"#, options: .regularExpression) != nil }) {
                found.append(RiskFinding(.secretRead, "the environment (jq env)"))
            }
        case "chmod", "chown", "chattr", "chflags":
            if args.contains(where: { $0.contains("+s") || $0.contains("u+s") || $0 == "4755" || $0 == "-R" }) { found.append(RiskFinding(.policyChange, "\(name) \(args.prefix(2).joined(separator: " "))")) }
        case "iptables", "ip6tables", "pfctl", "ufw", "networksetup", "scutil", "route", "nft":
            found.append(RiskFinding(.policyChange, name))
        case "crontab", "launchctl", "systemctl":
            found.append(RiskFinding(.policyChange, name))
        case "opencode", "claude", "codex", "cursor":
            if args.contains("mcp") { found.append(RiskFinding(.mcpServer, "\(name) mcp")) }
            if args.contains(where: { $0 == "auth" || $0 == "login" || $0 == "config" }) { found.append(RiskFinding(.policyChange, "\(name) \(sub)")) }
        case "docker", "podman", "nerdctl":
            if sub == "run", args.contains(where: { $0.contains("docker.sock") || $0 == "--privileged" || $0 == "--network=host" }) {
                found.append(RiskFinding(.policyViolation, "\(name) run with host access"))
            }
        default: break
        }
        if let subs = publishCommands[name], subs.isEmpty || subs.contains(sub) {
            if !(name == "aws" && sub == "s3" && !(positional.dropFirst().first.map { ["cp", "sync", "mv", "rm", "rb"].contains($0) } ?? false)) {
                if !(name == "gh" || name == "glab") || ["release", "pr", "repo", "api", "workflow"].contains(sub) {
                    found.append(RiskFinding(.publish, ([name] + positional.prefix(1)).joined(separator: " ")))
                }
            }
        }
        if alwaysInstall.contains(name) {
            found.append(RiskFinding(.packageInstall, ([name] + positional.prefix(1)).joined(separator: " ")))
        } else if let subs = installCommands[name], subs.contains(sub) {
            if !(name == "swift" && !(positional.dropFirst().first.map { ["update", "resolve"].contains($0) } ?? false)) && !(name == "uv" && sub == "run" && !args.contains("--with")) {
                found.append(RiskFinding(.packageInstall, "\(name) \(sub)"))
            }
        } else if name == "yarn", positional.isEmpty {
            found.append(RiskFinding(.packageInstall, "yarn"))
        } else if ["make", "cmake"].contains(name), sub == "install" {
            found.append(RiskFinding(.packageInstall, "\(name) install"))
        }
        if deleteCommands.contains(name) || name.hasPrefix("mkfs") { found.append(RiskFinding(.irreversibleDelete, name)) }
        if networkCommands.contains(name) { found += networkFindings(name, args, cwd: cwd, in: context) }
        return found
    }

    static func gitFindings(_ args: [String], cwd: String, in context: Context) -> [RiskFinding] {
        var rest = args[...]
        var found: [RiskFinding] = []
        // Global options before the subcommand.
        while let first = rest.first, first.hasPrefix("-") {
            rest = rest.dropFirst()
            if first == "-C" || first == "-c" || first == "--git-dir" || first == "--work-tree", let value = rest.first {
                if first != "-c" { found += argPathFindings(value, cwd: cwd, in: context) }
                else if value.lowercased().contains("credential") || value.lowercased().contains("sslverify") || value.lowercased().contains("proxy") {
                    found.append(RiskFinding(.policyChange, "git -c \(value.prefix { $0 != "=" })"))
                }
                rest = rest.dropFirst()
            }
        }
        guard let sub = rest.first else { return found }
        let tail = Array(rest.dropFirst())
        // git's parse-options takes any unique abbreviation of a long option (GW02): `reset --har` is `--hard`.
        let has = { (flags: [String]) in
            tail.contains { arg in
                flags.contains(arg) || OptionSyntax.abbreviates(arg, flags.filter { $0.hasPrefix("--") }.map { String($0.dropFirst(2)) })
            }
        }
        let short = { (letter: Character) in tail.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains(letter) } }
        switch sub {
        case "reset" where has(["--hard", "--merge", "--keep"]): found.append(RiskFinding(.destructiveGit, "reset --hard"))
        case "clean" where short("f") || has(["--force"]): found.append(RiskFinding(.destructiveGit, "clean -f"))
        case "push":
            if has(["--force", "--force-with-lease", "--mirror", "--delete", "--prune"]) || short("f") || tail.contains(where: { $0.hasPrefix(":") || $0.hasPrefix("+") }) {
                found.append(RiskFinding(.destructiveGit, "push --force"))
            }
            found.append(RiskFinding(.publish, "git push"))
        case "branch" where short("D") || has(["--delete", "-d", "--force"]): found.append(RiskFinding(.destructiveGit, "branch -D"))
        case "checkout" where tail.contains(".") || has(["--force", "-f"]) || (tail.first == "--"): found.append(RiskFinding(.destructiveGit, "checkout -- (discards changes)"))
        case "restore" where !has(["--staged"]) || has(["--worktree"]): found.append(RiskFinding(.destructiveGit, "restore (discards changes)"))
        case "stash" where tail.first == "drop" || tail.first == "clear": found.append(RiskFinding(.destructiveGit, "stash \(tail.first!)"))
        case "filter-branch", "filter-repo": found.append(RiskFinding(.destructiveGit, sub))
        case "reflog" where tail.first == "expire" || tail.first == "delete": found.append(RiskFinding(.destructiveGit, "reflog \(tail.first!)"))
        case "gc" where has(["--prune"]): found.append(RiskFinding(.destructiveGit, "gc --prune"))
        case "update-ref" where short("d"): found.append(RiskFinding(.destructiveGit, "update-ref -d"))
        case "rebase" where has(["--root"]) || tail.contains("-i") == false && has(["--onto"]): found.append(RiskFinding(.destructiveGit, "rebase"))
        case "worktree" where tail.first == "remove" && (short("f") || has(["--force"])): found.append(RiskFinding(.destructiveGit, "worktree remove --force"))
        case "config":
            if !(tail.contains("--get") || tail.contains("--list") || tail.contains("-l") || tail.contains("--get-all") || tail.count <= 1) {
                found.append(RiskFinding(.policyChange, "git config"))
            }
            if tail.contains(where: { $0.lowercased().contains("credential") }) { found.append(RiskFinding(.secretRead, "git credentials")) }
        case "credential", "credential-store", "credential-osxkeychain": found.append(RiskFinding(.secretRead, "git \(sub)"))
        default: break
        }
        return found
    }

    static func networkFindings(_ name: String, _ args: [String], cwd: String, in context: Context) -> [RiskFinding] {
        var found: [RiskFinding] = []
        var target = args.first { $0.contains("://") }.map(host(of:)) ?? name
        if name == "ssh" || name == "scp" || name == "sftp" || name == "rsync" {
            target = args.first { !$0.hasPrefix("-") && $0.contains("@") }.map { String($0.split(separator: ":").first ?? "") } ?? name
        }
        let lower = args.map { $0.lowercased() }
        // `--head` is curl's own option (-I), not an abbreviation of `--header`.
        let header = { (flag: String) in flag == "-h" || OptionSyntax.abbreviates(flag, ["header"], exact: ["head"]) }
        let credentialHeader = zip(lower, lower.dropFirst()).contains { flag, value in
            header(flag) && !flag.contains("=") && ["authorization", "token", "api-key", "apikey", "x-api-key", "cookie", "private-token", "x-auth"].contains { value.contains($0) }
        } || lower.contains { header($0) && $0.contains("=") && ["authorization", "token", "api-key", "cookie"].contains(where: $0.contains) }
        // curl before 8 and wget take unique abbreviations of long options (GW02).
        let userFlag = args.contains { ["-u", "-b", "--header=Authorization"].contains($0) || OptionSyntax.abbreviates($0, ["user", "oauth2-bearer", "netrc", "netrc-file", "cookie", "http-user", "http-password", "password"]) }
        let fileFlag = { (flag: String) in flag == "-T" || OptionSyntax.abbreviates(flag, ["upload-file", "post-file", "body-file"]) }
        let dataFlag = { (flag: String) in
            ["-d", "-F"].contains(flag) || OptionSyntax.abbreviates(flag, ["data", "data-ascii", "data-binary", "data-raw", "data-urlencode", "form"])
        }
        let upload = zip(args, args.dropFirst()).contains { flag, value in
            !flag.contains("=") && ((dataFlag(flag) && (value.hasPrefix("@") || value.contains("=@"))) || fileFlag(flag))
        } || args.contains { flag in
            guard flag.contains("="), let value = flag.split(separator: "=", maxSplits: 1).last.map(String.init) else { return false }
            return fileFlag(flag) || (dataFlag(flag) && (value.hasPrefix("@") || value.contains("=@")))
        }
        let urlCredential = args.contains { $0.contains("://") && urlCarriesCredentials($0) }
        if credentialHeader || userFlag || urlCredential { found.append(RiskFinding(.credentialNetwork, target)) }
        if upload { found.append(RiskFinding(.credentialNetwork, "uploads a local file to \(target)")) }
        if name == "scp" || name == "rsync", args.contains(where: { !$0.hasPrefix("-") && $0.contains(":") && !$0.contains("://") }) {
            found.append(RiskFinding(.credentialNetwork, "copies files to or from \(target)"))
        }
        return found
    }

    // MARK: - Deterministic allows

    /// Actions that never need review.
    static let alwaysAllowed: [String: String] = [
        "todowrite": "Updates the task list", "todoread": "Reads the task list", "question": "Asks you a question",
        "skill": "Loads a skill's instructions", "subagent": "Starts a child task (it inherits Auto)",
    ]
    /// Shell programs that only read, when every path they name is inside the project and not secret-looking.
    static let readOnlyPrograms: Set<String> = [
        "ls", "pwd", "echo", "cat", "head", "tail", "wc", "file", "stat", "du", "grep", "egrep", "fgrep", "rg", "ag", "find",
        "which", "type", "date", "uname", "whoami", "sort", "uniq", "cut", "tr", "jq", "tree", "basename", "dirname", "realpath",
        "true", "false", "test", "[", "diff", "cmp", "nl", "column", "printf", "seq", "yes", "sleep", "readlink",
        "md5", "md5sum", "shasum", "sha256sum", "xxd", "hexdump", "od", "strings", "comm", "join", "paste", "fold", "expand", "rev",
    ]
    static let readOnlyGit: Set<String> = [
        "status", "diff", "log", "show", "rev-parse", "ls-files", "blame", "describe", "shortlog", "grep", "ls-tree", "cat-file",
        "rev-list", "merge-base", "name-rev", "whatchanged", "reflog",
    ]

    static func deterministicAllow(_ action: Action, in context: Context) -> (String, String)? {
        if let text = alwaysAllowed[action.action] { return (action.action, text) }
        if action.action.hasPrefix("bellocode_app_") { return ("app_tool", "A BelloCode app tool (it asks you itself when it needs to)") }
        // Findings were empty, so these are inside the configured code roots.
        if action.action == "external_directory" { return ("code_root", "A folder inside your code roots") }
        if action.action == "bellocode_other_project" { return ("code_root_project", "Another project inside your code roots") }
        switch action.action {
        case "read", "list", "glob", "grep":
            // Findings were empty, so every path is inside the project and nothing names a secret.
            return ("in_project_read", "Reads inside the project")
        case "edit", "write", "patch":
            let paths = action.paths + action.resources
            guard !paths.isEmpty else { return nil }
            return ("in_project_edit", "Edits a file inside the project")
        case "shell":
            guard let line = action.command ?? (action.resources.count == 1 ? action.resources.first : nil) else {
                return action.resources.allSatisfy(readOnlyShell) && !action.resources.isEmpty ? ("read_only_command", "A read-only command inside the project") : nil
            }
            return readOnlyShell(line) ? ("read_only_command", "A read-only command inside the project") : nil
        default:
            return nil
        }
    }

    static func readOnlyShell(_ line: String) -> Bool {
        let analysis = ShellAnalysis.analyse(line)
        guard !analysis.isOpaque, !analysis.commands.isEmpty else { return false }
        for command in analysis.commands {
            guard let name = command.program, command.assignments.isEmpty else { return false }
            if command.redirects.contains(where: { !($0.op.hasSuffix("&") || $0.target == "/dev/null") }) { return false }
            if command.expandsVariables { return false }
            let args = command.arguments
            if name == "git" {
                guard readOnlyGitUse(args) else { return false }
                continue
            }
            if !readOnlyPrograms.contains(name) { return false }
            if name == "find", args.contains(where: { ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprintf", "-fls", "-fprint0"].contains($0) }) { return false }
            if writingReadOnlyUse(name, args) || changingReadOnlyUse(name, args) { return false }
            // Options that run another program (N05): `rg --pre ./x.sh`, `sort --compress-program=./x.sh`.
            if args.contains(where: { arg in Self.runsProgram(name, arg) }) { return false }
        }
        return true
    }

    /// git options of the read-only subcommands that write a file or run a program (N05), in any abbreviation
    /// (GW02): `--output`, `git grep --open-files-in-pager` (`--op=CMD` runs CMD through the shell), external diff,
    /// text conversion and filter drivers. `exact` are other options' exact spellings that abbreviate one of them.
    static let gitDangerousOptions = ["output", "open-files-in-pager", "ext-diff", "textconv", "filters", "upload-pack", "exec"]
    /// Exact spellings that win over the abbreviation, per subcommand: only where git defines that exact option
    /// (`git diff --text` is `--text`; `git cat-file` has no `--text`, so there it resolves to `--textconv`).
    /// Anywhere else they count as the dangerous option they abbreviate (GW02).
    static let gitExactOptions: [String: Set<String>] = [
        "diff": ["text"], "log": ["text"], "show": ["text"], "grep": ["text"], "whatchanged": ["text"],
        "rev-list": ["filter"],
    ]

    /// Options `git branch`, `git tag` and `git remote` take when they only list (anything else, or a name, may
    /// create, delete, rename or reconfigure): exact spellings, `name=value` for the ones that take a value, and
    /// clusters of the listed letters.
    static let gitListingOptions: [String: (exact: Set<String>, valued: Set<String>, letters: Set<Character>)] = [
        "branch": (["--all", "--remotes", "--verbose", "--list", "--show-current", "--color", "--no-color", "--column", "--no-column",
                    "--ignore-case", "--no-abbrev", "--merged", "--no-merged", "--contains", "--no-contains", "--points-at"],
                   ["--color", "--column", "--sort", "--format", "--abbrev", "--merged", "--no-merged", "--contains", "--no-contains", "--points-at"],
                   ["a", "r", "v", "l", "i"]),
        "tag": (["--list", "--column", "--no-column", "--color", "--no-color", "--ignore-case", "--merged", "--no-merged", "--contains",
                 "--no-contains", "--points-at"],
                ["--sort", "--format", "--color", "--column", "--merged", "--no-merged", "--contains", "--no-contains", "--points-at"],
                ["l", "i", "n"]),
        "remote": (["--verbose"], [], ["v"]),
    ]

    /// Whether a git command only reads. Global options before the subcommand (`-c`, `-C`, `--exec-path`) are not.
    static func readOnlyGitUse(_ args: [String]) -> Bool {
        guard let sub = args.first, !sub.hasPrefix("-") else { return false }
        let tail = Array(args.dropFirst())
        let positional = tail.filter { !$0.hasPrefix("-") }
        if let listing = gitListingOptions[sub] {
            guard positional.isEmpty else { return false }
            return tail.allSatisfy { arg in
                if listing.exact.contains(arg) { return true }
                if let equals = arg.firstIndex(of: "="), listing.valued.contains(String(arg[..<equals])) { return true }
                if sub == "tag", arg.range(of: #"^-n[0-9]*$"#, options: .regularExpression) != nil { return true }
                return OptionSyntax.isShortCluster(arg) && arg.dropFirst().allSatisfy { listing.letters.contains($0) }
            }
        }
        if sub == "stash" {
            // `git stash` alone stashes; `list` and `show` read (and take log and diff options, checked below).
            guard let action = tail.first, action == "list" || action == "show" else { return false }
        } else {
            guard readOnlyGit.contains(sub) else { return false }
        }
        if sub == "reflog", positional.first.map({ ["expire", "delete", "drop"].contains($0) }) == true { return false }
        return !tail.contains { arg in
            arg == "-o" || OptionSyntax.abbreviates(arg, gitDangerousOptions, exact: gitExactOptions[sub] ?? [])
                || (sub == "grep" && OptionSyntax.cluster(arg, contains: ["O"]))
        }
    }

    /// Options of read-only programs that run another program, in any abbreviation (GW02).
    static func runsProgram(_ name: String, _ arg: String) -> Bool {
        switch name {
        // `--search-zip`/`-z` runs decompressors; `--hostname-bin` runs a program for hyperlinks.
        case "rg": return OptionSyntax.abbreviates(arg, ["pre", "pre-glob", "search-zip", "hostname-bin"]) || OptionSyntax.cluster(arg, contains: ["z"])
        case "sort": return OptionSyntax.abbreviates(arg, ["compress-program"])
        case "ag": return OptionSyntax.abbreviates(arg, ["pager"])
        case "find": return ["-exec", "-execdir", "-ok", "-okdir"].contains(String(arg.prefix { $0 != "=" }))
        default: return false
        }
    }

    // MARK: - Helpers

    static func describe(_ action: Action) -> String {
        if let command = action.command { return "Runs `\(String(command.prefix(80)))`" }
        if let first = action.resources.first { return "\(action.action) \(String(first.prefix(80)))" }
        return action.action
    }

    static func stripGlob(_ path: String) -> String {
        var value = path
        while value.hasSuffix("/*") || value.hasSuffix("/**") { value = String(value.dropLast(value.hasSuffix("/**") ? 3 : 2)) }
        if value == "*" || value == "**" { return "." }
        return value
    }

    static func unique(_ findings: [RiskFinding]) -> [RiskFinding] {
        var seen = Set<RiskFinding>()
        return findings.filter { seen.insert($0).inserted }
    }
}

/// Path canonicalisation for the policy: `~` expansion, relative to a base, `.`/`..` resolved, then symlinks of the
/// longest existing prefix resolved (a link inside the project that points outside is outside).
enum Paths {
    /// Shell scratch locations that are not "outside the project" for commands (they run in the project container).
    static let shellScratch = ["/tmp", "/private/tmp", "/dev/null"]

    static func canonical(_ path: String, base: String, home: String) -> String {
        var value = path.trimmingCharacters(in: .whitespaces)
        if value == "~" { value = home } else if value.hasPrefix("~/") { value = home + value.dropFirst(1) }
        if value.hasPrefix("$HOME") { value = home + value.dropFirst(5) }
        if !value.hasPrefix("/") { value = (base.hasSuffix("/") ? base : base + "/") + value }
        let standardized = (value as NSString).standardizingPath
        return resolveExistingPrefix(standardized)
    }

    /// Resolves symlinks in the longest prefix that exists, then appends the rest unchanged.
    static func resolveExistingPrefix(_ path: String) -> String {
        var components = (path as NSString).pathComponents
        var suffix: [String] = []
        while components.count > 1 {
            let candidate = NSString.path(withComponents: components)
            if FileManager.default.fileExists(atPath: candidate) {
                let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
                let joined = suffix.reversed().reduce(resolved) { ($0 as NSString).appendingPathComponent($1) }
                return joined
            }
            suffix.append(components.removeLast())
        }
        return path
    }

    static func contains(_ root: String, _ path: String) -> Bool {
        let root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
}
