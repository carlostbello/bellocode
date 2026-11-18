import Foundation

/// One supporting service of a project (database, cache, queue), from the project's compose file or the Environment
/// pane. Only the subset BelloCode can run safely: see `ComposeParser`.
public struct ServiceDefinition: Sendable, Equatable, Codable, Hashable {
    public struct Port: Sendable, Equatable, Codable, Hashable {
        public var containerPort: Int
        public var proto: String
        public init(containerPort: Int, proto: String = "tcp") {
            self.containerPort = containerPort
            self.proto = proto
        }
    }

    public struct VolumeMount: Sendable, Equatable, Codable, Hashable {
        /// The named volume (compose name; the Docker volume is `bellocode-<project key>-svc-<name>`).
        public var name: String
        public var target: String
        public var readOnly: Bool
        public init(name: String, target: String, readOnly: Bool = false) {
            self.name = name
            self.target = target
            self.readOnly = readOnly
        }
    }

    public enum Condition: String, Sendable, Codable, Hashable {
        case started = "service_started"
        case healthy = "service_healthy"
        case completed = "service_completed_successfully"
    }

    public struct Dependency: Sendable, Equatable, Codable, Hashable {
        public var service: String
        public var condition: Condition
        public init(service: String, condition: Condition = .started) {
            self.service = service
            self.condition = condition
        }
    }

    public struct Healthcheck: Sendable, Equatable, Codable, Hashable {
        /// Docker form: `["CMD", …]`, `["CMD-SHELL", "…"]` or `["NONE"]`.
        public var test: [String]
        public var intervalSeconds: Double?
        public var timeoutSeconds: Double?
        public var startPeriodSeconds: Double?
        public var retries: Int?
        public init(test: [String], intervalSeconds: Double? = nil, timeoutSeconds: Double? = nil, startPeriodSeconds: Double? = nil, retries: Int? = nil) {
            self.test = test
            self.intervalSeconds = intervalSeconds
            self.timeoutSeconds = timeoutSeconds
            self.startPeriodSeconds = startPeriodSeconds
            self.retries = retries
        }

        /// How long a dependant waits for `healthy` at most: the start period plus every retry, plus a margin; never
        /// more than five minutes.
        public var gateTimeoutSeconds: Double {
            let interval = intervalSeconds ?? 30, timeout = timeoutSeconds ?? 30
            let total = (startPeriodSeconds ?? 0) + Double((retries ?? 3) + 1) * (interval + timeout) + 30
            return min(max(total, 30), 300)
        }
    }

    public var name: String
    public var image: String
    public var environment: [String: String]
    public var ports: [Port]
    public var volumes: [VolumeMount]
    public var dependsOn: [Dependency]
    public var healthcheck: Healthcheck?
    /// nil keeps the image's command.
    public var command: [String]?

    public init(name: String, image: String, environment: [String: String] = [:], ports: [Port] = [], volumes: [VolumeMount] = [],
                dependsOn: [Dependency] = [], healthcheck: Healthcheck? = nil, command: [String]? = nil) {
        self.name = name
        self.image = image
        self.environment = environment
        self.ports = ports
        self.volumes = volumes
        self.dependsOn = dependsOn
        self.healthcheck = healthcheck
        self.command = command
    }
}

/// The result of reading a compose file: the services BelloCode will run, and every key it did not use, so the pane
/// can list them. A `rejected` entry means the service it belongs to is not started (it asked for something BelloCode
/// does not allow); `ignored` keys are dropped and the service still runs.
public struct ComposeParseResult: Sendable, Equatable {
    public struct Issue: Sendable, Equatable, Hashable {
        /// `services.db.privileged`
        public var path: String
        public var reason: String
        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    public var services: [ServiceDefinition] = []
    public var ignored: [Issue] = []
    public var rejected: [Issue] = []
    /// Why the file could not be used at all (YAML error, no services); empty when it was read.
    public var errors: [String] = []
    /// Services that were refused (rejected keys, missing image, bad dependency).
    public var refusedServices: [String] = []

    public init() {}

    public var isUsable: Bool { errors.isEmpty }
}

/// Reads the supported subset of a `compose.yaml` / `docker-compose.yml` (docs/features/containers.md, "Services"):
///
/// - top level: `services` (required), `volumes` (named volumes, no options); `version` and `name` are accepted and
///   unused; anything else (`networks`, `configs`, `secrets`, `x-…`) is ignored and listed.
/// - per service: `image` (required: BelloCode builds nothing), `environment` (map or `KEY=value` list), `ports`
///   (container ports, forwarded on demand to the Mac's loopback; never published), `volumes` (named volumes only),
///   `depends_on` (list, or map with `condition`), `healthcheck` (`test`, `interval`, `timeout`, `start_period`,
///   `retries`, `disable`), `command` (string or list).
/// - refused (the service is not started): `build`, bind mounts and host paths, `privileged`, `cap_add`, `devices`,
///   `network_mode`, `pid`, `ipc`, `security_opt`, `userns_mode`, `volumes_from`, `cgroup_parent`, `sysctls`, `runtime`,
///   `device_cgroup_rules`, `extra_hosts`.
/// - ignored and listed: every other key (`restart`, `container_name`, `labels`, `networks`, `env_file`, …).
/// - `${VAR}` interpolation is not performed (BelloCode does not read the Mac's environment): such values are listed.
public enum ComposeParser {
    public static let fileNames = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]

    static let refusedKeys: [String: String] = [
        "build": "BelloCode runs images only; build the image in CI and reference it",
        "privileged": "privileged containers are not allowed",
        "cap_add": "extra capabilities are not allowed",
        "devices": "host devices are not allowed",
        "device_cgroup_rules": "host devices are not allowed",
        "network_mode": "services share the project's own network only",
        "pid": "sharing the host's or another container's processes is not allowed",
        "ipc": "sharing IPC namespaces is not allowed",
        "security_opt": "security options are BelloCode's",
        "userns_mode": "user namespace options are not allowed",
        "volumes_from": "volumes of other containers are not allowed",
        "cgroup_parent": "cgroup options are not allowed",
        "sysctls": "kernel parameters are not allowed",
        "runtime": "container runtimes are BelloCode's",
        "extra_hosts": "host name overrides are not allowed",
    ]

    public static func parse(_ text: String) -> ComposeParseResult {
        var result = ComposeParseResult()
        let root: YAMLNode
        do {
            root = try YAMLSubset.parse(text)
        } catch {
            result.errors.append("The compose file is not valid in the supported YAML subset (\(error.description)).")
            return result
        }
        guard let top = root.entries else {
            result.errors.append("The compose file has no services.")
            return result
        }
        var declaredVolumes = Set<String>()
        for (key, value) in top {
            switch key {
            case "services", "version", "name": continue
            case "volumes":
                for (name, options) in value.entries ?? [] {
                    declaredVolumes.insert(name)
                    if !options.isNull, !(options.entries ?? []).isEmpty {
                        result.ignored.append(.init(path: "volumes.\(name)", reason: "volume options are ignored (a local named volume is used)"))
                    }
                }
            default:
                result.ignored.append(.init(path: key, reason: "not supported"))
            }
        }
        guard let services = top.first(where: { $0.key == "services" })?.value.entries, !services.isEmpty else {
            result.errors.append("The compose file has no services.")
            return result
        }
        for (name, node) in services {
            if let service = parseService(name: name, node: node, declaredVolumes: declaredVolumes, result: &result) {
                result.services.append(service)
            } else {
                result.refusedServices.append(name)
            }
        }
        // Dependencies on refused or unknown services make the dependant unusable too.
        var changed = true
        while changed {
            changed = false
            let names = Set(result.services.map(\.name))
            for service in result.services {
                if let missing = service.dependsOn.first(where: { !names.contains($0.service) }) {
                    result.rejected.append(.init(path: "services.\(service.name).depends_on", reason: "depends on \(missing.service), which is not run"))
                    result.refusedServices.append(service.name)
                    result.services.removeAll { $0.name == service.name }
                    changed = true
                    break
                }
            }
        }
        do {
            _ = try startOrder(result.services)
        } catch {
            result.errors.append(error.description)
            result.services = []
        }
        return result
    }

    static func parseService(name: String, node: YAMLNode, declaredVolumes: Set<String>, result: inout ComposeParseResult) -> ServiceDefinition? {
        let prefix = "services.\(name)"
        guard isValidName(name) else {
            result.rejected.append(.init(path: prefix, reason: "service names use letters, digits, - and _ (at most 40)"))
            return nil
        }
        guard let entries = node.entries else {
            result.rejected.append(.init(path: prefix, reason: "a service must be a mapping"))
            return nil
        }
        var refused = false
        func reject(_ key: String, _ reason: String) {
            result.rejected.append(.init(path: "\(prefix).\(key)", reason: reason))
            refused = true
        }
        func ignore(_ key: String, _ reason: String) { result.ignored.append(.init(path: "\(prefix).\(key)", reason: reason)) }
        var service = ServiceDefinition(name: name, image: "")
        for (key, value) in entries {
            if let reason = refusedKeys[key] {
                reject(key, reason)
                continue
            }
            switch key {
            case "image":
                guard let image = value.string, !image.isEmpty, !image.contains(where: \.isWhitespace) else {
                    reject(key, "the image must be a reference")
                    continue
                }
                if image.contains("${") { reject(key, "variables are not interpolated; write the image reference") }
                service.image = image
            case "environment":
                for (variable, assignment) in environment(value) {
                    guard let assignment else {
                        ignore("environment.\(variable)", "takes its value from the Mac's environment, which BelloCode does not pass")
                        continue
                    }
                    if assignment.contains("${") { ignore("environment.\(variable)", "${…} is not interpolated: passed as written") }
                    guard !variable.isEmpty, !variable.contains("=") else {
                        ignore("environment", "“\(variable)” is not a variable name")
                        continue
                    }
                    service.environment[variable] = assignment
                }
            case "ports":
                for (offset, item) in (value.items ?? []).enumerated() {
                    if let port = port(item) { service.ports.append(port) } else {
                        ignore("ports[\(offset)]", "only single container ports are forwarded (no ranges)")
                    }
                }
            case "volumes":
                for (offset, item) in (value.items ?? []).enumerated() {
                    switch volume(item) {
                    case .named(let mount):
                        service.volumes.append(mount)
                        if !declaredVolumes.contains(mount.name) { ignore("volumes[\(offset)]", "volume “\(mount.name)” is not declared at the top level; created anyway") }
                    case .bind:
                        reject("volumes[\(offset)]", "folders of the Mac cannot be mounted into a service (use a named volume)")
                    case .invalid:
                        ignore("volumes[\(offset)]", "not a named volume (name:/path[:ro])")
                    }
                }
            case "depends_on":
                if let items = value.items {
                    for item in items { if let dependency = item.string { service.dependsOn.append(.init(service: dependency)) } }
                } else if let map = value.entries {
                    for (dependency, options) in map {
                        let raw = options["condition"]?.string ?? ServiceDefinition.Condition.started.rawValue
                        guard let condition = ServiceDefinition.Condition(rawValue: raw) else {
                            ignore("depends_on.\(dependency).condition", "unknown condition; waits for the service to start")
                            service.dependsOn.append(.init(service: dependency))
                            continue
                        }
                        service.dependsOn.append(.init(service: dependency, condition: condition))
                        for (option, _) in options.entries ?? [] where option != "condition" { ignore("depends_on.\(dependency).\(option)", "not supported") }
                    }
                }
            case "healthcheck":
                service.healthcheck = healthcheck(value, ignore: { ignore("healthcheck.\($0)", $1) })
            case "command":
                if let items = value.items {
                    service.command = items.compactMap(\.string)
                } else if let line = value.string {
                    service.command = ShellWords.split(line)
                }
            default:
                ignore(key, "not supported")
            }
        }
        if service.image.isEmpty, !refused { reject("image", "every service needs an image (BelloCode builds nothing)") }
        if service.dependsOn.contains(where: { $0.service == name }) { reject("depends_on", "a service cannot depend on itself") }
        return refused ? nil : service
    }

    static func isValidName(_ name: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !name.isEmpty && name.count <= 40 && name.unicodeScalars.allSatisfy { allowed.contains($0) } && name.first != "-"
    }

    /// `[(name, value)]`; a nil value means `KEY` with no `=` (taken from the host by compose: not supported).
    static func environment(_ node: YAMLNode) -> [(String, String?)] {
        if let entries = node.entries { return entries.map { ($0.key, $0.value.isNull ? nil : $0.value.string) } }
        return (node.items ?? []).compactMap(\.string).map { item in
            guard let equals = item.firstIndex(of: "=") else { return (item, nil) }
            return (String(item[..<equals]), String(item[item.index(after: equals)...]))
        }
    }

    static func port(_ node: YAMLNode) -> ServiceDefinition.Port? {
        if let entries = node.entries {
            guard let target = entries.first(where: { $0.key == "target" })?.value.string.flatMap(Int.init), (1...65535).contains(target) else { return nil }
            return .init(containerPort: target, proto: node["protocol"]?.string ?? "tcp")
        }
        guard var text = node.string else { return nil }
        var proto = "tcp"
        if let slash = text.firstIndex(of: "/") {
            proto = String(text[text.index(after: slash)...])
            text = String(text[..<slash])
        }
        guard let last = text.split(separator: ":").last, let port = Int(last), (1...65535).contains(port) else { return nil }
        return .init(containerPort: port, proto: proto)
    }

    enum VolumeKind {
        case named(ServiceDefinition.VolumeMount)
        case bind
        case invalid
    }

    static func volume(_ node: YAMLNode) -> VolumeKind {
        if let entries = node.entries {
            let type = node["type"]?.string ?? "volume"
            guard type == "volume" else { return type == "bind" ? .bind : .invalid }
            guard let source = node["source"]?.string, let target = node["target"]?.string, isVolumeName(source), target.hasPrefix("/") else {
                return entries.isEmpty ? .invalid : .invalid
            }
            return .named(.init(name: source, target: target, readOnly: node["read_only"]?.string == "true"))
        }
        guard let text = node.string else { return .invalid }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return .invalid }  // an anonymous volume
        if !isVolumeName(parts[0]) { return parts[0].hasPrefix("/") || parts[0].hasPrefix(".") || parts[0].hasPrefix("~") ? .bind : .invalid }
        guard parts[1].hasPrefix("/") else { return .invalid }
        return .named(.init(name: parts[0], target: parts[1], readOnly: parts.count > 2 && parts[2].split(separator: ",").contains("ro")))
    }

    static func isVolumeName(_ text: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return !text.isEmpty && !text.hasPrefix(".") && !text.hasPrefix("/") && text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func healthcheck(_ node: YAMLNode, ignore: (String, String) -> Void) -> ServiceDefinition.Healthcheck? {
        if node["disable"]?.string == "true" { return .init(test: ["NONE"]) }
        var check = ServiceDefinition.Healthcheck(test: [])
        for (key, value) in node.entries ?? [] {
            switch key {
            case "test":
                if let items = value.items {
                    check.test = items.compactMap(\.string)
                } else if let line = value.string {
                    check.test = ["CMD-SHELL", line]
                }
            case "interval": check.intervalSeconds = value.string.flatMap(duration)
            case "timeout": check.timeoutSeconds = value.string.flatMap(duration)
            case "start_period": check.startPeriodSeconds = value.string.flatMap(duration)
            case "retries": check.retries = value.string.flatMap { Int($0) }
            case "disable": continue
            default: ignore(key, "not supported")
            }
        }
        guard let kind = check.test.first, ["CMD", "CMD-SHELL", "NONE"].contains(kind) else {
            ignore("test", "must be a string or a [\"CMD\", …] / [\"CMD-SHELL\", …] list; the image's healthcheck is used")
            return nil
        }
        return check
    }

    /// Compose durations: `1m30s`, `10s`, `500ms`, `1h`; plain numbers are seconds.
    public static func duration(_ text: String) -> Double? {
        if let seconds = Double(text) { return seconds }
        var total = 0.0
        var number = ""
        var unit = ""
        func flush() -> Bool {
            guard let value = Double(number) else { return false }
            switch unit {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            case "ms": total += value / 1000
            case "us": total += value / 1_000_000
            default: return false
            }
            number = ""
            unit = ""
            return true
        }
        for character in text {
            if character.isNumber || character == "." {
                if !unit.isEmpty { guard flush() else { return nil } }
                number.append(character)
            } else {
                unit.append(character)
            }
        }
        guard flush() else { return nil }
        return total
    }

    public struct OrderError: Error, Sendable, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// Start order in layers: every service comes after what it depends on; services of one layer start together.
    public static func startOrder(_ services: [ServiceDefinition]) throws(OrderError) -> [[String]] {
        let byName = Dictionary(services.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var remaining = Set(byName.keys)
        var done = Set<String>()
        var layers: [[String]] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { name in byName[name]!.dependsOn.allSatisfy { done.contains($0.service) || byName[$0.service] == nil } }.sorted()
            guard !ready.isEmpty else {
                throw OrderError(description: "The services depend on each other in a cycle (\(remaining.sorted().joined(separator: ", "))): none can start first.")
            }
            layers.append(ready)
            done.formUnion(ready)
            remaining.subtract(ready)
        }
        return layers
    }
}

/// Shell-like word splitting for plain words and quotes, with no expansion: `node "my tool.js" -v`.
public enum ShellWords {
    public static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var hasWord = false
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                hasWord = true
                continue
            }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                hasWord = true
            } else if character.isWhitespace {
                if hasWord { words.append(current) }
                current = ""
                hasWord = false
            } else {
                current.append(character)
                hasWord = true
            }
        }
        if hasWord { words.append(current) }
        return words
    }
}
