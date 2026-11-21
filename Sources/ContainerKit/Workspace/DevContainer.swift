import CryptoKit
import Foundation

/// A project's `.devcontainer/devcontainer.json` (or `.devcontainer.json`) read as the source of its project container
/// (docs/features/containers.md, "Dev containers"). Only a safe subset is supported (research 09 §1): `image`, `build`
/// (`dockerfile`, `context`, `args`, `target`) built with Rancher Desktop's `docker buildx`, a same-path workspace,
/// `containerEnv`, `remoteEnv`, `remoteUser`, `forwardPorts` (numbers) and `postCreateCommand` / `postStartCommand`
/// after one review. Anything that runs on the Mac, adds privileges or needs Features is refused with the reason;
/// editor customisations are listed as ignored. Nothing is ever silently dropped.
public struct DevContainerPlan: Sendable, Equatable {
    public struct Build: Sendable, Equatable {
        /// Absolute paths on the Mac.
        public var dockerfile: String
        public var context: String
        public var args: [String: String]
        public var target: String?
    }

    public struct Refusal: Sendable, Equatable, Hashable {
        public var key: String
        public var reason: String
    }

    /// The configuration file (absolute).
    public var file: String
    public var image: String?
    public var build: Build?
    public var containerEnv: [String: String] = [:]
    public var remoteEnv: [String: String] = [:]
    public var remoteUser: String?
    public var forwardPorts: [Int] = []
    /// Shell command lines (an array form is joined with quoting).
    public var postCreate: String?
    public var postStart: String?
    /// Keys that block using the file (the project keeps its own image setting meanwhile).
    public var refused: [Refusal] = []
    /// Keys that have no effect here (editor customisations, host requirements…).
    public var ignored: [String] = []

    public var isUsable: Bool { refused.isEmpty && (image != nil || build != nil) }

    /// What the person reviews before lifecycle commands run: changes to it need a new review.
    public var lifecycleDigest: String? {
        guard postCreate != nil || postStart != nil else { return nil }
        let text = "create:\(postCreate ?? "")\nstart:\(postStart ?? "")"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// `docker buildx build` arguments (argv after the docker binary). No secrets, no shell. The Dockerfile comes on
    /// standard input (`-f -`, the bytes `DevContainerBuildInputs` verified) and `context` is the verified canonical
    /// folder, so the CLI never opens a project path BelloCode did not just check (R16).
    ///
    /// `offline` (enforced egress, N09): `RUN` steps get no network. BuildKit's builder in the daemon cannot join
    /// BelloCode's egress network (it accepts only `default`, `host` and `none`), and its default network would bypass
    /// the proxy, so the build fails closed rather than reaching the internet directly.
    public func buildArguments(tag: String, context: String, offline: Bool = false) -> [String]? {
        guard let build else { return nil }
        var argv = ["buildx", "build", "--load", "--progress", "plain", "-t", tag, "-f", "-",
                    "--label", "\(WorkspaceSpec.labelWorkspace)=1", "--label", "app.bellocode.devcontainer=1"]
        if offline { argv += ["--network", "none"] }
        for (key, value) in build.args.sorted(by: { $0.key < $1.key }) { argv += ["--build-arg", "\(key)=\(value)"] }
        if let target = build.target { argv += ["--target", target] }
        argv.append(context)
        return argv
    }

    // MARK: Reading

    /// The configuration file of a project, if it has one.
    public static func find(projectRoot: String) -> String? {
        for candidate in [".devcontainer/devcontainer.json", ".devcontainer.json"] {
            let path = (projectRoot as NSString).appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    public static func load(projectRoot: String) -> DevContainerPlan? {
        guard let file = find(projectRoot: projectRoot), let data = FileManager.default.contents(atPath: file) else { return nil }
        return parse(data, file: file, projectRoot: projectRoot)
    }

    /// Supported keys and what each refusal means.
    static let refusedKeys: [String: String] = [
        "initializeCommand": "runs on this Mac before the container exists; BelloCode never runs project commands on the Mac",
        "features": "Dev Container Features run installers as root during the build and are not supported yet; install the tools in the Dockerfile instead",
        "privileged": "privileged containers are not allowed",
        "capAdd": "added capabilities are not allowed",
        "securityOpt": "security options are not allowed",
        "runArgs": "arbitrary docker run arguments are not allowed",
        "mounts": "extra mounts are not supported; the project and its worktrees are mounted at the same paths",
        "workspaceMount": "the project is always mounted at its own path",
        "dockerComposeFile": "Compose-based dev containers are not supported; use image or build",
        "onCreateCommand": "only postCreateCommand and postStartCommand are supported",
        "updateContentCommand": "only postCreateCommand and postStartCommand are supported",
        "postAttachCommand": "only postCreateCommand and postStartCommand are supported",
        "updateRemoteUserUID": "changing the user's UID is not supported",
        "containerUser": "the container runs as remoteUser or your Mac user",
        "appPort": "publishing ports is not supported; use forwardPorts",
        "overrideCommand": "the container's command is always BelloCode's",
        "shutdownAction": "the container stops when idle, as other project containers do",
        "userEnvProbe": "not supported",
        "waitFor": "not supported",
        "portsAttributes": "port attributes are not supported; ports are forwarded to 127.0.0.1 on demand",
        "otherPortsAttributes": "port attributes are not supported",
        "init": "BelloCode's containers always use an init process",
    ]
    static let ignoredKeys: Set<String> = ["name", "customizations", "hostRequirements", "$schema", "extensions", "settings"]

    public static func parse(_ data: Data, file: String, projectRoot: String) -> DevContainerPlan {
        var plan = DevContainerPlan(file: file)
        guard let json = (try? JSONSerialization.jsonObject(with: stripJSONC(data))) as? [String: Any] else {
            plan.refused.append(Refusal(key: "(file)", reason: "the file is not valid JSON (with comments)"))
            return plan
        }
        let directory = (file as NSString).deletingLastPathComponent
        func resolve(_ value: String) -> String {
            let substituted = value.replacingOccurrences(of: "${localWorkspaceFolder}", with: projectRoot)
                .replacingOccurrences(of: "${containerWorkspaceFolder}", with: projectRoot)
            // Lexical only (`standardizingPath` would also drop a leading /private); containment is checked on the
            // canonical paths below.
            return CodeRootPaths.lexicallyNormalized(substituted.hasPrefix("/") ? substituted : (directory as NSString).appendingPathComponent(substituted))
        }
        for key in json.keys.sorted() {
            let value = json[key]
            if let reason = refusedKeys[key] {
                // An empty or false value asks for nothing.
                let empty = (value as? [Any])?.isEmpty == true || (value as? [String: Any])?.isEmpty == true || (value as? Bool) == false
                    || (value as? String)?.isEmpty == true || value is NSNull
                if !empty { plan.refused.append(Refusal(key: key, reason: reason)) }
                continue
            }
            if ignoredKeys.contains(key) {
                plan.ignored.append(key)
                continue
            }
            switch key {
            case "image":
                plan.image = value as? String
            case "build", "dockerFile", "context":
                break
            case "workspaceFolder":
                let folder = (value as? String).map(resolve)
                if folder != projectRoot { plan.refused.append(Refusal(key: key, reason: "the project is always at its own path (\(projectRoot)) in the container")) }
            case "containerEnv", "remoteEnv":
                var values: [String: String] = [:]
                for (name, raw) in (value as? [String: Any]) ?? [:] {
                    guard let text = raw as? String, !text.contains("${localEnv") else {
                        plan.refused.append(Refusal(key: "\(key).\(name)", reason: "values must be plain text (no ${localEnv:…}, which would read the Mac's environment)"))
                        continue
                    }
                    if name.hasPrefix("BUN_") || name.hasPrefix("BELLOCODE_") || ["HOME", "PATH"].contains(name) {
                        plan.refused.append(Refusal(key: "\(key).\(name)", reason: "\(name) cannot be set"))
                        continue
                    }
                    values[name] = text
                }
                if key == "containerEnv" { plan.containerEnv = values } else { plan.remoteEnv = values }
            case "remoteUser":
                // N09: the container's capabilities exist for BelloCode's own root step only; commands never run as root.
                if let user = value as? String, Self.isRoot(user) {
                    plan.refused.append(Refusal(key: key, reason: "commands never run as root in BelloCode's containers; use the image's non-root user, or leave remoteUser out to use your Mac user"))
                } else {
                    plan.remoteUser = value as? String
                }
            case "forwardPorts":
                for entry in (value as? [Any]) ?? [] {
                    if let port = (entry as? NSNumber)?.intValue, (1...65535).contains(port) {
                        plan.forwardPorts.append(port)
                    } else {
                        plan.refused.append(Refusal(key: "forwardPorts", reason: "“\(entry)”: only port numbers of the container are supported"))
                    }
                }
            case "postCreateCommand", "postStartCommand":
                switch lifecycle(value) {
                case .success(let line): if key == "postCreateCommand" { plan.postCreate = line } else { plan.postStart = line }
                case .failure(let refusal): plan.refused.append(Refusal(key: key, reason: refusal.reason))
                }
            default:
                plan.refused.append(Refusal(key: key, reason: "not supported by BelloCode"))
            }
        }
        // build (and the legacy top-level dockerFile/context).
        let build = (json["build"] as? [String: Any]) ?? [:]
        if let dockerfile = (build["dockerfile"] as? String) ?? (json["dockerFile"] as? String) {
            let context = resolve((build["context"] as? String) ?? (json["context"] as? String) ?? ".")
            let file = resolve(dockerfile)
            var args: [String: String] = [:]
            for (name, raw) in (build["args"] as? [String: Any]) ?? [:] {
                if let text = raw as? String, !text.contains("${localEnv") { args[name] = text } else {
                    plan.refused.append(Refusal(key: "build.args.\(name)", reason: "build arguments must be plain text"))
                }
            }
            for extra in build.keys.sorted() where !["dockerfile", "context", "args", "target"].contains(extra) {
                plan.refused.append(Refusal(key: "build.\(extra)", reason: "not supported (cache, options and secrets are BelloCode's to set)"))
            }
            // Links resolved on both sides (R16): a linked folder or Dockerfile under the project that points elsewhere
            // is outside it. Checked again, on the objects themselves, right before each build (DevContainerBuildInputs).
            if let refusal = DevContainerBuildInputs.containmentProblem(context: context, dockerfile: file, projectRoot: projectRoot) {
                plan.refused.append(Refusal(key: "build.context", reason: refusal))
            }
            plan.build = Build(dockerfile: file, context: context, args: args, target: build["target"] as? String)
        } else if !build.isEmpty {
            plan.refused.append(Refusal(key: "build", reason: "build needs a dockerfile"))
        }
        if plan.image != nil && plan.build != nil { plan.image = nil }
        if plan.image == nil && plan.build == nil && !plan.refused.contains(where: { $0.key == "dockerComposeFile" }) {
            plan.refused.append(Refusal(key: "image", reason: "the file names neither an image nor a build"))
        }
        plan.refused.sort { $0.key < $1.key }
        plan.ignored.sort()
        return plan
    }

    /// `root`, `0`, or either with a group (`0:0`, `root:wheel`).
    public static func isRoot(_ user: String) -> Bool {
        let name = user.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return name == "root" || (!name.isEmpty && name.allSatisfy(\.isNumber) && Int(name) == 0)
    }

    struct LifecycleRefusal: Error { var reason: String }

    /// A string runs as one shell line; an array is joined with quoting; the parallel object form is refused.
    static func lifecycle(_ value: Any?) -> Result<String, LifecycleRefusal> {
        if let line = value as? String { return .success(line) }
        if let words = value as? [String] {
            return .success(words.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " "))
        }
        return .failure(LifecycleRefusal(reason: "the parallel (object) form is not supported; use one command line"))
    }

    /// Removes `//` and `/* */` comments and trailing commas outside strings (JSON with comments, as the spec allows).
    public static func stripJSONC(_ data: Data) -> Data {
        let input = Array(String(decoding: data, as: UTF8.self).unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        var inString = false
        while index < input.count {
            let character = input[index]
            if inString {
                output.append(character)
                if character == "\\", index + 1 < input.count { output.append(input[index + 1]); index += 2; continue }
                if character == "\"" { inString = false }
                index += 1
                continue
            }
            if character == "\"" { inString = true; output.append(character); index += 1; continue }
            if character == "/", index + 1 < input.count, input[index + 1] == "/" {
                while index < input.count, input[index] != "\n" { index += 1 }
                continue
            }
            if character == "/", index + 1 < input.count, input[index + 1] == "*" {
                index += 2
                while index + 1 < input.count, !(input[index] == "*" && input[index + 1] == "/") { index += 1 }
                index += 2
                continue
            }
            if character == "," {
                var look = index + 1
                while look < input.count, CharacterSet.whitespacesAndNewlines.contains(input[look]) { look += 1 }
                if look < input.count, input[look] == "}" || input[look] == "]" { index += 1; continue }
            }
            output.append(character)
            index += 1
        }
        return Data(String(output).utf8)
    }
}

/// The verified inputs of one dev-container build, taken right before the CLI runs (R16): the canonical context folder
/// and the Dockerfile's bytes, read through a descriptor opened without following a final link, both proven inside the
/// canonical project folder. The CLI then gets the canonical context path and the Dockerfile on standard input.
public struct DevContainerBuildInputs: Sendable, Equatable {
    public var context: String
    public var dockerfile: Data

    public struct Problem: Error, Sendable, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    public static let dockerfileLimit = 1 << 20

    /// Why the context or Dockerfile is not inside the project once links are resolved, or nil.
    public static func containmentProblem(context: String, dockerfile: String, projectRoot: String) -> String? {
        guard let root = CodeRootPaths.canonical(projectRoot) else { return "the project folder does not exist" }
        guard let canonicalContext = CodeRootPaths.canonical(context) else { return "the build context \(context) does not exist" }
        guard let canonicalFile = CodeRootPaths.canonical(dockerfile) else { return "the Dockerfile \(dockerfile) does not exist" }
        guard CodeRootPaths.inside(canonicalContext, root), CodeRootPaths.inside(canonicalFile, root) else {
            return "the build context and Dockerfile must be inside the project (links are followed: \(canonicalContext), \(canonicalFile))"
        }
        return nil
    }

    public static func verify(_ build: DevContainerPlan.Build, projectRoot: String) -> Result<DevContainerBuildInputs, Problem> {
        if let problem = containmentProblem(context: build.context, dockerfile: build.dockerfile, projectRoot: projectRoot) {
            return .failure(Problem("The dev container was not built: \(problem)."))
        }
        guard let context = CodeRootPaths.canonical(build.context), let file = CodeRootPaths.canonical(build.dockerfile) else {
            return .failure(Problem("The dev container was not built: its build context or Dockerfile disappeared."))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: context, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(Problem("The dev container was not built: its build context \(context) is not a folder."))
        }
        // The canonical path has no links; O_NOFOLLOW refuses one swapped in since, and fstat proves a regular file.
        let fd = open(file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .failure(Problem("The dev container was not built: its Dockerfile could not be opened (\(String(cString: strerror(errno))))."))}
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return .failure(Problem("The dev container was not built: its Dockerfile is not a regular file."))
        }
        guard Int(info.st_size) <= dockerfileLimit else { return .failure(Problem("The dev container was not built: its Dockerfile is larger than 1 MiB.")) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = (try? handle.read(upToCount: dockerfileLimit + 1)) ?? Data()
        guard data.count <= dockerfileLimit else { return .failure(Problem("The dev container was not built: its Dockerfile is larger than 1 MiB.")) }
        // Still inside after opening (a parent folder swapped for a link between the checks and the open).
        if let problem = containmentProblem(context: context, dockerfile: file, projectRoot: projectRoot) {
            return .failure(Problem("The dev container was not built: \(problem)."))
        }
        return .success(DevContainerBuildInputs(context: context, dockerfile: data))
    }
}
