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

    /// The tag BelloCode builds the image as (changes when the Dockerfile, context or arguments change).
    public func buildTag(projectKey: String) -> String? {
        guard let build else { return nil }
        let dockerfile = (try? Data(contentsOf: URL(filePath: build.dockerfile))) ?? Data()
        var hasher = SHA256()
        hasher.update(data: dockerfile)
        hasher.update(data: Data("\(build.context)\n\(build.args.sorted { $0.key < $1.key })\n\(build.target ?? "")".utf8))
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12)
        return "bellocode-dev-\(projectKey):\(digest)"
    }

    /// `docker buildx build` arguments (argv after the docker binary). No secrets, no shell.
    public func buildArguments(tag: String) -> [String]? {
        guard let build else { return nil }
        var argv = ["buildx", "build", "--load", "--progress", "plain", "-t", tag, "-f", build.dockerfile,
                    "--label", "\(WorkspaceSpec.labelWorkspace)=1", "--label", "app.bellocode.devcontainer=1"]
        for (key, value) in build.args.sorted(by: { $0.key < $1.key }) { argv += ["--build-arg", "\(key)=\(value)"] }
        if let target = build.target { argv += ["--target", target] }
        argv.append(build.context)
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
            return substituted.hasPrefix("/") ? (substituted as NSString).standardizingPath
                : ((directory as NSString).appendingPathComponent(substituted) as NSString).standardizingPath
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
                plan.remoteUser = value as? String
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
            if !CodeRootPaths.inside(context, projectRoot) || !CodeRootPaths.inside(file, projectRoot) {
                plan.refused.append(Refusal(key: "build.context", reason: "the build context and Dockerfile must be inside the project"))
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
