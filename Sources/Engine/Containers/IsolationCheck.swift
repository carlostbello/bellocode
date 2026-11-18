import BelloCore
import ContainerKit
import Foundation
import OpenCodeKit

/// The result of "Verify isolation": every path that can run a command, and where it ran.
public struct IsolationReport: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// Ran in the project's container (the probe printed `container Linux`).
        case container(String)
        /// Ran on the Mac: an escape. The detail says which path.
        case host(String)
        /// Correctly refused (blocked state, or a path that is configured off).
        case off(String)
        /// Could not be checked (no project with an image, server offline, timeout).
        case skipped(String)
        /// Ran on the Mac by design, inside a boundary that was exercised and held (host git's sandbox).
        case confined(String)
        case failed(String)

        public var isProblem: Bool {
            switch self {
            case .host, .failed: true
            default: false
            }
        }

        public var word: String {
            switch self {
            case .container: "Container"
            case .host: "HOST"
            case .off: "Off"
            case .skipped: "Skipped"
            case .confined: "Confined"
            case .failed: "Failed"
            }
        }

        public var detail: String {
            switch self {
            case .container(let text), .host(let text), .off(let text), .skipped(let text), .confined(let text), .failed(let text): text
            }
        }
    }

    public struct Check: Sendable, Equatable, Identifiable {
        public var name: String
        public var outcome: Outcome
        public var id: String { name }
        public init(_ name: String, _ outcome: Outcome) {
            self.name = name
            self.outcome = outcome
        }
    }

    public var date: Date
    public var directory: String?
    /// Whether the session-based paths (command template, schedule condition, BelloCode's terminal) were run.
    public var full: Bool
    public var checks: [Check]

    public init(date: Date, directory: String?, full: Bool, checks: [Check]) {
        self.date = date
        self.directory = directory
        self.full = full
        self.checks = checks
    }

    /// The overall result. Only a report where every applicable check ran and held is `isolated`; anything that could
    /// not be checked makes it `notVerified` (never shown as a pass); an escape or failure is a `problem`.
    public enum Verdict: String, Sendable, Equatable {
        case isolated
        case notVerified
        case problem

        public var word: String {
            switch self {
            case .isolated: "Isolated"
            case .notVerified: "Not verified"
            case .problem: "Problem"
            }
        }
    }

    /// Paths that executed on the Mac.
    public var hostPaths: [Check] { checks.filter { if case .host = $0.outcome { true } else { false } } }
    public var problems: [Check] { checks.filter(\.outcome.isProblem) }
    /// Checks that did not run (no project, server offline, runtime refusing commands, no answer from the plugin).
    public var unverified: [Check] { checks.filter { if case .skipped = $0.outcome { true } else { false } } }
    public var verdict: Verdict {
        if !problems.isEmpty { return .problem }
        if !unverified.isEmpty || ranInContainer == 0 { return .notVerified }
        return .isolated
    }
    /// Every applicable check ran and none ran on the host or failed.
    public var passed: Bool { verdict == .isolated }
    public var ranInContainer: Int { checks.filter { if case .container = $0.outcome { true } else { false } }.count }

    public var summary: String {
        if !hostPaths.isEmpty { return "\(hostPaths.count) path\(hostPaths.count == 1 ? "" : "s") ran on this Mac: \(hostPaths.map(\.name).joined(separator: ", "))" }
        if !problems.isEmpty { return "\(problems.count) check\(problems.count == 1 ? "" : "s") failed" }
        if !unverified.isEmpty {
            return "Not verified: \(unverified.map(\.name).joined(separator: ", ")) could not be checked"
        }
        if ranInContainer == 0 { return "Not verified: no command path was exercised" }
        return "Isolated: \(ranInContainer) of \(checks.count) checks ran in the container\(full ? "" : " (quick check)")"
    }
}

/// Proves, with the real server configuration, that commands land in the project's container
/// (docs/features/containers.md). Each runtime path runs the same probe (`ContainerExecution.probe`) and writes its
/// answer to a marker under `/tmp`: read inside the container it proves the path ran there; found on the Mac it
/// proves an escape. Nothing is written into a project folder and no prompt is ever sent.
///
/// Quick (engine start, invisible): the configuration (shell, formatter, LSP, local MCP servers and how each is routed,
/// worktree start commands, the plugin guard), a shell job (`/api/shell`, the agent shell tool's path), a PTY started
/// with `$SHELL` (`/api/pty`) and a scratch local MCP server registered like a project's. Full (on demand, `make smoke`): also a command template (`!`…``), a schedule condition and
/// BelloCode's own terminal (a persistent PTY), which need a scratch thread that is deleted afterwards.
public enum IsolationCheck {
    public struct Context: Sendable {
        public var client: @Sendable () async throws -> OpenCodeClient
        public var helperPath: String
        public var terminalEnvironment: [String: String]
        /// opencode's `git` shim (nil: only BelloCode's own host git is probed).
        public var gitShim: String?

        public init(
            client: @escaping @Sendable () async throws -> OpenCodeClient, helperPath: String, terminalEnvironment: [String: String], gitShim: String? = nil
        ) {
            self.client = client
            self.helperPath = helperPath
            self.terminalEnvironment = terminalEnvironment
            self.gitShim = gitShim
        }
    }

    static func marker(_ name: String) -> String { "/tmp/bellocode-verify-\(name)" }

    static func probeCommand(_ name: String) -> String { "\(ContainerExecution.probe) > \(marker(name))" }

    /// Reads a marker inside the container and on the Mac, then removes both.
    static func outcome(of name: String, runtime: any WorkspaceRuntime, container: String, user: String, path: String) async -> IsolationReport.Outcome {
        let hostMarker = "/private" + marker(name)
        defer { try? FileManager.default.removeItem(atPath: hostMarker) }
        if let text = try? String(contentsOfFile: hostMarker, encoding: .utf8), !text.isEmpty {
            return .host("\(path) ran on this Mac (\(text.trimmingCharacters(in: .whitespacesAndNewlines)))")
        }
        let result = try? await runtime.run(container: container, argv: ["/bin/sh", "-c", "cat \(marker(name)) 2>/dev/null; rm -f \(marker(name))"],
                                            workingDir: nil, environment: [:], user: user, timeout: .seconds(10))
        let text = result.map { String(decoding: $0.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if text.hasPrefix("container") { return .container("\(path): \(text)") }
        if text.hasPrefix("host") { return .host("\(path) reported \(text)") }
        return .failed("\(path) left no answer (it did not run, or ran somewhere unexpected)")
    }

    static func clear(_ names: [String], runtime: any WorkspaceRuntime, container: String, user: String) async {
        for name in names { try? FileManager.default.removeItem(atPath: "/private" + marker(name)) }
        _ = try? await runtime.run(container: container, argv: ["/bin/sh", "-c", "rm -f " + names.map(marker).joined(separator: " ")],
                                   workingDir: nil, environment: [:], user: user, timeout: .seconds(10))
    }

    /// Scans the loaded configuration for anything that would run on the host.
    static func configurationChecks(_ entries: [JSONValue], projects: [OpenCodeKit.Project], helperPath: String, guardInstalled: Bool?) -> [IsolationReport.Check] {
        var checks: [IsolationReport.Check] = []
        var shells: [String] = []
        var formatterOn = false, lspOn = false
        // Entries come lowest priority first; a later entry replaces a server's whole entry (checked on 2.3.0).
        var mcpRoutes: [String: MCPRouting.Route] = [:]
        func scan(_ value: JSONValue) {
            if let shell = value["shell"]?.stringValue { shells.append(shell) }
            if let formatter = value["formatter"] {
                if case .bool(true) = formatter { formatterOn = true }
                if case .object(let entries) = formatter, !entries.isEmpty {
                    formatterOn = formatterOn || entries.values.contains { $0["disabled"]?.boolValue != true }
                }
            }
            if let lsp = value["lsp"] {
                if case .bool(true) = lsp { lspOn = true }
                if case .object(let entries) = lsp, entries.values.contains(where: { $0["disabled"]?.boolValue != true }) { lspOn = true }
            }
            if case .object(let servers)? = value["mcp"]?["servers"] {
                for (name, server) in servers {
                    guard server["type"]?.stringValue == "local", server["disabled"]?.boolValue != true else {
                        mcpRoutes[name] = nil
                        continue
                    }
                    let command: [String] = if case .array(let items)? = server["command"] { items.compactMap(\.stringValue) } else { [] }
                    mcpRoutes[name] = MCPRouting.route(of: command, helper: helperPath)
                }
            }
        }
        for entry in entries {
            if let info = entry["info"] { scan(info) } else { scan(entry) }
        }
        let foreign = shells.filter { $0 != helperPath }
        checks.append(.init("Configured shell", foreign.isEmpty && shells.contains(helperPath)
            ? .container("every shell setting is bellocode-exec")
            : .host(foreign.first.map { "a configuration sets the shell to \($0): commands could run on this Mac" }
                ?? "no configuration sets the shell to bellocode-exec: commands could run on this Mac")))
        checks.append(.init("Formatters", formatterOn ? .host("formatters are on: they run project tooling on this Mac") : .off("off")))
        checks.append(.init("Language servers", lspOn ? .host("language servers are configured: they would run on this Mac") : .off("off")))
        var routedMCP: [String] = [], refusedMCP: [String] = [], hostMCP: [String] = []
        for (name, route) in mcpRoutes {
            switch route {
            case .container: routedMCP.append(name)
            case .refused: refusedMCP.append(name)
            case .host(let program): hostMCP.append("\(name) (\(program))")
            }
        }
        checks.append(.init("Local MCP servers", localMCPOutcome(routed: routedMCP, refused: refusedMCP, host: hostMCP)))
        let starts = projects.filter { !($0.commands?.start ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        checks.append(.init("Worktree start commands", starts.isEmpty ? .off("none set (setup scripts run in the container)")
            : .host("opencode would run a worktree start command on this Mac for \(starts.map(\.canonical).joined(separator: ", "))")))
        switch guardInstalled {
        case true?: checks.append(.init("Plugin guard", .container("shell.create.before forces bellocode-exec")))
        case false?: checks.append(.init("Plugin guard", .failed("the bundled plugin did not install its shell guard")))
        case nil: checks.append(.init("Plugin guard", .skipped("the bundled plugin did not answer")))
        }
        return checks
    }

    static func localMCPOutcome(routed: [String], refused: [String], host: [String]) -> IsolationReport.Outcome {
        if !host.isEmpty { return .host("local MCP servers would run on this Mac: \(Set(host).sorted().joined(separator: ", "))") }
        let refusedText = refused.isEmpty ? "" : "; refused (configured for all projects): \(Set(refused).sorted().joined(separator: ", "))"
        if !routed.isEmpty { return .container("routed into the project's container (bellocode-exec --stdio): \(Set(routed).sorted().joined(separator: ", "))\(refusedText)") }
        if !refused.isEmpty { return .off("none run" + refusedText) }
        return .off("none configured")
    }

    /// Servers opencode lists for the location that neither its configuration nor BelloCode accounts for (added at
    /// runtime by another API client): their command cannot be checked.
    static func unaccountedMCP(listed: [MCPServerStatus], entries: [JSONValue], registered: Set<String>) -> [String] {
        var known = registered
        for entry in entries {
            let value = entry["info"] ?? entry
            if case .object(let servers)? = value["mcp"]?["servers"] { known.formUnion(servers.keys) }
        }
        return listed.map(\.name).filter { !known.contains($0) && $0 != verifyMCPName }.sorted()
    }

    /// The scratch MCP server the self-check registers for a moment.
    static let verifyMCPName = "bellocode-verify-mcp"

    /// Runs the check against `directory` (a project whose container can run). `full` adds the session-based paths.
    @MainActor
    static func run(service: EnvironmentService, context: Context, directory: String?, full: Bool) async -> IsolationReport {
        // Host git (BelloCode's and opencode's): a scratch repository whose configuration names a program at every git
        // extension point; none may run. Needs neither the server nor a container.
        var checks: [IsolationReport.Check] = [.init("Host git", await HostGitProbe.run(shim: context.gitShim))]
        let client: OpenCodeClient
        do {
            client = try await context.client()
        } catch {
            checks.append(.init("Server", .skipped("opencode is not running: \(error)")))
            return IsolationReport(date: Date(), directory: directory, full: full, checks: checks)
        }

        // Configuration (no project needed).
        let entries = (try? await client.configEntries(directory: directory)) ?? []
        let projects = (try? await client.projects()) ?? []
        var guardInstalled: Bool?
        if let directory {
            // The plugin loads per location: the first call for a new project may arrive before it registered.
            for attempt in 0..<12 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(250)) }
                if let output = try? await client.pluginRPC(OrchestrationContract.rpcID, "info", input: .object([:]), directory: directory) {
                    guardInstalled = output["container"]?["guard"]?.boolValue ?? false
                    break
                }
            }
        }
        // Project MCP servers are runtime registrations (not in the configuration documents): scanned as the
        // highest-priority entry, since a location's runtime add replaces a configured server of the same name.
        let registered = directory.map { service.registeredMCP[service.environment(for: $0).directory] ?? [:] } ?? [:]
        let scanned = registered.isEmpty ? entries : entries + [.object(["mcp": .object(["servers": .object(registered)])])]
        checks += configurationChecks(scanned, projects: projects, helperPath: context.helperPath, guardInstalled: guardInstalled)

        guard let directory else {
            checks.append(.init("Runtime paths", .skipped("no project with a container image to run the probes in: open a project and choose an image, then verify again")))
            return IsolationReport(date: Date(), directory: nil, full: full, checks: checks)
        }
        let container: String, spec: WorkspaceSpec
        do {
            (container, spec, _) = try await service.readyContainer(directory)
        } catch {
            // Commands are refused (nothing can escape now), but no path was exercised: not a pass.
            checks.append(.init("Runtime paths", .skipped("not exercised: commands are refused in this project now (\(EnvironmentService.describe(error)))")))
            return IsolationReport(date: Date(), directory: directory, full: full, checks: checks)
        }
        let runtime = service.activeRuntime
        let names = ["shell", "pty", "mcp", "command", "schedule", "terminal"]
        await clear(names, runtime: runtime, container: container, user: spec.user)

        // 1. Shell job: the agent shell tool, /api/shell and /session/{id}/shell share this path.
        do {
            let job = try await client.createShellJob(command: probeCommand("shell"), cwd: directory, timeout: 20_000)
            var current = job
            for _ in 0..<100 where !current.isFinished {
                try await Task.sleep(for: .milliseconds(100))
                current = try await client.shellJob(job.id, directory: directory)
            }
            if current.shell != context.helperPath {
                checks.append(.init("Shell tool (/api/shell)", .host("the job ran with \(current.shell), not bellocode-exec")))
            } else {
                var result = await outcome(of: "shell", runtime: runtime, container: container, user: spec.user, path: "shell job")
                if case .failed(let text) = result {
                    // Only the helper's own message (never the command's output) explains the failure.
                    let output = (try? await client.shellJobOutput(job.id, directory: directory))?.output ?? ""
                    let helper = output.split(separator: "\n").first { $0.hasPrefix("BelloCode:") }.map(String.init)
                    result = .failed(text + " (exit \(current.exit.map { String(Int($0)) } ?? "none")\(helper.map { "; \($0)" } ?? ""))")
                }
                checks.append(.init("Shell tool (/api/shell)", result))
            }
        } catch {
            checks.append(.init("Shell tool (/api/shell)", .failed("could not start a shell job: \(error)")))
        }

        // 2. A PTY with opencode's default command ($SHELL).
        do {
            let pty = try await client.createLegacyPTY(directory: directory, args: ["-c", probeCommand("pty") + "; sleep 5"], title: "BelloCode isolation check")
            var result = IsolationReport.Outcome.failed("no answer")
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(150))
                result = await outcome(of: "pty", runtime: runtime, container: container, user: spec.user, path: "PTY ($SHELL)")
                if case .failed = result { continue }
                break
            }
            try? await client.deleteLegacyPTY(pty, directory: directory)
            checks.append(.init("PTY ($SHELL)", result))
        } catch {
            checks.append(.init("PTY ($SHELL)", .failed("could not start a PTY: \(error)")))
        }

        // 3. A local MCP server: registered for the location with the routed command (as project servers are), it
        // writes the probe and exits; opencode marks it failed, which is fine: only where it ran matters.
        let listed = (try? await client.mcpServers(directory: directory)) ?? []
        let strangers = unaccountedMCP(listed: listed, entries: entries, registered: service.registeredMCPNames(directory))
        if !strangers.isEmpty {
            checks.append(.init("MCP servers added at runtime", .failed("added by another client, command not checked: \(strangers.joined(separator: ", "))")))
        }
        do {
            let config = MCPRouting.projectServerConfig(
                helper: context.helperPath, project: service.environment(for: directory).directory,
                argv: ["/bin/sh", "-c", probeCommand("mcp")], environment: [:], timeoutMilliseconds: 10_000)
            try await client.addMCPServer(verifyMCPName, config: config, directory: directory)
            var result = IsolationReport.Outcome.failed("no answer")
            for _ in 0..<40 {
                result = await outcome(of: "mcp", runtime: runtime, container: container, user: spec.user, path: "MCP server (stdio)")
                if case .failed = result { try? await Task.sleep(for: .milliseconds(150)); continue }
                break
            }
            try? await client.removeMCPServer(verifyMCPName, directory: directory)
            checks.append(.init("MCP server (stdio)", result))
        } catch {
            try? await client.removeMCPServer(verifyMCPName, directory: directory)
            checks.append(.init("MCP server (stdio)", .failed("could not register a scratch MCP server: \(error)")))
        }

        if full { checks += await sessionChecks(client: client, context: context, directory: directory, runtime: runtime, container: container, user: spec.user) }
        return IsolationReport(date: Date(), directory: directory, full: full, checks: checks)
    }

    /// Command template, schedule condition and BelloCode's terminal, in a scratch thread deleted afterwards.
    static func sessionChecks(client: OpenCodeClient, context: Context, directory: String, runtime: any WorkspaceRuntime,
                              container: String, user: String) async -> [IsolationReport.Check] {
        var checks: [IsolationReport.Check] = []
        let session: SessionInfo
        do {
            session = try await client.createSession(SessionCreateRequest(
                directory: directory, title: "BelloCode isolation check", metadata: .object(["bellocode": .object(["kind": .string("isolation-check")])]),
                permissions: [PermissionRule(action: "shell", resource: "*", effect: .allow),
                              PermissionRule(action: "external_directory", resource: "*", effect: .allow)]))
        } catch {
            return [.init("Command template, schedule, terminal", .skipped("could not create a scratch thread: \(error)"))]
        }

        // 3. Command template: `!`…`` is expanded with the configured shell before any prompt; the command's model does
        // not exist, so nothing is sent to a provider.
        do {
            try await client.runCommand(sessionID: session.id, CommandRequest(name: ContainerExecution.verifyCommandName, text: ""))
        } catch {
            // Expected: the prompt after the expansion fails on the missing model.
        }
        var command = IsolationReport.Outcome.failed("no answer")
        for _ in 0..<30 {
            command = await outcome(of: "command", runtime: runtime, container: container, user: user, path: "command template")
            if case .failed = command { try? await Task.sleep(for: .milliseconds(200)); continue }
            break
        }
        checks.append(.init("Command template (!`…`)", command))
        try? await client.interrupt(sessionID: session.id)

        // 4. Schedule condition: due in a second, never wakes the thread.
        do {
            let schedule = try await client.createProbeSchedule(sessionID: session.id, directory: directory, run: probeCommand("schedule"), after: 1)
            var result = IsolationReport.Outcome.failed("the condition did not run within 20 s")
            for _ in 0..<80 {
                try await Task.sleep(for: .milliseconds(250))
                let answer = await outcome(of: "schedule", runtime: runtime, container: container, user: user, path: "schedule condition")
                if case .failed = answer { continue }
                result = answer
                break
            }
            try? await client.deleteSchedule(schedule.id, directory: directory)
            checks.append(.init("Schedule condition", result))
        } catch where "\(error)".contains("Scheduled tasks are disabled") {
            // opencode's own schedules are off in BelloCode's server configuration (BelloCode schedules its tasks
            // itself), so no condition can run anywhere; when enabled they use the same configured shell.
            checks.append(.init("Schedule condition", .off("opencode schedules are disabled in this configuration")))
        } catch {
            checks.append(.init("Schedule condition", .failed("could not create a schedule: \(error)")))
        }

        // 5. BelloCode's terminal: a persistent PTY with the helper as its command (TerminalLaunch).
        do {
            let pty = try await client.createTerminal(sessionID: session.id, PTYCreateRequest(
                command: context.helperPath, args: ["-c", probeCommand("terminal") + "; sleep 5"], cwd: directory,
                title: "BelloCode isolation check", env: context.terminalEnvironment))
            var result = IsolationReport.Outcome.failed("no answer")
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(150))
                result = await outcome(of: "terminal", runtime: runtime, container: container, user: user, path: "terminal")
                if case .failed = result { continue }
                break
            }
            try? await client.deleteTerminal(pty.id)
            checks.append(.init("Terminal (persistent PTY)", result))
        } catch {
            checks.append(.init("Terminal (persistent PTY)", .failed("could not open a terminal: \(error)")))
        }
        try? await client.deleteSession(session.id)
        return checks
    }
}

extension EnvironmentService {
    /// "Verify isolation": runs the self-check in `directory` (default: the most recently used project with an image).
    /// `full` adds the session-based paths (a scratch thread appears briefly).
    @discardableResult
    public func verifyIsolation(directory: String? = nil, full: Bool = false) async -> IsolationReport? {
        guard isEnabled, let context = isolationContext else { return nil }
        isVerifyingIsolation = true
        defer { isVerifyingIsolation = false }
        let target = directory.map { environment(for: $0).directory } ?? environments
            .filter { $0.image != nil && !$0.phase.isBlocking }
            .max { ($0.record.lastUsed ?? .distantPast) < ($1.record.lastUsed ?? .distantPast) }?.directory
        let report = await IsolationCheck.run(service: self, context: context, directory: target, full: full)
        isolation = report
        if !report.hostPaths.isEmpty { Self.log.error("isolation check: a path ran on the host") }
        return report
    }
}
