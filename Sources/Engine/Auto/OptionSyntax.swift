import Foundation

/// How command-line programs spell their options, for the risk policy (GW02, AF14).
///
/// `getopt_long` (GNU and BSD utilities) and git's `parse-options` accept any unique abbreviation of a long option
/// (`--out=FILE` is `--output=FILE`), take a required value attached (`--opt=v`) or as the next word (`--opt v`), an
/// optional value only attached, and read a single-dash word as a cluster of short options (`-ro FILE` is `-r -o FILE`,
/// `-oFILE` is `-o FILE`). Exact spellings are therefore never enough to recognise an option: these helpers match every
/// spelling a program could read as the option, erring towards a match.
enum OptionSyntax {
    /// The name in `--name` or `--name=value` (possibly empty: `--=x`), or nil for anything else, `--` included.
    static func longName(_ arg: String) -> Substring? {
        guard arg.hasPrefix("--"), arg != "--" else { return nil }
        return arg.dropFirst(2).prefix { $0 != "=" }
    }

    /// Whether a program that abbreviates could read `arg` as one of `options` (names without `--`): `--name` or
    /// `--name=value` where `name` is a prefix of the option, one letter (`--o`) or none (`--=x`) included. An exact
    /// spelling of another option in `exact` wins, as it does in getopt_long and parse-options (`git diff --text` is
    /// not `--textconv`).
    static func abbreviates(_ arg: String, _ options: [String], exact: Set<String> = []) -> Bool {
        guard let name = longName(arg) else { return false }
        if exact.contains(String(name)) { return false }
        return options.contains { $0.hasPrefix(name) }
    }

    /// A word of single-dash short options (`-abc`): not `-`, not `--…`.
    static func isShortCluster(_ arg: String) -> Bool {
        arg.hasPrefix("-") && !arg.hasPrefix("--") && arg.count > 1
    }

    /// Whether the cluster `arg` contains one of `letters` anywhere. Letters after one that takes a value are that
    /// option's value, not options; counting them anyway errs towards a match.
    static func cluster(_ arg: String, contains letters: Set<Character>) -> Bool {
        isShortCluster(arg) && arg.dropFirst().contains { letters.contains($0) }
    }

    /// The words a short option `letter` that takes a value could receive in `args`: the rest of a cluster after its
    /// first `letter` when there is one, and the next word otherwise. Every cluster holding the letter counts.
    static func shortValues(_ args: [String], _ letter: Character) -> [String] {
        var values: [String] = []
        for (index, arg) in args.enumerated() where isShortCluster(arg) {
            guard let position = arg.dropFirst().firstIndex(of: letter) else { continue }
            let rest = String(arg[arg.index(after: position)...])
            if !rest.isEmpty { values.append(rest) } else if index + 1 < args.count { values.append(args[index + 1]) }
        }
        return values
    }

    /// The values a long option that abbreviates to one of `options` could receive: after `=`, or the next word.
    static func longValues(_ args: [String], _ options: [String], exact: Set<String> = []) -> [String] {
        var values: [String] = []
        for (index, arg) in args.enumerated() where abbreviates(arg, options, exact: exact) {
            if let equals = arg.firstIndex(of: "=") { values.append(String(arg[arg.index(after: equals)...])) }
            else if index + 1 < args.count { values.append(args[index + 1]) }
        }
        return values
    }
}

/// How a version of grep reads its arguments: what is an option, which options take a value, and which words are the
/// pattern and the operands (AF14). GNU grep (3.x, what the workspace containers run) and BSD grep (2.6.0-FreeBSD,
/// macOS) differ, so the policy reads every command both ways.
struct GrepGrammar: Sendable {
    enum Value: Sendable { case none, required, optional }

    struct Long: Sendable {
        var name: String
        var value: Value
        /// Options with the same meaning (`--color`, `--colour`) resolve an abbreviation of both without ambiguity.
        var meaning: String
    }

    var long: [Long]
    /// Short options whose value is the rest of the word or the next word.
    var shortRequired: Set<Character>
    /// Short options whose value can only be attached (BSD `-C[num]`).
    var shortOptional: Set<Character>

    /// The long options `name` could be: the exact one, else every option it abbreviates. Empty: unknown. More than one
    /// meaning: ambiguous (grep refuses it).
    func resolve(_ name: Substring) -> [Long] {
        if let exact = long.first(where: { $0.name == name }) { return [exact] }
        let matches = long.filter { $0.name.hasPrefix(name) }
        var meanings: [String] = []
        for match in matches where !meanings.contains(match.meaning) { meanings.append(match.meaning) }
        return meanings.count == 1 ? [matches[0]] : matches
    }

    private static func table(_ entries: [(String, Value)], aliases: [String: String] = [:]) -> [Long] {
        entries.map { Long(name: $0.0, value: $0.1, meaning: aliases[$0.0] ?? $0.0) }
    }

    /// GNU grep 3.11 `long_options`.
    static let gnu = GrepGrammar(
        long: table([
            ("basic-regexp", .none), ("extended-regexp", .none), ("fixed-regexp", .none), ("fixed-strings", .none),
            ("perl-regexp", .none), ("after-context", .required), ("before-context", .required), ("binary-files", .required),
            ("byte-offset", .none), ("context", .required), ("color", .optional), ("colour", .optional), ("count", .none),
            ("devices", .required), ("directories", .required), ("dereference-recursive", .none), ("exclude", .required),
            ("exclude-from", .required), ("exclude-dir", .required), ("file", .required), ("files-with-matches", .none),
            ("files-without-match", .none), ("group-separator", .required), ("help", .none), ("include", .required),
            ("ignore-case", .none), ("no-ignore-case", .none), ("initial-tab", .none), ("label", .required),
            ("line-buffered", .none), ("line-number", .none), ("line-regexp", .none), ("max-count", .required),
            ("no-filename", .none), ("no-group-separator", .none), ("no-messages", .none), ("null", .none),
            ("null-data", .none), ("only-matching", .none), ("quiet", .none), ("recursive", .none), ("regexp", .required),
            ("invert-match", .none), ("silent", .none), ("text", .none), ("binary", .none), ("unix-byte-offsets", .none),
            ("version", .none), ("with-filename", .none), ("word-regexp", .none),
        ], aliases: ["colour": "color", "fixed-regexp": "fixed-strings", "silent": "quiet"]),
        shortRequired: ["A", "B", "C", "D", "X", "d", "e", "f", "m"], shortOptional: [])

    /// BSD grep 2.6.0-FreeBSD (macOS) `long_options`.
    static let bsd = GrepGrammar(
        long: table([
            ("binary-files", .required), ("help", .none), ("mmap", .none), ("line-buffered", .none), ("label", .required),
            ("null", .none), ("color", .optional), ("colour", .optional), ("exclude", .required), ("include", .required),
            ("exclude-dir", .required), ("include-dir", .required), ("after-context", .required), ("text", .none),
            ("before-context", .required), ("byte-offset", .none), ("context", .optional), ("count", .none),
            ("devices", .required), ("directories", .required), ("extended-regexp", .none), ("regexp", .required),
            ("fixed-strings", .none), ("file", .required), ("basic-regexp", .none), ("no-filename", .none),
            ("with-filename", .none), ("ignore-case", .none), ("bz2decompress", .none), ("files-with-matches", .none),
            ("files-without-match", .none), ("max-count", .required), ("lzma", .none), ("line-number", .none),
            ("only-matching", .none), ("quiet", .none), ("silent", .none), ("recursive", .none), ("no-messages", .none),
            ("binary", .none), ("unix-byte-offsets", .none), ("invert-match", .none), ("version", .none),
            ("word-regexp", .none), ("line-regexp", .none), ("xz", .none), ("null-data", .none), ("decompress", .none),
        ], aliases: ["colour": "color", "silent": "quiet"]),
        shortRequired: ["A", "B", "D", "d", "e", "f", "m"], shortOptional: ["C"])
}
