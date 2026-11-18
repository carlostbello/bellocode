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
    public static let version = "bellocode-auto-1"

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

    public static func decide(_ action: Action, in context: Context) -> Verdict {
        let findings = self.findings(action, in: context)
        if let violation = findings.first(where: { $0.category == .policyViolation }) { return .deny(violation) }
        let mandatory = findings.filter { $0.category != .policyViolation }
        if !mandatory.isEmpty { return .escalate(unique(mandatory)) }
        if let allow = deterministicAllow(action, in: context) { return .allow(allow.0, allow.1) }
        return .review(describe(action))
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
            // Paths in arguments (options' values too), relative to the current directory.
            for arg in args {
                let value = arg.hasPrefix("-") ? (arg.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? "") : arg
                if value.hasPrefix("@") { found += argPathFindings(String(value.dropFirst()), cwd: cwd, in: context) }
                else if looksLikePath(value) { found += argPathFindings(value, cwd: cwd, in: context) }
            }
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

    static func argPathFindings(_ value: String, cwd: String, in context: Context) -> [RiskFinding] {
        if value.contains("://") { return [] }
        if ["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/stdin", "/dev/tty", "-"].contains(value) { return [] }
        return pathFindings(value, writes: false, in: context, base: cwd, shell: true)
    }

    static func redirectFindings(_ redirect: ShellAnalysis.Redirect, cwd: String, in context: Context) -> [RiskFinding] {
        if redirect.op.hasSuffix("&") || redirect.op.hasPrefix("<<") || redirect.target.isEmpty { return [] }
        return argPathFindings(redirect.target, cwd: cwd, in: context)
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
            if name == "rm", flags.contains("r") || flags.contains("R") || flags.contains("f") || args.contains("--recursive") || args.contains("--force") || command.hasGlob {
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
            for arg in positional where name == "export" {
                let variable = String(arg.prefix { $0 != "=" })
                if networkPolicyVariables.contains(variable) { found.append(RiskFinding(.policyChange, variable)) }
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
        let has = { (flags: [String]) in tail.contains { arg in flags.contains(arg) || flags.contains { $0.hasPrefix("--") && arg.hasPrefix($0 + "=") } } }
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
        case "gc" where tail.contains(where: { $0.hasPrefix("--prune") }): found.append(RiskFinding(.destructiveGit, "gc --prune"))
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
        let credentialHeader = zip(lower, lower.dropFirst()).contains { flag, value in
            (flag == "-h" || flag == "--header") && ["authorization", "token", "api-key", "apikey", "x-api-key", "cookie", "private-token", "x-auth"].contains { value.contains($0) }
        } || lower.contains { $0.hasPrefix("--header=") && ["authorization", "token", "api-key", "cookie"].contains(where: $0.contains) }
        let userFlag = args.contains { ["-u", "--user", "--oauth2-bearer", "--netrc", "--netrc-file", "-b", "--cookie", "--http-user", "--http-password", "--password", "--header=Authorization"].contains($0) }
        let upload = zip(args, args.dropFirst()).contains { flag, value in
            (["-d", "--data", "--data-binary", "--data-raw", "--data-urlencode", "-F", "--form", "-T", "--upload-file", "--post-file", "--body-file"].contains(flag)) && (value.hasPrefix("@") || value.contains("=@") || flag == "-T" || flag == "--upload-file" || flag == "--post-file" || flag == "--body-file")
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
        "true", "false", "test", "[", "diff", "cmp", "less", "more", "nl", "column", "printf", "seq", "yes", "sleep", "readlink",
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
            if name == "git" {
                let positional = command.arguments.filter { !$0.hasPrefix("-") }
                guard let sub = positional.first else { return false }
                if command.arguments.first?.hasPrefix("-") == true { return false }
                if sub == "branch" || sub == "tag" || sub == "remote" || sub == "stash" {
                    guard positional.count == 1 || (sub == "stash" && positional.dropFirst().first == "list") else { return false }
                    if command.arguments.contains(where: { ["-d", "-D", "--delete", "-m", "-M", "-c", "-C", "--set-upstream-to", "-u"].contains($0) }) { return false }
                    continue
                }
                if !readOnlyGit.contains(sub) { return false }
                if sub == "reflog", positional.dropFirst().first.map({ ["expire", "delete"].contains($0) }) == true { return false }
                if command.arguments.contains(where: { $0.hasPrefix("--output") || $0 == "-o" }) { return false }
                continue
            }
            if !readOnlyPrograms.contains(name) { return false }
            if name == "find", command.arguments.contains(where: { ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprintf", "-fls"].contains($0) }) { return false }
            if name == "sort", command.arguments.contains(where: { $0 == "-o" || $0.hasPrefix("--output") }) { return false }
            if name == "xxd", command.arguments.contains("-r") { return false }
        }
        return true
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
