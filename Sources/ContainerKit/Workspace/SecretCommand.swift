import Foundation

/// How a command that receives a secret runs (C3 in docs/reviews/M3-M6-review.md): in a throwaway sibling of the
/// project's workspace container, never in the shared one, so nothing else in the project (a dev server, a stray
/// process of the agent's) can read its environment, and nothing it writes outlives it unless the user allowed writing
/// the project.
public struct SecretCommandPolicy: Sendable, Hashable, Codable {
    /// Outbound network. Off by default: the command cannot send the value anywhere.
    public var network: Bool
    /// The project (and its worktree folders) mounted read-write. Off by default: read-only, so the value cannot be
    /// written into the bind-mounted project where the agent could read it later.
    public var writesProject: Bool
    /// The project's optional host mounts this command receives, each with the access it was approved with. Empty by
    /// default: a secret command never gets an optional mount the approval did not list (S5 in
    /// docs/reviews/deep-review-1.md).
    public var mounts: [UserMount]

    public init(network: Bool = false, writesProject: Bool = false, mounts: [UserMount] = []) {
        self.network = network
        self.writesProject = writesProject
        self.mounts = mounts
    }

    enum CodingKeys: String, CodingKey { case network, writesProject, mounts }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        network = try c.decode(Bool.self, forKey: .network)
        writesProject = try c.decode(Bool.self, forKey: .writesProject)
        mounts = try c.decodeIfPresent([UserMount].self, forKey: .mounts) ?? []
    }

    /// The mounts in a canonical order and spelling (what an approval binds).
    public var canonicalMounts: [String] {
        mounts.map { "\(($0.path as NSString).standardizingPath):\($0.readOnly ? "ro" : "rw")" }.sorted()
    }
}

extension WorkspaceSpec {
    /// The label every secret-command container carries (cleanup finds leftovers by it).
    public static let labelSecretCommand = "app.bellocode.secret-command"

    /// The create body of a one-shot container for a secret command: the workspace's image, user, limits and hardening;
    /// the workspace folders read-only unless `policy.writesProject`; only the optional mounts `policy.mounts` lists,
    /// with the access listed there (never the project's other user mounts); no caches and no persistent home (HOME is
    /// a fresh /tmp); network `none` unless `policy.network`.
    public func secretCommandBody(imageID: String?, policy: SecretCommandPolicy) -> ContainerCreate {
        var body = createBody(imageID: imageID)
        body.env = ["HOME=/tmp", "BELLOCODE_WORKSPACE=1"] + environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        body.labels = [Self.labelSecretCommand: "1"].merging(extraLabels) { a, _ in a }
        guard var host = body.hostConfig else { return body }
        host.networkMode = policy.network ? Network.bridge.rawValue : Network.none.rawValue
        // Nothing BelloCode runs as root here: no capabilities at all.
        host.capAdd = nil
        var mounts = workspaceRoots.map { Mount(type: .bind, source: $0, target: $0, readOnly: !policy.writesProject, createMountpoint: false) }
        mounts += policy.mounts.map { Mount(type: .bind, source: $0.path, target: $0.path, readOnly: $0.readOnly, createMountpoint: false) }
        host.mounts = mounts
        host.portBindings = nil
        body.exposedPorts = nil
        body.hostConfig = host
        return body
    }
}

extension WorkspaceManager {
    /// The result of a secret command. Output is bounded: `truncated` says whether bytes were dropped.
    public struct SecretCommandResult: Sendable {
        public var exitCode: Int
        public var output: BoundedOutput
        public init(exitCode: Int, output: BoundedOutput) {
            self.exitCode = exitCode
            self.output = output
        }
    }

    /// Runs `shell -c command` in a one-shot container (see `secretCommandBody`) with `secret` in the environment
    /// variable `name`. The value travels on the exec's stdin (read by a one-line wrapper into the variable), so it is
    /// never in a container or exec configuration the Engine API can show; the container is removed afterwards (also
    /// on cancellation, timeout or error). Never pulls.
    public func runSecretCommand(
        _ spec: WorkspaceSpec, shell: String, command: String, workingDir: String, name: String, secret: Data, policy: SecretCommandPolicy,
        limit: Int = 256 << 10, timeout: Duration = .seconds(300)
    ) async throws -> SecretCommandResult {
        guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }), !name.isEmpty else {
            throw WorkspaceError.engine(.http(status: 400, message: "invalid variable name"))
        }
        guard let image = try await client.inspectImage(spec.image) else { throw WorkspaceError.imageMissing(spec.image) }
        let body = spec.secretCommandBody(imageID: image.id, policy: policy)
        let containerName = "bellocode-secret-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let id = try await client.createContainer(name: containerName, body)
        do {
            try await client.startContainer(id)
            // `NAME=$(cat)` reads the whole value until end of input (trailing newlines are dropped, as in any command
            // substitution), then the command runs with stdin from /dev/null.
            let wrapper = "\(name)=$(cat); export \(name); exec \"$@\" </dev/null"
            let session = try await ExecSession.start(
                client: client, container: id, argv: ["/bin/sh", "-c", wrapper, "bellocode-secret", shell, "-c", command], workingDir: workingDir,
                environment: [:], user: spec.user, tty: false)
            defer { session.close() }
            try await session.write(secret)
            session.closeStdin()
            let output = try await withDeadline(timeout, operation: "secret command") {
                var output = BoundedOutput(limit: limit)
                for try await chunk in session.output() {
                    switch chunk.stream {
                    case .stderr, .system: output.append(chunk.bytes, toStderr: true)
                    default: output.append(chunk.bytes, toStderr: false)
                    }
                }
                return output
            }
            let code = try await session.exitCode()
            try? await client.removeContainer(id, force: true)
            return SecretCommandResult(exitCode: code, output: output)
        } catch {
            try? await client.removeContainer(id, force: true)
            throw error
        }
    }

    /// Removes secret-command containers left behind by a crash.
    public func removeLeftoverSecretContainers() async {
        guard let all = try? await client.listContainers(labels: ["\(WorkspaceSpec.labelSecretCommand)=1"], all: true) else { return }
        for container in all { try? await client.removeContainer(container.id, force: true) }
    }
}

/// Output kept within a byte budget per stream: the head and the tail are kept, the middle is dropped and counted, so
/// an early failure and the final result both survive (M6 in docs/reviews/M3-M6-review.md).
public struct BoundedOutput: Sendable, Hashable {
    public struct Stream: Sendable, Hashable {
        public var head = Data()
        public var tail = Data()
        /// Bytes dropped between head and tail.
        public var dropped = 0
        public var total = 0

        mutating func append(_ data: Data, limit: Int) {
            total += data.count
            let half = max(1, limit / 2)
            var rest = data
            if head.count < half {
                let take = min(half - head.count, rest.count)
                head.append(rest.prefix(take))
                rest = rest.dropFirst(take)
            }
            guard !rest.isEmpty else { return }
            tail.append(rest)
            if tail.count > half {
                let excess = tail.count - half
                dropped += excess
                tail = Data(tail.suffix(half))
            }
        }

        public var isTruncated: Bool { dropped > 0 }

        /// Head, a visible marker naming how much was dropped, tail.
        public var text: String {
            let head = String(decoding: head, as: UTF8.self)
            let tail = String(decoding: tail, as: UTF8.self)
            guard dropped > 0 else { return head + tail }
            return head + "\n[… \(dropped) bytes of output omitted …]\n" + tail
        }

        public var data: Data { head + tail }
    }

    public let limit: Int
    public var stdout = Stream()
    public var stderr = Stream()

    public init(limit: Int) { self.limit = limit }

    public mutating func append(_ data: Data, toStderr: Bool) {
        if toStderr { stderr.append(data, limit: limit) } else { stdout.append(data, limit: limit) }
    }

    public var isTruncated: Bool { stdout.isTruncated || stderr.isTruncated }
    public var droppedBytes: Int { stdout.dropped + stderr.dropped }
}
