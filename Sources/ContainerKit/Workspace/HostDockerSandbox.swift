import Foundation

/// The confinement of the docker client in "Host shell, docker only" mode (N03, A06). Docker's client reads and writes
/// host files itself before any request reaches the filtered endpoint: `--env-file`, `--label-file`, a build's
/// `-f` and context, Compose files with their `env_file`, `include`, `extends` and build contexts, BuildKit secrets
/// and caches. Checking arguments cannot see what a Compose file names, so the client runs under macOS's sandbox
/// (`sandbox-exec`) with a profile that:
///
/// - denies reading and writing anything under `/Users`, `/Volumes` and the temporary folders, except the project's
///   folders (its roots, read-write), BelloCode's docker configuration (read-only) and docker's own installation
///   (read-only); file metadata stays visible so paths resolve;
/// - denies every other write (system locations are read-only anyway);
/// - denies outbound network except TCP to the filtered endpoint's port on the loopback, so no other daemon socket
///   (Rancher's raw socket, a `DOCKER_HOST` from a Compose `.env`) and no remote build context can be reached.
///
/// Paths go in as parameters (`-D NAME=value`), never spliced into the profile text.
public enum HostDockerSandbox {
    public static let sandboxExec = "/usr/bin/sandbox-exec"

    public struct Paths: Sendable, Equatable {
        /// Folders the client may read and write (the project's roots).
        public var readWrite: [String]
        /// Folders the client may read (docker's installation, BelloCode's docker configuration).
        public var readOnly: [String]
        public init(readWrite: [String], readOnly: [String]) {
            self.readWrite = readWrite
            self.readOnly = readOnly
        }
    }

    /// The profile text for `paths` (referenced as parameters) and the endpoint `port`.
    public static func profile(readWrite: Int, readOnly: Int, port: Int) -> String {
        var lines = [
            "(version 1)",
            "(allow default)",
            // User data, other volumes and temporary folders: nothing by default.
            "(deny file-read* file-write* (subpath \"/Users\") (subpath \"/Volumes\") (subpath \"/private/var/folders\") (subpath \"/private/tmp\") (subpath \"/private/var/tmp\"))",
            // No writes anywhere else either.
            "(deny file-write* (subpath \"/\"))",
            // Names and attributes stay visible, so paths resolve; contents do not.
            "(allow file-read-metadata)",
            "(allow file-write* (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/dtracehelper\") (regex #\"^/dev/tty\") (regex #\"^/dev/fd/\"))",
        ]
        for index in 0..<readOnly { lines.append("(allow file-read* (subpath (param \"RO\(index)\")))") }
        for index in 0..<readWrite { lines.append("(allow file-read* file-write* (subpath (param \"RW\(index)\")))") }
        lines += [
            // Only the filtered endpoint: no other daemon socket, no remote context, no other local service.
            "(deny network-outbound)",
            "(allow network-outbound (remote ip \"localhost:\(port)\"))",
        ]
        return lines.joined(separator: "\n")
    }

    /// The argv that runs `argv` (docker and its arguments) confined, or nil when the sandbox is unavailable.
    public static func wrap(_ argv: [String], paths: Paths, port: Int, sandbox: String = sandboxExec) -> [String]? {
        guard FileManager.default.isExecutableFile(atPath: sandbox), port > 0, port < 65536 else { return nil }
        let readWrite = Self.canonicalFolders(paths.readWrite)
        let readOnly = Self.canonicalFolders(paths.readOnly)
        guard !readWrite.isEmpty else { return nil }
        var wrapped = [sandbox]
        for (index, path) in readOnly.enumerated() { wrapped += ["-D", "RO\(index)=\(path)"] }
        for (index, path) in readWrite.enumerated() { wrapped += ["-D", "RW\(index)=\(path)"] }
        wrapped += ["-p", profile(readWrite: readWrite.count, readOnly: readOnly.count, port: port)]
        return wrapped + argv
    }

    /// Canonical spellings (the sandbox matches resolved paths), existing folders only, never `/` or a folder that
    /// contains the home folder.
    static func canonicalFolders(_ paths: [String]) -> [String] {
        let home = CodeRootPaths.canonical(NSHomeDirectory()) ?? NSHomeDirectory()
        var seen = Set<String>()
        return paths.compactMap { CodeRootPaths.canonical($0) }.filter { path in
            path != "/" && !CodeRootPaths.inside(home, path) && seen.insert(path).inserted
        }
    }

    /// What docker's client needs to read: its own installation (the binary and plugins, links resolved) and
    /// BelloCode's docker configuration with the plugin links in it.
    public static func installationFolders(docker: String, configDirectory: String?) -> [String] {
        var folders: [String] = []
        func addInstallation(of binary: String) {
            let linkFolder = (binary as NSString).deletingLastPathComponent
            folders.append(linkFolder)
            if let resolved = CodeRootPaths.canonical(binary) {
                // `…/darwin/bin/docker`: the installation is the folder above `bin` (its plugins sit beside it).
                let binFolder = (resolved as NSString).deletingLastPathComponent
                folders.append((binFolder as NSString).deletingLastPathComponent)
            }
        }
        addInstallation(of: docker)
        if let configDirectory {
            folders.append(configDirectory)
            let plugins = (configDirectory as NSString).appendingPathComponent("cli-plugins")
            for name in (try? FileManager.default.contentsOfDirectory(atPath: plugins)) ?? [] {
                addInstallation(of: (plugins as NSString).appendingPathComponent(name))
                if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: (plugins as NSString).appendingPathComponent(name)) {
                    addInstallation(of: target)
                }
            }
        }
        return folders
    }

    /// The endpoint's port from a `DOCKER_HOST` such as `tcp://127.0.0.1:<port>/<token>`.
    public static func port(dockerHost: String) -> Int? {
        guard let url = URL(string: dockerHost), url.scheme == "tcp", let host = url.host, ["127.0.0.1", "localhost"].contains(host) else { return nil }
        return url.port
    }
}
