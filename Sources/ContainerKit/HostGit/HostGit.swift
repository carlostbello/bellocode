import Darwin
import Foundation

/// The confinement every git process on the Mac runs under: BelloCode's own (`GitRunner` in Engine) and opencode's
/// (through the `git` shim, `bellocode-exec` invoked as `git`, first on the server's PATH). See
/// docs/features/containers.md, "Host git".
///
/// Why: a repository's configuration is writable by whatever runs in the project's container (the project folder is
/// bind-mounted), and git turns configuration into program execution in many places (`core.fsmonitor`, clean/smudge/
/// process filters, textconv and external diff drivers, hooks, `core.sshCommand`, credential helpers, remote helpers,
/// pagers, editors, signing programs, …). Neutralising keys one by one cannot be complete (filter and diff drivers are
/// named by the repository, so the keys cannot be listed in advance, and a scan races the container), so the boundary
/// is enforced by the kernel instead:
///
/// 1. **Sandbox** (`sandbox-exec` profile, inherited by every child): local operations may execute only git itself and
///    its own `libexec/git-core` programs, have no network, and may write only inside the repository's working tree,
///    its `.git` directories and the roots the caller names. Network operations (fetch, push) may additionally execute
///    `ssh` and the system shells (credential helpers run through `sh`) and reach the network; the `ext` and `fd`
///    remote helpers stay blocked. Whatever a configuration names, git cannot start it: the attempt fails with
///    "Operation not permitted".
/// 2. **Configuration overrides** (`GIT_CONFIG_COUNT`, read after every file, so they win over the repository): hooks,
///    fsmonitor, pagers, editors, askpass, signing and automatic gc off; `ssh` and credential helpers only from the
///    user's own (system/global) configuration; transports limited to https and ssh. These keep git's behaviour clean
///    (no errors from blocked programs) and protect network operations, where the sandbox must allow a shell.
/// 3. **Environment**: an allowlist (no inherited `GIT_SSH*`, `GIT_EXTERNAL_DIFF`, pager or editor variables), a fixed
///    PATH, git's own exec path, no SSH agent except for network operations.
///
/// If the sandbox or git cannot be found, `invocation` returns nil and callers refuse to run git (never unconfined).
public enum HostGit {
    public enum Mode: Sendable, Hashable {
        /// Status, diff, add, commit, worktrees, refs, log: no network, no programs.
        case local
        /// fetch, push, pull, clone, ls-remote: network, `ssh` and shells for the user's own credential helpers.
        case network
    }

    /// A ready-to-launch confined git process.
    public struct Invocation: Sendable, Hashable {
        public var executable: String
        public var arguments: [String]
        public var environment: [String: String]
    }

    public static let sandboxExecutable = "/usr/bin/sandbox-exec"
    public static let fixedPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// git subcommands that use the network (run with `.network`).
    public static let networkSubcommands: Set<String> = ["fetch", "push", "pull", "clone", "ls-remote", "remote", "submodule", "fetch-pack", "send-pack"]

    // MARK: Locating git

    /// The real git binary (never Apple's `/usr/bin/git` xcrun stub, never a shim on PATH): `$DEVELOPER_DIR`, then the
    /// Command Line Tools, then Xcode.
    public static func realGit(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        var candidates: [String] = []
        if let developer = environment["DEVELOPER_DIR"], developer.hasPrefix("/") { candidates.append(developer + "/usr/bin/git") }
        candidates += [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(canonical)
    }

    /// git's own helper programs (`<prefix>/libexec/git-core`).
    public static func execPath(forGit git: String) -> String {
        canonical(((git as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent + "/libexec/git-core")
    }

    // MARK: Building an invocation

    /// The confined launch of `git <arguments>` in `directory`, or nil when the sandbox or git is unavailable (callers
    /// fail closed). `writableRoots` are trusted extra roots (for example a new worktree's parent); `gitDirectory` is
    /// an explicit git dir the caller chose (`--git-dir`), also trusted. `trusted` carries values from the user's own
    /// configuration for network operations (`trustedValues`).
    public static func invocation(
        arguments: [String], directory: String, mode: Mode, environment base: [String: String],
        writableRoots extra: [String] = [], trusted: TrustedConfiguration = TrustedConfiguration(),
        credentials: GitCredentialSetup? = nil
    ) -> Invocation? {
        guard FileManager.default.isExecutableFile(atPath: sandboxExecutable), let git = realGit(environment: base) else { return nil }
        let execPath = execPath(forGit: git)
        let roots = writableRoots(directory: directory, environment: base, extra: extra, mode: mode)
        // The app's credential helper may run only for network operations (never for local ones).
        let credentials = mode == .network ? credentials : nil
        var sandboxArguments = ["-p", profile(mode: mode, rootCount: roots.count, allowsCredentialHelper: credentials != nil)]
        sandboxArguments += ["-D", "GIT=\(git)", "-D", "EXEC_PATH=\(execPath)"]
        for (index, root) in roots.enumerated() { sandboxArguments += ["-D", "ROOT\(index)=\(root)"] }
        if mode == .network, let home = base["HOME"] { sandboxArguments += ["-D", "SSH_DIR=\(canonical(home + "/.ssh"))"] }
        if let credentials { sandboxArguments += ["-D", "CREDENTIAL_HELPER=\(canonical(credentials.helperPath))"] }
        return Invocation(
            executable: sandboxExecutable, arguments: sandboxArguments + [git] + arguments,
            environment: environment(base: base, mode: mode, execPath: execPath, trusted: trusted, credentials: credentials))
    }

    /// The sandbox profile. Paths come in as parameters (`-D`), so nothing in a path needs quoting.
    static func profile(mode: Mode, rootCount: Int, allowsCredentialHelper: Bool = false) -> String {
        var lines = [
            "(version 1)",
            "(allow default)",
            "(deny process-exec*)",
            #"(allow process-exec* (literal (param "GIT")) (subpath (param "EXEC_PATH")))"#,
        ]
        switch mode {
        case .local:
            lines.append("(deny network*)")
        case .network:
            lines.append(#"(allow process-exec* (literal "/usr/bin/ssh") (literal "/bin/sh") (literal "/bin/bash") (literal "/bin/zsh") (literal "/bin/dash"))"#)
            // Remote helpers that run arbitrary commands (also refused by the protocol allowlist).
            lines.append(#"(deny process-exec* (literal (string-append (param "EXEC_PATH") "/git-remote-ext")) (literal (string-append (param "EXEC_PATH") "/git-remote-fd")))"#)
            // BelloCode's own credential helper (`bellocode-exec --git-credential`), only when the app granted one.
            if allowsCredentialHelper { lines.append(#"(allow process-exec* (literal (param "CREDENTIAL_HELPER")))"#) }
        }
        lines.append("(deny file-write*)")
        lines.append(#"(allow file-write* (subpath "/dev"))"#)
        for index in 0..<rootCount { lines.append(#"(allow file-write* (subpath (param "ROOT\#(index)")))"#) }
        if mode == .network { lines.append(#"(allow file-write* (subpath (param "SSH_DIR")))"#) }
        return lines.joined(separator: "\n")
    }

    /// Configuration that wins over every file (GIT_CONFIG_COUNT is read last).
    static func overrides(mode: Mode, trusted: TrustedConfiguration) -> [(String, String)] {
        var pairs: [(String, String)] = [
            ("core.hooksPath", "/dev/null"),
            ("core.fsmonitor", "false"),
            ("core.pager", "cat"),
            ("core.editor", "true"),
            ("sequence.editor", "true"),
            ("core.askPass", ""),
            ("commit.gpgSign", "false"),
            ("tag.gpgSign", "false"),
            ("push.gpgSign", "false"),
            ("log.showSignature", "false"),
            ("gc.auto", "0"),
            ("maintenance.auto", "false"),
            ("safe.bareRepository", "explicit"),
            ("submodule.recurse", "false"),
            ("fetch.recurseSubmodules", "false"),
            ("push.recurseSubmodules", "no"),
            ("protocol.allow", "never"),
            ("protocol.https.allow", "always"),
            ("protocol.ssh.allow", "always"),
            ("core.sshCommand", trusted.sshCommand ?? "ssh"),
            // An empty value resets the helper list (repository and URL-scoped helpers included); then the user's own.
            ("credential.helper", ""),
        ]
        if mode == .network { pairs += trusted.credentialHelpers.map { ("credential.helper", $0) } }
        return pairs
    }

    /// Variables passed through from the caller; everything else is dropped.
    static let passedThrough: Set<String> = [
        "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "XDG_CONFIG_HOME", "GIT_INDEX_FILE", "GIT_DIR", "GIT_WORK_TREE",
        "GIT_OPTIONAL_LOCKS", "GIT_LITERAL_PATHSPECS", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM",
        "GIT_LFS_SKIP_SMUDGE", "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_AUTHOR_DATE", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL",
        "GIT_COMMITTER_DATE",
    ]

    static func environment(
        base: [String: String], mode: Mode, execPath: String, trusted: TrustedConfiguration, credentials: GitCredentialSetup? = nil
    ) -> [String: String] {
        var environment = base.filter { passedThrough.contains($0.key) }
        if mode == .network, let agent = base["SSH_AUTH_SOCK"] { environment["SSH_AUTH_SOCK"] = agent }
        environment["PATH"] = fixedPath
        environment["GIT_EXEC_PATH"] = execPath
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = ""
        environment["GIT_PAGER"] = "cat"
        environment["GIT_EDITOR"] = "true"
        environment["GIT_SEQUENCE_EDITOR"] = "true"
        environment["GIT_NO_LAZY_FETCH"] = "1"
        environment["GIT_PROTOCOL_FROM_USER"] = "0"
        // The caller's own -c style entries first (they are ours: opencode's server environment, tests), then ours.
        var pairs: [(String, String)] = []
        if let count = base["GIT_CONFIG_COUNT"].flatMap(Int.init), count > 0, count < 64 {
            for index in 0..<count {
                if let key = base["GIT_CONFIG_KEY_\(index)"], let value = base["GIT_CONFIG_VALUE_\(index)"] { pairs.append((key, value)) }
            }
        }
        pairs += overrides(mode: mode, trusted: trusted)
        // Per-URL settings for the app's GitLab remotes come last (they must win over everything above).
        if let credentials {
            pairs += credentials.overrides
            environment[GitCredentialHelper.socketVariable] = credentials.socketPath
            environment[GitCredentialHelper.grantVariable] = credentials.grant
        }
        environment["GIT_CONFIG_COUNT"] = String(pairs.count)
        for (index, pair) in pairs.enumerated() {
            environment["GIT_CONFIG_KEY_\(index)"] = pair.0
            environment["GIT_CONFIG_VALUE_\(index)"] = pair.1
        }
        return environment
    }

    // MARK: Writable roots

    /// Where git may write: the directory, the repository's git directories (only when they are `.git` directories: a
    /// repository can point its gitdir anywhere), the caller's trusted roots and, for opencode, its own data directory.
    static func writableRoots(directory: String, environment: [String: String], extra: [String], mode: Mode) -> [String] {
        var roots = [directory] + extra
        // git writes temporary blobs for textconv and external diffs there (the programs themselves cannot run).
        if let temporary = environment["TMPDIR"], temporary.hasPrefix("/") { roots.append(temporary) }
        if let explicit = environment["GIT_DIR"] { roots.append(resolve(explicit, against: directory)) }
        if let tree = environment["GIT_WORK_TREE"] { roots.append(resolve(tree, against: directory)) }
        for discovered in gitDirectories(from: environment["GIT_DIR"] == nil ? directory : nil) where isDotGit(discovered) {
            roots.append(discovered)
        }
        var seen: Set<String> = []
        return roots.map(canonical).filter { $0 != "/" && seen.insert($0).inserted }
    }

    /// The gitdir and common dir for a working directory, read from `.git` (directory or `gitdir:` file) and
    /// `commondir` without running git.
    static func gitDirectories(from directory: String?) -> [String] {
        guard var current = directory.map(canonical) else { return [] }
        let fileManager = FileManager.default
        while true {
            let dotGit = current + "/.git"
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                var gitDirectory = dotGit
                if !isDirectory.boolValue {
                    guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8), text.hasPrefix("gitdir:") else { return [] }
                    let path = text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                    gitDirectory = resolve(path, against: current)
                }
                var result = [canonical(gitDirectory)]
                if let common = try? String(contentsOfFile: gitDirectory + "/commondir", encoding: .utf8) {
                    result.append(canonical(resolve(common.trimmingCharacters(in: .whitespacesAndNewlines), against: gitDirectory)))
                }
                return result
            }
            if current == "/" || current.isEmpty { return [] }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    static func isDotGit(_ path: String) -> Bool {
        path.split(separator: "/").contains(".git")
    }

    static func resolve(_ path: String, against base: String) -> String {
        path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)
    }

    /// The real path (symlinks resolved, `/var` → `/private/var`), also for paths that do not exist yet (their deepest
    /// existing ancestor is resolved). The sandbox matches real paths.
    public static func canonical(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        var existing = standardized
        var rest: [String] = []
        while !existing.isEmpty, existing != "/" {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                var result = String(cString: resolved)
                for component in rest.reversed() { result = (result as NSString).appendingPathComponent(component) }
                return result
            }
            rest.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return standardized
    }

    // MARK: Trusted configuration

    /// Values of executable keys from the user's own configuration (system, global, Apple's built-in defaults), never
    /// from the repository: the credential helpers and `core.sshCommand` network operations may use.
    public struct TrustedConfiguration: Sendable, Hashable {
        public var credentialHelpers: [String] = []
        public var sshCommand: String?
        public init(credentialHelpers: [String] = [], sshCommand: String? = nil) {
            self.credentialHelpers = credentialHelpers
            self.sshCommand = sshCommand
        }
    }

    static let trustedScopes: Set<String> = ["system", "global", "unknown"]

    /// Parses `git config --show-scope -z --get-regexp '^(credential\.helper|core\.sshcommand)$'`.
    public static func parseTrusted(_ data: Data) -> TrustedConfiguration {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var result = TrustedConfiguration()
        var index = 0
        while index + 1 < fields.count {
            let scope = fields[index]
            let entry = fields[index + 1]
            index += 2
            guard trustedScopes.contains(scope), let newline = entry.firstIndex(of: "\n") else { continue }
            let key = entry[..<newline].lowercased()
            let value = String(entry[entry.index(after: newline)...])
            if key == "credential.helper" {
                if value.isEmpty { result.credentialHelpers.removeAll() } else { result.credentialHelpers.append(value) }
            } else if key == "core.sshcommand", !value.isEmpty {
                result.sshCommand = value
            }
        }
        return result
    }

    /// The arguments for reading the trusted values (run confined, `.local`).
    public static let trustedQuery = ["config", "--show-scope", "-z", "--get-regexp", #"^(credential\.helper|core\.sshcommand)$"#]

    /// Reads the trusted values synchronously (the shim; GitRunner has its own async runner).
    public static func trustedValues(directory: String, environment: [String: String]) -> TrustedConfiguration {
        guard let invocation = invocation(arguments: trustedQuery, directory: directory, mode: .local, environment: environment) else {
            return TrustedConfiguration()
        }
        let process = Process()
        process.executableURL = URL(filePath: invocation.executable)
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = URL(filePath: directory, directoryHint: .isDirectory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // Not `waitUntilExit`: in the helper's async top level it spins the main run loop and was seen never to return
        // (the shim hung on every network subcommand on macOS 27). The handler runs on a Foundation queue.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return TrustedConfiguration() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        return parseTrusted(data.prefix(64 << 10))
    }

    // MARK: Command lines

    /// The subcommand of a git command line (after global options such as `-C dir`, `-c k=v`, `--git-dir=…`).
    public static func subcommand(of arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"].contains(argument) {
                index += 2
                continue
            }
            if argument.hasPrefix("-") { index += 1; continue }
            return argument
        }
        return nil
    }

    /// Paths the caller named explicitly on the command line (`-C`, `--git-dir`, `--work-tree`): trusted roots.
    public static func explicitRoots(in arguments: [String], directory: String) -> [String] {
        var roots: [String] = []
        var base = directory
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-C" || argument == "--git-dir" || argument == "--work-tree", index + 1 < arguments.count {
                let value = resolve(arguments[index + 1], against: base)
                if argument == "-C" { base = value }
                roots.append(value)
                index += 2
                continue
            }
            for prefix in ["--git-dir=", "--work-tree="] where argument.hasPrefix(prefix) {
                roots.append(resolve(String(argument.dropFirst(prefix.count)), against: base))
            }
            if !argument.hasPrefix("-") { break }
            index += 1
        }
        return roots
    }

    /// The `git` shim (`bellocode-exec` invoked as `git`): replaces itself with confined git. Never returns.
    public static func shimMain(arguments: [String], environment: [String: String]) -> Never {
        let directory = FileManager.default.currentDirectoryPath
        let mode: Mode = subcommand(of: arguments).map { networkSubcommands.contains($0) } == true ? .network : .local
        var roots = explicitRoots(in: arguments, directory: directory)
        // opencode keeps its snapshots and worktrees in its own data directory.
        if let data = environment["XDG_DATA_HOME"], data.hasPrefix("/") { roots.append(data) }
        let trusted = mode == .network ? trustedValues(directory: directory, environment: environment) : TrustedConfiguration()
        guard let invocation = invocation(arguments: arguments, directory: directory, mode: mode, environment: environment, writableRoots: roots, trusted: trusted)
        else {
            FileHandle.standardError.write(Data("BelloCode: git runs on this Mac only inside its sandbox, and the sandbox or git is unavailable. Install the Command Line Tools. The command was not run.\n".utf8))
            exit(126)
        }
        let argv = ([invocation.executable] + invocation.arguments).map { strdup($0) } + [nil]
        let envp = invocation.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        execve(invocation.executable, argv, envp)
        FileHandle.standardError.write(Data("BelloCode: could not start sandboxed git (errno \(errno)). The command was not run.\n".utf8))
        exit(126)
    }
}
