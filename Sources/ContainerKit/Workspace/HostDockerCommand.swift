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

    /// The argv to run (with the docker binary at `docker`), or the reason it is refused.
    public static func argv(for line: String, docker: String) throws(Refusal) -> [String] {
        let words = try Self.words(line)
        guard let program = words.first else { throw .empty }
        if program.contains("=") { throw .shellSyntax("a variable assignment") }
        guard program == "docker" || program == docker else { throw .notDocker(program) }
        try check(arguments: Array(words.dropFirst()))
        return [docker] + words.dropFirst()
    }

    /// Validates docker's arguments (also used for relayed `--stdio` programs).
    public static func check(arguments: [String]) throws(Refusal) {
        guard let subcommand = arguments.first else { return }
        if subcommand.hasPrefix("-") {
            let name = String(subcommand.split(separator: "=").first ?? "")
            if endpointOptions.contains(name) || !["-v", "--version", "-D", "--debug", "--help", "-h"].contains(name) {
                throw .globalOption(name)
            }
            return
        }
        guard allowedSubcommands.contains(subcommand) else { throw .subcommand(subcommand) }
        let rest = arguments.dropFirst()
        if let nested = refusedNested[subcommand], let second = rest.first(where: { !$0.hasPrefix("-") }), nested.contains(second) {
            throw .subcommand("\(subcommand) \(second)")
        }
        for argument in rest {
            let name = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
            if writingOptions.contains(name) { throw .option(name) }
            // Anywhere on the line (strict: a container argument spelled the same is refused too, never guessed).
            if ["-H", "--host", "--context", "--config"].contains(name) { throw .globalOption(name) }
        }
    }
}
