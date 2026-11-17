import Foundation

/// How the supervised server runs commands in containers (docs/features/containers.md). With this set, opencode's
/// shell (agent shell tool, `/api/shell`, `!`cmd`` in command templates, schedule conditions, legacy PTYs) is
/// `bellocode-exec`, which forwards every command into the project's workspace container and never runs anything on
/// the Mac; the bundled plugin's guard hook forces the shell back to it; repository config (plugins, agents, a
/// `"shell"`) is ignored; formatters and LSP are off (they would run project tooling on the host); host git runs
/// without hooks.
public struct ContainerExecution: Sendable, Hashable {
    /// `Contents/Helpers/bellocode-exec`.
    public var helperURL: URL
    /// The helper's configuration file (written by the app; `BELLOCODE_EXEC_CONFIG`).
    public var execConfigURL: URL

    public init(helperURL: URL, execConfigURL: URL) {
        self.helperURL = helperURL
        self.execConfigURL = execConfigURL
    }

    /// The internal command the isolation self-check invokes (its `!`…`` runs through the configured shell). Its model
    /// does not exist, so invoking it never sends a prompt anywhere.
    public static let verifyCommandName = "bellocode-verify-isolation"
    /// Where that command's probe writes inside the container (never a project folder).
    public static let verifyCommandMarker = "/tmp/bellocode-verify-command"

    /// A POSIX probe that prints `container <kernel>` inside a BelloCode workspace container and `host <kernel>`
    /// anywhere else.
    public static let probe = #"if [ -n "$BELLOCODE_WORKSPACE" ] || [ -f /.dockerenv ]; then printf 'container '; else printf 'host '; fi; uname -s"#

    /// Environment the server gets on top of the defaults.
    public var environment: [String: String] {
        [
            "SHELL": helperURL.path,
            "BELLOCODE_EXEC_CONFIG": execConfigURL.path,
            "BELLOCODE_EXEC_PATH": helperURL.path,
            // Repository opencode.json, .opencode/ plugins, agents and commands would run inside opencode on the host.
            "OPENCODE_DISABLE_PROJECT_CONFIG": "1",
            // Host git (snapshots, diffs, worktrees) never runs repository hooks (husky and friends would execute
            // project code on the Mac). bellocode-exec strips GIT_CONFIG_* so the container's git keeps them.
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.hooksPath",
            "GIT_CONFIG_VALUE_0": "/dev/null",
        ]
    }

    /// Additions to `OPENCODE_CONFIG_CONTENT`.
    var configAdditions: [String: JSONValue] {
        [
            "shell": .string(helperURL.path),
            "formatter": .bool(false),
            "lsp": .bool(false),
            "commands": .object([
                Self.verifyCommandName: .object([
                    "description": .string("BelloCode internal: proves command templates run in the project's container."),
                    "template": .string("!`" + Self.probe.replacingOccurrences(of: "`", with: "") + " > \(Self.verifyCommandMarker)`"),
                    "model": .string("bellocode-verify/none"),
                ])
            ]),
        ]
    }

    /// Options for the bundled plugin's container guard (`shell.create.before` → the helper) and guidance.
    var pluginOptions: JSONValue {
        .object(["helper": .string(helperURL.path), "config": .string(execConfigURL.path)])
    }
}

extension ServerConfiguration {
    /// Variables that must never reach the server child: with `BUN_BE_BUN` set, the opencode binary is a JavaScript
    /// runtime on the host (`opencode script.js`). Removed whatever the caller passes.
    public static let forbiddenEnvironmentPrefixes = ["BUN_"]
}
