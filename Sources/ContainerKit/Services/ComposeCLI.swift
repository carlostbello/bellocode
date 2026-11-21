import Foundation
import os

private let signposter = OSSignposter(subsystem: "app.bellocode.ContainerKit", category: "compose")

/// Rancher Desktop's `docker-compose` (the compose plugin binary in `~/.rd/bin`), for global compose-stack MCP servers
/// (docs/features/containers.md, "Global MCP servers"): full compose-spec fidelity (`build`, `env_file`, networks,
/// profiles, `extends`) without reimplementing it. Allowed by the owner (2026-11-18); resolved by explicit path, never
/// from `PATH`, and run against Rancher Desktop's socket (`DOCKER_HOST`) with a BelloCode-owned `DOCKER_CONFIG`, so
/// neither another engine (Docker Desktop's plugin in `~/.docker/cli-plugins`) nor the person's Docker configuration
/// or credential helpers are involved. Project services keep the Engine API (`ServiceManager`).
public struct ComposeCLI: Sendable {
    public let executable: URL
    public let socketPath: String
    /// `DOCKER_CONFIG`: a folder holding an empty `config.json` (public base images need no credentials).
    public let configDirectory: URL

    public init(executable: URL, socketPath: String, configDirectory: URL) {
        self.executable = executable
        self.socketPath = socketPath
        self.configDirectory = configDirectory
    }

    /// `~/.rd/bin/docker-compose` when it is an executable (a link into Rancher Desktop's bundle).
    public static func rancherExecutable(home: String = NSHomeDirectory()) -> URL? {
        let url = URL(filePath: home).appending(path: ".rd/bin/docker-compose")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    public struct Result: Sendable, Equatable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data
        public var text: String { String(decoding: stdout, as: UTF8.self) }
        /// The last lines of stderr (compose's own error), for messages.
        public var errorSummary: String {
            let lines = String(decoding: stderr, as: UTF8.self).split(separator: "\n").suffix(3)
            return lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
        public init(status: Int32, stdout: Data, stderr: Data) {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    /// The child's whole environment: nothing inherited but the home folder.
    public func environment() -> [String: String] {
        [
            "DOCKER_HOST": "unix://\(socketPath)",
            "DOCKER_CONFIG": configDirectory.path,
            "HOME": NSHomeDirectory(),
            "PATH": executable.deletingLastPathComponent().path + ":/usr/bin:/bin",
            "COMPOSE_ANSI": "never",
            "COMPOSE_STATUS_STDOUT": "0",
        ]
    }

    /// Compose builds through buildx (BuildKit: named build contexts, the certificates' `bellocode-ca`). With BelloCode's
    /// own `DOCKER_CONFIG` the plugin is looked up in `<config>/cli-plugins`, so Rancher Desktop's `docker-buildx` (next
    /// to `docker-compose`) is linked there; without it compose falls back to the classic builder.
    static func linkBuildx(beside executable: URL, into configDirectory: URL) throws {
        let buildx = executable.deletingLastPathComponent().appending(path: "docker-buildx")
        guard FileManager.default.isExecutableFile(atPath: buildx.path) else { return }
        let plugins = configDirectory.appending(path: "cli-plugins", directoryHint: .isDirectory)
        let link = plugins.appending(path: "docker-buildx")
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == buildx.path { return }
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: buildx.path)
    }

    /// The arguments for one call: project name, files, then the command.
    public static func arguments(project: String, files: [URL], workingDirectory: URL?, command: [String]) -> [String] {
        var arguments = ["--project-name", project]
        if let workingDirectory { arguments += ["--project-directory", workingDirectory.path] }
        for file in files { arguments += ["--file", file.path] }
        return arguments + command
    }

    /// Runs compose to completion (output bounded to `limit` bytes per stream, newest kept), or kills it after
    /// `timeout`. Off the main actor.
    @concurrent
    public func run(project: String, files: [URL], workingDirectory: URL?, command: [String], timeout: Duration = .seconds(300),
                    limit: Int = 512 * 1024) async throws -> Result {
        let state = signposter.beginInterval("compose")
        defer { signposter.endInterval("compose", state) }
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = configDirectory.appending(path: "config.json")
        if !FileManager.default.fileExists(atPath: config.path) { try Data("{}\n".utf8).write(to: config) }
        try Self.linkBuildx(beside: executable, into: configDirectory)
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(project: project, files: files, workingDirectory: workingDirectory, command: command)
        process.environment = environment()
        process.currentDirectoryURL = workingDirectory ?? configDirectory
        // Drained, bounded, TERM→KILL on timeout or cancellation, no blocking reads (N18).
        let result: ChildProcess.Result
        do {
            result = try await ChildProcess.run(process, ChildProcess.Options(timeout: timeout, outputLimit: limit))
        } catch is ChildProcess.LaunchFailed {
            return Result(status: -1, stdout: Data(), stderr: Data())
        }
        if result.timedOut { throw ContainerError.timedOut(operation: "docker compose \(command.first ?? "")") }
        return Result(status: result.status, stdout: result.stdout, stderr: result.stderr)
    }
}

/// The normalised model of a compose file (`docker compose config --format json`), as far as BelloCode needs it.
public struct ComposeModel: Sendable, Equatable {
    public struct Service: Sendable, Equatable {
        public var name: String
        public var image: String?
        public var hasBuild: Bool
        /// `container_name`, when the file sets one.
        public var containerName: String?
        public var publishesPorts: Bool
        public var environmentNames: Set<String>
        /// Features that reach past the container (privileged, capabilities, devices, host namespaces, bind mounts).
        public var elevated: [String]
        /// Never allowed: the container engine's socket.
        public var forbidden: [String]

        public init(name: String, image: String? = nil, hasBuild: Bool = false, containerName: String? = nil, publishesPorts: Bool = false,
                    environmentNames: Set<String> = [], elevated: [String] = [], forbidden: [String] = []) {
            self.name = name
            self.image = image
            self.hasBuild = hasBuild
            self.containerName = containerName
            self.publishesPorts = publishesPorts
            self.environmentNames = environmentNames
            self.elevated = elevated
            self.forbidden = forbidden
        }
    }

    public var name: String
    public var services: [Service]

    public init(name: String, services: [Service]) {
        self.name = name
        self.services = services
    }

    /// Parses `config --format json`.
    public static func parse(_ data: Data) throws -> ComposeModel {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ContainerError.http(status: 500, message: "docker compose config printed no model")
        }
        let services = (root["services"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }.map { name, value -> Service in
            let service = value as? [String: Any] ?? [:]
            var elevated: [String] = []
            var forbidden: [String] = []
            if service["privileged"] as? Bool == true { elevated.append("privileged") }
            for key in ["cap_add", "devices", "security_opt", "sysctls"] where !((service[key] as? [Any]) ?? []).isEmpty || service[key] is [String: Any] {
                elevated.append(key)
            }
            for key in ["network_mode", "pid", "ipc", "userns_mode", "cgroup_parent", "runtime"] {
                if let mode = service[key] as? String, !mode.isEmpty { elevated.append("\(key): \(mode)") }
            }
            if !((service["volumes_from"] as? [Any]) ?? []).isEmpty { elevated.append("volumes_from") }
            for volume in service["volumes"] as? [[String: Any]] ?? [] where volume["type"] as? String == "bind" {
                let source = volume["source"] as? String ?? "?"
                if source.hasSuffix("docker.sock") { forbidden.append("mounts the container engine's socket (\(source))") } else {
                    elevated.append("bind mount \(source)\(volume["read_only"] as? Bool == true ? " (read-only)" : "")")
                }
            }
            let environment = service["environment"] as? [String: Any] ?? [:]
            return Service(
                name: name, image: service["image"] as? String, hasBuild: service["build"] != nil,
                containerName: service["container_name"] as? String, publishesPorts: !((service["ports"] as? [Any]) ?? []).isEmpty,
                environmentNames: Set(environment.keys), elevated: elevated, forbidden: forbidden)
        }
        return ComposeModel(name: root["name"] as? String ?? "", services: services)
    }

    /// The container compose creates for `service` (`container_name`, else `<project>-<service>-1`).
    public func containerName(_ service: String) -> String? {
        guard let entry = services.first(where: { $0.name == service }) else { return nil }
        return entry.containerName ?? "\(name)-\(service)-1"
    }

    public var elevated: [String] { services.flatMap { service in service.elevated.map { "\(service.name): \($0)" } } }
    public var forbidden: [String] { services.flatMap { service in service.forbidden.map { "\(service.name): \($0)" } } }

    /// BelloCode's override file: every service gets its label, the enterprise certificates (read-only) and their
    /// variables (a value the file sets wins), no published port (`!reset`: the endpoint is forwarded to loopback
    /// instead), and services that build get the proxy build arguments and the certificates as the named build
    /// context `bellocode-ca`.
    public func override(label: (key: String, value: String), corporate: CorporateNetwork?) -> String {
        var lines = ["# Written by BelloCode for this stack; replaced on every start.", "services:"]
        let env = corporate?.environment(noProxyExtra: services.map(\.name)) ?? [:]
        let build = corporate.map { ImageBuildNetwork($0).buildArgs(noProxyExtra: services.map(\.name)) } ?? [:]
        for service in services {
            lines.append("  \(Self.quote(service.name)):")
            lines.append("    labels:")
            lines.append("      \(Self.quote(label.key)): \(Self.quote(label.value))")
            if service.publishesPorts { lines.append("    ports: !reset []") }
            let added = env.filter { !service.environmentNames.contains($0.key) }.sorted { $0.key < $1.key }
            if !added.isEmpty {
                lines.append("    environment:")
                for (name, value) in added { lines.append("      \(Self.quote(name)): \(Self.quote(value))") }
            }
            if let directory = corporate?.certificateDirectory {
                lines.append("    volumes:")
                lines.append("      - type: bind")
                lines.append("        source: \(Self.quote(directory))")
                lines.append("        target: \(Self.quote(CorporateNetwork.containerDirectory))")
                lines.append("        read_only: true")
            }
            if service.hasBuild, !build.isEmpty || corporate?.certificateDirectory != nil {
                lines.append("    build:")
                if !build.isEmpty {
                    lines.append("      args:")
                    for (name, value) in build.sorted(by: { $0.key < $1.key }) { lines.append("        \(Self.quote(name)): \(Self.quote(value))") }
                }
                if let directory = corporate?.certificateDirectory {
                    lines.append("      additional_contexts:")
                    lines.append("        \(ImageBuildNetwork.contextName): \(Self.quote(directory))")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A YAML double-quoted scalar.
    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// One line of `docker compose ps --format json` (one object per line, or an array on older versions).
public struct ComposeServiceStatus: Sendable, Equatable {
    public var service: String
    public var state: String
    public var health: String?
    public var exitCode: Int?

    public static func parse(_ text: String) -> [ComposeServiceStatus] {
        var objects: [[String: Any]] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), let array = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [[String: Any]] {
            objects = array
        } else {
            objects = trimmed.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        return objects.compactMap { object in
            guard let service = object["Service"] as? String else { return nil }
            let health = (object["Health"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ComposeServiceStatus(service: service, state: object["State"] as? String ?? "unknown", health: health,
                                        exitCode: object["ExitCode"] as? Int)
        }
    }
}
