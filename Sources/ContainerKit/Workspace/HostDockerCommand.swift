import Foundation

/// The command filter of "Host shell, docker only" (`ExecutionMode.hostDocker`): `bellocode-exec -c <line>` runs on the
/// Mac only when the whole line is one plain `docker …` command, which is then executed directly (argv, no shell) with
/// Rancher Desktop's binary by absolute path and BelloCode's filtered endpoint as `DOCKER_HOST`.
///
/// Deliberately strict, because it is the weaker mode (docs/features/containers.md): words may be plain or quoted, but
/// any shell syntax (`;`, `&&`, `|`, redirection, `$`, backquotes, globs, `~`, comments, variable assignments, line
/// breaks, backslashes) is refused rather than interpreted. Options that choose another daemon, context or
/// configuration, and options or subcommands that write files on the Mac, are refused too.
public enum HostDockerCommand {
    public enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        case empty
        case shellSyntax(String)
        case unterminatedQuote
        case notDocker(String)
        case globalOption(String)
        case subcommand(String)
        case option(String)
        case unknownOption(String)
        /// A host file the docker client would read, outside the project's folders (N03, A06).
        case outsidePath(option: String, path: String)
        /// An option that reads or writes host files or sockets docker's client opens itself (secrets, SSH agent,
        /// named contexts, local caches), or a remote context the client would fetch on the Mac.
        case hostInput(String)
        /// The client could not be confined (macOS's sandbox is missing).
        case unconfined

        public var description: String {
            let tail = " This project runs in “Host shell, docker only” mode: only one plain docker, docker compose or docker buildx command per call is run on this Mac. Run other commands inside a container (for example docker compose run SERVICE …), or switch the project to the shared workspace in Project Settings ▸ Environment."
            return switch self {
            case .empty: "the command is empty." + tail
            case .shellSyntax(let text): "the command uses shell syntax (\(text)), which this mode refuses rather than interprets." + tail
            case .unterminatedQuote: "the command has an unterminated quote." + tail
            case .notDocker(let program): "“\(program)” is not docker." + tail
            case .globalOption(let option): "the docker option \(option) chooses another daemon, context or configuration, which is not allowed." + tail
            case .subcommand(let name): "“docker \(name)” is not allowed in this mode (it changes the docker configuration or writes files on the Mac)." + tail
            case .option(let option): "the option \(option) writes files on the Mac, which is not allowed." + tail
            case .unknownOption(let option): "the option \(option) is not one this mode understands, so the command is refused rather than guessed." + tail
            case .outsidePath(let option, let path): "\(option) names \(path), which is outside this project's folders; docker would read it on this Mac." + tail
            case .hostInput(let option): "\(option) makes docker read files, sockets or the network on this Mac itself, which is not allowed." + tail
            case .unconfined: "docker cannot be confined to the project's folders on this Mac (macOS's sandbox-exec is missing), so nothing was run." + tail
            }
        }
    }

    /// Characters that are shell syntax when unquoted.
    static let unquotedSyntax: Set<Character> = [";", "&", "|", "<", ">", "(", ")", "$", "`", "\\", "*", "?", "[", "]", "{", "}", "~", "#", "!", "\n", "\r"]
    /// Inside double quotes the shell still expands these.
    static let doubleQuotedSyntax: Set<Character> = ["$", "`", "\\", "!", "\n", "\r"]

    /// Subcommands allowed at the top level. Others (context, login/logout, cp, save, export, load, plugin, swarm,
    /// trust, …) are refused.
    public static let allowedSubcommands: Set<String> = [
        "build", "buildx", "compose", "container", "create", "events", "exec", "history", "image", "images", "info", "inspect",
        "kill", "logs", "network", "pause", "port", "ps", "pull", "restart", "rm", "rmi", "run", "start", "stats", "stop", "tag",
        "top", "unpause", "version", "volume", "wait", "attach",
    ]
    /// Second-level subcommands refused under an allowed group.
    public static let refusedNested: [String: Set<String>] = [
        "compose": ["cp", "publish", "watch", "bridge"],
        "container": ["cp", "export", "commit"],
        "image": ["save", "load", "import", "push"],
        "buildx": ["create", "use", "rm", "bake", "prune", "imagetools", "install", "uninstall", "history"],
    ]
    /// Options that write a file on the Mac (or redirect where output goes).
    public static let writingOptions: Set<String> = ["-o", "--output", "--iidfile", "--metadata-file", "--cidfile", "--sbom", "--provenance", "--push"]
    /// Global options that choose another daemon or configuration.
    public static let endpointOptions: Set<String> = ["-H", "--host", "-c", "--context", "--config", "--tls", "--tlsverify", "--tlscacert", "--tlscert", "--tlskey"]

    /// Splits a command line into words (plain, single- or double-quoted), refusing any shell syntax.
    public static func words(_ line: String) throws(Refusal) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var iterator = Array(line).makeIterator()
        while let character = iterator.next() {
            switch character {
            case " ", "\t":
                if inWord { words.append(current); current = ""; inWord = false }
            case "'":
                inWord = true
                var closed = false
                while let next = iterator.next() {
                    if next == "'" { closed = true; break }
                    if next == "\n" || next == "\r" { throw .shellSyntax("a line break") }
                    current.append(next)
                }
                if !closed { throw .unterminatedQuote }
            case "\"":
                inWord = true
                var closed = false
                while let next = iterator.next() {
                    if next == "\"" { closed = true; break }
                    if doubleQuotedSyntax.contains(next) { throw .shellSyntax(describe(next)) }
                    current.append(next)
                }
                if !closed { throw .unterminatedQuote }
            default:
                if unquotedSyntax.contains(character) { throw .shellSyntax(describe(character)) }
                inWord = true
                current.append(character)
            }
        }
        if inWord { words.append(current) }
        return words
    }

    static func describe(_ character: Character) -> String {
        switch character {
        case "\n", "\r": "a line break"
        case "&", ";", "|": "“\(character)”: one command at a time"
        case "<", ">": "redirection “\(character)”"
        case "$", "`": "expansion “\(character)”"
        default: "“\(character)”"
        }
    }

    /// The argv to run (with the docker binary at `docker`), or the reason it is refused. With `roots`, every host
    /// file an option names (and a build context) must be inside them, resolved from `cwd` with links followed.
    public static func argv(for line: String, docker: String, roots: [String]? = nil, cwd: String? = nil) throws(Refusal) -> [String] {
        let words = try Self.words(line)
        guard let program = words.first else { throw .empty }
        if program.contains("=") { throw .shellSyntax("a variable assignment") }
        guard program == "docker" || program == docker else { throw .notDocker(program) }
        try check(arguments: Array(words.dropFirst()), roots: roots, cwd: cwd)
        return [docker] + words.dropFirst()
    }

    /// Options that make the client read host files, sockets or caches itself, refused wherever they appear (the
    /// classic builder BelloCode's endpoint offers supports none of them; BuildKit's are refused by the endpoint).
    public static let hostInputOptions: Set<String> = ["--secret", "--ssh", "--build-context", "--cache-to", "--attest", "--sbom"]
    /// Options naming a host file the client reads, under any subcommand.
    public static let fileOptions: Set<String> = ["--env-file", "--label-file", "--env-from-file"]
    /// Build subcommands, whose `-f/--file` is a host file and whose positional argument is a host folder.
    static func isBuild(_ arguments: [String], at index: Int) -> Bool {
        guard index < arguments.count else { return false }
        if arguments[index] == "build" { return true }
        return index + 1 < arguments.count && ["image", "buildx", "builder"].contains(arguments[index]) && arguments[index + 1] == "build"
    }

    /// Global options accepted before the subcommand (they only change what docker prints).
    public static let harmlessGlobalOptions: Set<String> = ["-D", "--debug"]
    /// Global options accepted only as the whole remaining command line.
    public static let terminalGlobalOptions: Set<String> = ["-v", "--version", "-h", "--help"]
    /// Group options that may appear between a group and its subcommand, and whether each takes a value.
    public static let groupOptions: [String: [String: Bool]] = [
        "compose": [
            "-f": true, "--file": true, "-p": true, "--project-name": true, "--project-directory": true, "--env-file": true,
            "--profile": true, "--ansi": true, "--progress": true, "--parallel": true,
            "--compatibility": false, "--dry-run": false, "--all-resources": false,
        ],
        "container": [:], "image": [:], "network": [:], "volume": [:], "buildx": [:],
    ]
    /// `docker buildx` subcommands allowed (builder changes, bake, dial-stdio, imagetools … are refused).
    public static let allowedBuildx: Set<String> = ["build", "ls", "inspect", "version", "du"]
    /// Options refused anywhere on the line: they pick another daemon, context, configuration or builder.
    public static let endpointOptionsAnywhere: Set<String> = ["-H", "--host", "--context", "--config", "--builder"]

    /// Validates docker's arguments (also used for relayed `--stdio` programs). The whole argument vector is checked:
    /// leading global options are consumed one by one (only harmless ones), the subcommand and, for groups, the group's
    /// options and nested subcommand are parsed, and then every remaining word is scanned for options that write on the
    /// Mac or change the endpoint, including attached (`-ofile`, `--output=x`) and clustered (`-qo x`) short forms.
    public static func check(arguments: [String], roots: [String]? = nil, cwd: String? = nil) throws(Refusal) {
        try checkOptions(arguments)
        if let roots { try checkPaths(arguments, roots: roots, cwd: cwd ?? FileManager.default.currentDirectoryPath) }
    }

    /// Host files named by options (and a build's context) must be inside `roots` (N03, A06). The sandbox the client
    /// runs in enforces the same folders for everything else it opens (Compose files' `env_file`, includes, …);
    /// this check names the option in the refusal.
    static func checkPaths(_ arguments: [String], roots: [String], cwd: String) throws(Refusal) {
        let canonicalRoots = roots.map { CodeRootPaths.canonical($0) ?? CodeRootPaths.lexicallyNormalized($0) }
        func verify(_ option: String, _ value: String) throws(Refusal) {
            if value == "-" { return }  // standard input
            let absolute = value.hasPrefix("/") ? value : (cwd as NSString).appendingPathComponent(value)
            let resolved = canonicalExisting(CodeRootPaths.lexicallyNormalized(absolute))
            guard canonicalRoots.contains(where: { CodeRootPaths.inside(resolved, $0) }) else { throw .outsidePath(option: option, path: value) }
        }
        var index = 0
        while index < arguments.count, arguments[index].hasPrefix("-") { index += 1 }
        let build = isBuild(arguments, at: index)
        let compose = index < arguments.count && arguments[index] == "compose"
        var position = 0
        while position < arguments.count {
            let word = arguments[position]
            let name = optionName(word)
            let attached: String? = word.contains("=") && word.hasPrefix("--") ? String(word.dropFirst(name.count + 1)) : nil
            let next: String? = position + 1 < arguments.count ? arguments[position + 1] : nil
            var takes = false
            if fileOptions.contains(name) || (build && ["-f", "--file"].contains(name))
                || (compose && ["-f", "--file", "--project-directory"].contains(name) && position < composeNestedIndex(arguments)) {
                takes = true
            } else if build, name.hasPrefix("-f"), !name.hasPrefix("--"), word.count > 2 {
                // `-fpath`
                try verify("-f", String(word.dropFirst(2)))
            }
            if takes {
                guard let value = attached ?? next else { break }
                try verify(name, value)
                position += attached == nil ? 2 : 1
                continue
            }
            position += 1
        }
        // A build's context: a folder inside the roots, never a URL or a Git repository the client would fetch.
        if build {
            for word in arguments.dropFirst(index) where Self.isRemoteContext(word) { throw .hostInput("a remote build context (\(word))") }
            if let context = Self.buildContext(arguments, from: index) { try verify("the build context", context) }
        }
    }

    /// The canonical path of the longest existing prefix, with the rest appended (a file that does not exist yet still
    /// resolves through any link above it).
    static func canonicalExisting(_ path: String) -> String {
        if let canonical = CodeRootPaths.canonical(path) { return canonical }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != path, !parent.isEmpty else { return path }
        return (canonicalExisting(parent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    static func isRemoteContext(_ word: String) -> Bool {
        let lowered = word.lowercased()
        return ["http://", "https://", "git://", "git@", "ssh://", "github.com/"].contains { lowered.hasPrefix($0) }
    }

    /// Where a compose group's nested subcommand starts (its group options come before it).
    static func composeNestedIndex(_ arguments: [String]) -> Int {
        guard let start = arguments.firstIndex(of: "compose") else { return arguments.count }
        var index = start + 1
        let options = groupOptions["compose"] ?? [:]
        while index < arguments.count, arguments[index].hasPrefix("-") {
            let word = arguments[index]
            let takesValue = options[optionName(word)] ?? false
            index += takesValue && !word.contains("=") ? 2 : 1
        }
        return index
    }

    /// Build options that take a separate value (so the positional context can be told apart from option values).
    static let buildValueOptions: Set<String> = [
        "-t", "--tag", "-f", "--file", "--build-arg", "--label", "--target", "--platform", "--network", "--cache-from",
        "--add-host", "--cgroup-parent", "--cpu-period", "--cpu-quota", "-c", "--cpu-shares", "--cpuset-cpus", "--cpuset-mems",
        "--isolation", "-m", "--memory", "--memory-swap", "--security-opt", "--shm-size", "--ulimit", "--progress", "--iidfile",
        "--builder", "--allow", "--annotation", "--call", "--check", "--metadata-file", "--no-cache-filter", "--provenance",
        "--sbom", "--secret", "--ssh", "--build-context", "--cache-to", "--attest", "-o", "--output",
    ]

    /// The positional context of a build (the last word that is neither an option nor an option's value).
    static func buildContext(_ arguments: [String], from start: Int) -> String? {
        var index = start + (arguments[start] == "build" ? 1 : 2)
        var context: String?
        while index < arguments.count {
            let word = arguments[index]
            if word.hasPrefix("-"), word != "-" {
                index += buildValueOptions.contains(optionName(word)) && !word.contains("=") && !(word.count > 2 && !word.hasPrefix("--")) ? 2 : 1
                continue
            }
            context = word
            index += 1
        }
        return context
    }

    static func checkOptions(_ arguments: [String]) throws(Refusal) {
        for (position, word) in arguments.enumerated() where word == "--cache-from" && position + 1 < arguments.count {
            if arguments[position + 1].contains("=") { throw .hostInput("--cache-from") }
        }
        var index = 0
        while index < arguments.count, arguments[index].hasPrefix("-") {
            let name = optionName(arguments[index])
            if harmlessGlobalOptions.contains(name), !arguments[index].contains("=") {
                index += 1
                continue
            }
            if terminalGlobalOptions.contains(name), !arguments[index].contains("="), index == arguments.count - 1 { return }
            throw .globalOption(name)
        }
        guard index < arguments.count else { return }
        let subcommand = arguments[index]
        guard allowedSubcommands.contains(subcommand) else { throw .subcommand(subcommand) }
        index += 1
        if let options = groupOptions[subcommand] {
            while index < arguments.count, arguments[index].hasPrefix("-") {
                let word = arguments[index]
                let name = optionName(word)
                if endpointOptionsAnywhere.contains(name) { throw .globalOption(name) }
                if terminalGlobalOptions.contains(name), index == arguments.count - 1 { return }
                guard let takesValue = options[name] else { throw .unknownOption("\(subcommand) \(name)") }
                index += takesValue && !word.contains("=") ? 2 : 1
            }
            if index < arguments.count {
                let nested = arguments[index]
                if refusedNested[subcommand]?.contains(nested) == true { throw .subcommand("\(subcommand) \(nested)") }
                if subcommand == "buildx", !allowedBuildx.contains(nested) { throw .subcommand("buildx \(nested)") }
            }
        }
        for argument in arguments {
            let name = optionName(argument)
            if writingOptions.contains(name) { throw .option(name) }
            if hostInputOptions.contains(name) { throw .hostInput(name) }
            // `--cache-from` names an image for the classic builder; a `type=local,src=…` cache is a host folder.
            if name == "--cache-from", argument.dropFirst("--cache-from=".count).contains("=") { throw .hostInput(name) }
            // Anywhere on the line (strict: a container argument spelled the same is refused too, never guessed).
            if endpointOptionsAnywhere.contains(name) { throw .globalOption(name) }
            // Short options attached or clustered: `-o/tmp/x`, `-qo x`, `-Hunix:///…`.
            if argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.count > 2 {
                let cluster = argument.dropFirst().prefix { $0 != "=" }
                if cluster.contains("o") { throw .option("-o") }
                if cluster.contains("H") { throw .globalOption("-H") }
            }
        }
    }

    /// `--name=value` → `--name`; `-x` → `-x`.
    static func optionName(_ word: String) -> String {
        String(word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }
}
