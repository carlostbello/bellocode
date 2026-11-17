import ContainerKit
import Foundation

/// A throwaway repository whose configuration turns every git extension point into a program that, if git ever ran it,
/// creates a marker file. Used by the isolation self-check's host git probe and by the tests
/// (docs/features/containers.md, "Host git"). Everything lives under one temporary folder that `remove()` deletes.
public struct HostileRepository: Sendable {
    public let base: String
    public let root: String
    public let markers: String
    public let origin: String

    /// The configuration vectors, by marker name. `%M` is replaced with the marker path.
    public static let configVectors: [(name: String, key: String, value: String)] = [
        ("fsmonitor", "core.fsmonitor", "%S"),
        ("filter-clean", "filter.evil.clean", "%S"),
        ("filter-smudge", "filter.evil.smudge", "%S"),
        ("filter-process", "filter.evilp.process", "%S"),
        ("textconv", "diff.evil.textconv", "%S"),
        ("diff-command", "diff.evil.command", "%S"),
        ("diff-external", "diff.external", "%S"),
        ("pager", "core.pager", "%S"),
        ("pager-status", "pager.status", "%S"),
        ("pager-diff", "pager.diff", "%S"),
        ("pager-log", "pager.log", "%S"),
        ("editor", "core.editor", "%S"),
        ("sequence-editor", "sequence.editor", "%S"),
        ("askpass", "core.askPass", "%S"),
        ("gpg", "gpg.program", "%S"),
        ("gpg-ssh", "gpg.ssh.program", "%S"),
        ("ssh-command", "core.sshCommand", "%S"),
        ("credential", "credential.helper", "!%S"),
        ("credential-url", "credential.https://example.invalid.helper", "!%S"),
        ("alias", "alias.status", "!%S"),
        ("git-proxy", "core.gitProxy", "%S"),
        ("alternate-refs", "core.alternateRefsCommand", "%S"),
        ("uploadpack", "remote.origin.uploadpack", "%S"),
        ("receivepack", "remote.origin.receivepack", "%S"),
        ("pack-objects-hook", "uploadpack.packObjectsHook", "%S"),
        ("merge-driver", "merge.evil.driver", "%S"),
        ("trailer", "trailer.evil.command", "%S"),
        ("ext-insteadof", "url.ext::%S #.insteadOf", "https://example.invalid/"),
    ]

    /// Hooks written into `.git/hooks` and into a `core.hooksPath` folder.
    public static let hookNames = [
        "pre-commit", "prepare-commit-msg", "commit-msg", "post-commit", "post-checkout", "post-index-change", "reference-transaction",
        "pre-push", "pre-receive", "update", "post-receive", "post-update", "pre-auto-gc", "fsmonitor-watchman", "push-to-checkout",
    ]

    /// Creates the repository with one commit (made with plain git before anything hostile is configured), a bare
    /// `origin` it is pushed to, then writes the hostile configuration straight into `.git/config` (as a process in the
    /// container would).
    public static func make() throws -> HostileRepository {
        let base = HostGit.canonical(FileManager.default.temporaryDirectory.appending(path: "bellocode-hostile-\(UUID().uuidString)").path)
        let repository = HostileRepository(base: base, root: base + "/repo", markers: base + "/markers", origin: base + "/origin.git")
        try repository.build()
        return repository
    }

    public func remove() { try? FileManager.default.removeItem(atPath: base) }

    /// Markers that exist: each is a program git ran.
    public var fired: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: markers)) ?? []).sorted()
    }

    func script(_ name: String) -> String { base + "/bin/\(name)" }

    private func build() throws {
        let fileManager = FileManager.default
        for directory in [root, markers, base + "/bin", base + "/hooks"] { try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true) }
        // One executable per vector; each records that it ran, then behaves like `cat` so filters do not lose content.
        for name in Self.configVectors.map(\.name) + Self.hookNames.map({ "hook-" + $0 }) + ["submodule-fsmonitor", "include", "include-if"] {
            let path = script(name)
            try Data("#!/bin/sh\n: > '\(markers)/\(name)'\ncat 2>/dev/null\nexit 0\n".utf8).write(to: URL(filePath: path))
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        try plain(["init", "-q", "-b", "main"], in: root)
        try Data("hello\n".utf8).write(to: URL(filePath: root + "/README.md"))
        try Data("x\n".utf8).write(to: URL(filePath: root + "/data.bin"))
        try Data("* filter=evil diff=evil merge=evil\n*.bin filter=evilp\n".utf8).write(to: URL(filePath: root + "/.gitattributes"))
        try plain(["add", "-A"], in: root)
        try plain(["commit", "-q", "-m", "initial"], in: root)
        try plain(["init", "-q", "--bare", "-b", "main", origin], in: base)
        try plain(["remote", "add", "origin", origin], in: root)
        try plain(["push", "-q", "origin", "main"], in: root)
        try plain(["remote", "add", "sshremote", "ssh://127.0.0.1:1/x.git"], in: root)
        try plain(["remote", "add", "gitremote", "git://127.0.0.1:1/x.git"], in: root)
        try plain(["remote", "add", "extremote", "ext::\(script("ext-vcs")) %S"], in: root)

        // Hooks: in the repository, in the origin, and in a hooksPath folder.
        for hook in Self.hookNames {
            for folder in [root + "/.git/hooks", origin + "/hooks", base + "/hooks"] {
                let path = folder + "/" + hook
                try Data("#!/bin/sh\n: > '\(markers)/hook-\(hook)'\nexit 0\n".utf8).write(to: URL(filePath: path))
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            }
        }
        // Included files with their own hostile settings.
        try Data("[core]\n\tfsmonitor = \(script("include"))\n".utf8).write(to: URL(filePath: base + "/included.config"))
        try Data("[core]\n\tfsmonitor = \(script("include-if"))\n".utf8).write(to: URL(filePath: base + "/included-if.config"))

        var config = "\n[core]\n\thooksPath = \(base)/hooks\n"
        for vector in Self.configVectors {
            let value = vector.value.replacingOccurrences(of: "%S", with: script(vector.name))
            let key = vector.key.replacingOccurrences(of: "%S", with: script(vector.name))
            config += Self.configLine(key: key, value: value)
        }
        config += "[remote \"extremote\"]\n\tvcs = ext\n"
        config += "[protocol]\n\tallow = always\n[protocol \"ext\"]\n\tallow = always\n[protocol \"file\"]\n\tallow = always\n"
        config += "[commit]\n\tgpgSign = true\n[tag]\n\tgpgSign = true\n[log]\n\tshowSignature = true\n[gpg]\n\tformat = openpgp\n"
        config += "[filter \"evil\"]\n\trequired = false\n"
        config += "[include]\n\tpath = \(base)/included.config\n"
        config += "[includeIf \"gitdir:\(root)/\"]\n\tpath = \(base)/included-if.config\n"
        config += "[status]\n\tshowUntrackedFiles = all\n[gc]\n\tauto = 1\n[maintenance]\n\tauto = true\n"
        let handle = try FileHandle(forWritingTo: URL(filePath: root + "/.git/config"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(config.utf8))
        try handle.close()
        // Dirty the tree so status, diff and add have work (and refresh the index through the filters).
        try Data("hello\nchanged\n".utf8).write(to: URL(filePath: root + "/README.md"))
        try Data("new\n".utf8).write(to: URL(filePath: root + "/untracked.txt"))
    }

    /// `section.sub.name = value` as a config file line (sections with subsections quoted).
    static func configLine(key: String, value: String) -> String {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let name = parts.last ?? key
        let section = parts.first ?? key
        let quoted = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        if parts.count > 2 {
            let sub = parts.dropFirst().dropLast().joined(separator: ".")
            return "[\(section) \"\(sub)\"]\n\t\(name) = \"\(quoted)\"\n"
        }
        return "[\(section)]\n\t\(name) = \"\(quoted)\"\n"
    }

    /// Plain, unconfined git for building the fixture (before anything hostile exists): no user configuration.
    func plain(_ arguments: [String], in directory: String) throws {
        let process = Process()
        process.executableURL = URL(filePath: HostGit.realGit() ?? "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "protocol.file.allow=always"] + arguments
        process.currentDirectoryURL = URL(filePath: directory, directoryHint: .isDirectory)
        process.environment = [
            "HOME": base, "PATH": HostGit.fixedPath, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "Probe",
            "GIT_AUTHOR_EMAIL": "probe@example.invalid", "GIT_COMMITTER_NAME": "Probe", "GIT_COMMITTER_EMAIL": "probe@example.invalid",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitError.failed(command: arguments.first ?? "git", status: process.terminationStatus, message: "fixture") }
    }

    /// The environment for confined runs against the fixture: no user configuration, a fixed identity.
    public var environment: [String: String] {
        var environment = GitRunner.defaultEnvironment()
        environment["HOME"] = base
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_AUTHOR_NAME"] = "Probe"
        environment["GIT_AUTHOR_EMAIL"] = "probe@example.invalid"
        environment["GIT_COMMITTER_NAME"] = "Probe"
        environment["GIT_COMMITTER_EMAIL"] = "probe@example.invalid"
        return environment
    }
}

/// The isolation self-check's host git probe: runs BelloCode's confined git (and opencode's, through the shim, when
/// its path is known) against a `HostileRepository` and reports any program git started on the Mac.
public enum HostGitProbe {
    /// `shim`: the `git` symlink first on opencode's PATH (`<data>/git-shim/git`), when the server is containerised.
    public static func run(shim: String?) async -> IsolationReport.Outcome {
        let repository: HostileRepository
        do {
            repository = try HostileRepository.make()
        } catch {
            return .skipped("could not build the scratch repository (\(error))")
        }
        defer { repository.remove() }
        let runner = GitRunner(environment: repository.environment)
        guard runner.invocation(["status"], in: repository.root, writableRoots: [], trusted: .init()) != nil else {
            return .failed("host git cannot run inside its sandbox (sandbox-exec or the Command Line Tools are missing); BelloCode refuses to run it")
        }
        let git = GitRepository(directory: repository.root, runner: runner)
        _ = try? await git.status()
        _ = try? await git.diff(.unstaged)
        _ = try? await git.diff(.commit("HEAD"))
        try? await git.stage(["README.md", "untracked.txt"])
        _ = try? await git.diff(.staged)
        _ = try? await git.commit(message: "probe")
        _ = try? await git.commits()
        _ = try? await runner.run(["fetch", "sshremote"], in: repository.root, timeout: .seconds(20), allowFailure: true)
        var ran = ["status", "diff", "add", "commit", "log", "fetch"]
        if let shim {
            for arguments in [["status"], ["diff"], ["add", "-A"], ["log", "-1"], ["checkout", "--", "README.md"]] {
                _ = try? await runProgram(shim, arguments, in: repository.root, environment: repository.environment)
            }
            ran.append("opencode's git")
        }
        let fired = repository.fired
        if !fired.isEmpty { return .host("host git ran repository-configured programs on this Mac: \(fired.joined(separator: ", "))") }
        return .confined("\(HostileRepository.configVectors.count + HostileRepository.hookNames.count) hostile settings and hooks; nothing ran (\(ran.joined(separator: ", ")))")
    }

    private static func runProgram(_ path: String, _ arguments: [String], in directory: String, environment: [String: String]) async throws -> GitOutput {
        try await GitRunner(environment: environment).runProgram(URL(filePath: path), arguments, in: directory, environment: environment, timeout: .seconds(20))
    }
}
