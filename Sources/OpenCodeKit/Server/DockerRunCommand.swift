import Foundation

/// A `docker run` (or `podman run`, `nerdctl run`) command line, as MCP clients configure stdio servers that come from
/// an image (`["docker", "run", "-i", "--rm", "-e", "TOKEN", "ghcr.io/acme/mcp:1", "--stdio"]`). BelloCode never runs
/// that command (there is no container CLI on the Mac); it reads it to run the same image itself, in its own
/// container (docs/features/containers.md, "Global MCP servers"). Used by Import and by servers configured for all
/// projects in BelloCode's isolated opencode configuration.
public struct DockerRunCommand: Sendable, Equatable {
    public struct Mount: Sendable, Equatable, Hashable {
        public var source: String
        public var target: String
        public var readOnly: Bool
        public init(source: String, target: String, readOnly: Bool) {
            self.source = source
            self.target = target
            self.readOnly = readOnly
        }
    }

    public var image: String
    public var args: [String] = []
    public var entrypoint: [String]?
    /// `-e NAME=value`.
    public var environment: [String: String] = [:]
    /// `-e NAME` (the value comes from the client's environment for the server).
    public var passthrough: [String] = []
    /// `-v /host:/container[:ro]`: never applied without review.
    public var mounts: [Mount] = []
    /// `bridge` or `none` (nil: not given).
    public var network: String?
    /// Options dropped with a reason (`--name`, `-t`, `-p`, limits): shown in the import review.
    public var notes: [String] = []

    public init(image: String) { self.image = image }

    public struct Refusal: Error, Sendable, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    static let runtimes: Set<String> = ["docker", "podman", "nerdctl"]
    static let ignoredBooleans: Set<String> = ["-i", "--interactive", "--rm", "--init", "--read-only", "--sig-proxy"]
    static let refusedBooleans: [String: String] = [
        "--privileged": "--privileged (full access to the container engine's VM)",
        "-d": "-d (a detached server cannot speak over stdin/stdout)", "--detach": "--detach (a detached server cannot speak over stdin/stdout)",
    ]
    /// Options taking a value that are dropped with a note.
    static let ignoredWithValue: [String: String] = [
        "--name": "the container name (BelloCode names its own)", "--pull": "the pull policy (BelloCode's image policy applies)",
        "--platform": "the platform", "-l": "labels", "--label": "labels", "-p": "published ports (stdio needs none)",
        "--publish": "published ports (stdio needs none)", "-m": "the memory limit (BelloCode's limits apply)",
        "--memory": "the memory limit (BelloCode's limits apply)", "--cpus": "the CPU limit (BelloCode's limits apply)",
        "-u": "the user (the image's user runs)", "--user": "the user (the image's user runs)", "-w": "the working directory",
        "--workdir": "the working directory", "--hostname": "the host name", "-h": "the host name", "--restart": "the restart policy",
        "--log-driver": "the log driver", "--stop-timeout": "the stop timeout",
    ]
    /// Options that cannot be converted faithfully or safely.
    static let refusedWithValue: [String: String] = [
        "--env-file": "--env-file (it reads a file on this Mac; copy the variables in instead)",
        "--mount": "--mount (add the folder in the editor after import)", "--cap-add": "--cap-add (extra capabilities)",
        "--device": "--device (host devices)", "--security-opt": "--security-opt", "--pid": "--pid", "--ipc": "--ipc",
        "--userns": "--userns", "--volumes-from": "--volumes-from", "--add-host": "--add-host", "--cgroup-parent": "--cgroup-parent",
        "--runtime": "--runtime", "--sysctl": "--sysctl", "--gpus": "--gpus",
    ]

    /// True when `argv` starts with a container CLI's `run` (`docker run`, `docker container run`).
    public static func isDockerRun(_ argv: [String]) -> Bool { runIndex(argv) != nil }

    static func runIndex(_ argv: [String]) -> Int? {
        guard let first = argv.first, runtimes.contains((first as NSString).lastPathComponent) else { return nil }
        if argv.count > 1, argv[1] == "run" { return 2 }
        if argv.count > 2, argv[1] == "container", argv[2] == "run" { return 3 }
        return nil
    }

    /// Parses `argv` (`docker run [options] IMAGE [args…]`).
    public static func parse(_ argv: [String]) throws(Refusal) -> DockerRunCommand {
        guard let start = runIndex(argv) else { throw Refusal("not a docker run command") }
        var index = start
        var pending = DockerRunCommand(image: "")
        func value(_ option: String, _ inline: String?) throws(Refusal) -> String {
            if let inline { return inline }
            index += 1
            guard index < argv.count else { throw Refusal("\(option) has no value") }
            return argv[index]
        }
        while index < argv.count {
            let word = argv[index]
            guard word.hasPrefix("-"), word != "-" else { break }
            if word == "--" {
                index += 1
                break
            }
            var option = word
            var inline: String?
            if word.hasPrefix("--"), let equals = word.firstIndex(of: "=") {
                option = String(word[..<equals])
                inline = String(word[word.index(after: equals)...])
            } else if !word.hasPrefix("--"), word.count > 2, ["-e", "-v", "-p", "-l", "-u", "-w", "-m", "-h"].contains(String(word.prefix(2))) {
                // `-eNAME=value`, `-v/a:/b`
                option = String(word.prefix(2))
                inline = String(word.dropFirst(2)).drop(while: { $0 == "=" }).description
            }
            if !option.hasPrefix("--"), option.count > 2, option.dropFirst().allSatisfy({ "itd".contains($0) }) {
                // Combined short booleans: -it, -ti, -itd.
                for letter in option.dropFirst() {
                    try pending.applyBoolean("-\(letter)")
                }
                index += 1
                continue
            }
            switch option {
            case "-e", "--env":
                let entry = try value(option, inline)
                if let equals = entry.firstIndex(of: "=") {
                    pending.environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
                } else if !entry.isEmpty {
                    pending.passthrough.append(entry)
                }
            case "-v", "--volume":
                pending.mounts.append(try Self.mount(try value(option, inline)))
            case "--network", "--net":
                let network = try value(option, inline)
                switch network {
                case "bridge", "default": pending.network = "bridge"
                case "none": pending.network = "none"
                case "host": throw Refusal("--network host (the server would share the VM's network stack)")
                default: throw Refusal("--network \(network) (another network; use a compose stack for servers that need one)")
                }
            case "--entrypoint":
                pending.entrypoint = [try value(option, inline)]
            default:
                if let note = ignoredWithValue[option] {
                    _ = try value(option, inline)
                    pending.notes.append("Dropped \(option): \(note).")
                } else if let refusal = refusedWithValue[option] {
                    throw Refusal(refusal)
                } else {
                    try pending.applyBoolean(option)
                }
            }
            index += 1
        }
        guard index < argv.count, !argv[index].isEmpty else { throw Refusal("no image named after the options") }
        pending.image = argv[index]
        pending.args = Array(argv[(index + 1)...])
        return pending
    }

    mutating func applyBoolean(_ option: String) throws(Refusal) {
        if Self.ignoredBooleans.contains(option) { return }
        if option == "-t" || option == "--tty" {
            notes.append("Dropped \(option): a stdio server needs no terminal (it would alter the bytes).")
            return
        }
        if let refusal = Self.refusedBooleans[option] { throw Refusal(refusal) }
        throw Refusal("unknown option \(option)")
    }

    static func mount(_ text: String) throws(Refusal) -> Mount {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw Refusal("-v \(text) is not host:container") }
        guard parts[0].hasPrefix("/") || parts[0].hasPrefix("~") || parts[0].hasPrefix("$") else {
            throw Refusal("-v \(text) uses a named volume (only folders on this Mac can be mounted, after review)")
        }
        if parts[0].hasSuffix("docker.sock") || parts[0].hasSuffix("/.rd/docker.sock") {
            throw Refusal("-v \(parts[0]) (the container engine's socket would give the server control of every container)")
        }
        let options = parts.count > 2 ? parts[2].split(separator: ",").map(String.init) : []
        return Mount(source: parts[0], target: parts[1], readOnly: options.contains("ro") || options.contains("readonly"))
    }
}
