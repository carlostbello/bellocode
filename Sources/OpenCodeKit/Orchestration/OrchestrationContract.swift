import Foundation

/// The bundled "bellocode" opencode server plugin (`Plugin/`, `Contents/Resources/opencode-plugin`): how it is loaded and
/// what it exposes. docs/features/orchestration.md.
///
/// The plugin is listed in the server's config through `OPENCODE_CONFIG_CONTENT` (verified on 2.3.0: a local directory
/// with a root `server.ts` loads with no npm install; `GET /api/plugin` lists it as `{id: "bellocode", source: {type:
/// "local"}, state: {status: "active"}}`). Its RPC `bellocode` answers `info` with the contract version and the tools it
/// registered for the location.
public enum OrchestrationContract {
    public static let rpcID = "bellocode"
    public static let pluginID = "bellocode"
    /// Bumped by the plugin (`src/logic.ts` `CONTRACT_VERSION`) whenever a tool or metadata shape changes.
    public static let version = 2
    /// The instruction entry the plugin writes on every session (`<context key="bellocode.orchestration">`).
    public static let guidanceKey = "bellocode.orchestration"
    /// `metadata.bellocode` on sessions the plugin created or summarised.
    public static let metadataKey = "bellocode"

    /// Tools the plugin registers (codemode off, so they appear by these names in tool calls).
    public enum Tool {
        public static let capabilities = "orchestrator_capabilities"
        public static let delegateTask = "delegate_task"
        public static let taskStatus = "task_status"
        public static let taskCancel = "task_cancel"
        public static let createThreads = "create_threads"
        public static let threadList = "thread_list"
        public static let threadSearch = "thread_search"
        public static let projectList = "project_list"
        public static let threadRead = "thread_read"
        public static let threadSend = "thread_send"
        public static let threadWait = "thread_wait"
        public static let threadInterrupt = "thread_interrupt"
        public static let pendingRequests = "pending_requests"
        public static let sendToUser = "send_to_user"

        public static let all = [
            capabilities, delegateTask, taskStatus, taskCancel, createThreads, threadList, threadSearch, projectList,
            threadRead, threadSend, threadWait, threadInterrupt, pendingRequests, sendToUser,
        ]
    }

    /// Limits the plugin enforces (mirrors `DEFAULT_LIMITS` in `Plugin/src/logic.ts`; overridable through options).
    public struct Limits: Sendable, Equatable, Codable {
        public var maxDepth: Int
        public var maxActiveChildren: Int
        public var maxCreate: Int
        public var maxWaitSeconds: Int
        public var readMaxMessages: Int
        public var readMaxChars: Int

        public static let standard = Limits(
            maxDepth: 2, maxActiveChildren: 6, maxCreate: 8, maxWaitSeconds: 45, readMaxMessages: 20, readMaxChars: 12_000)

        public init(maxDepth: Int, maxActiveChildren: Int, maxCreate: Int, maxWaitSeconds: Int, readMaxMessages: Int, readMaxChars: Int) {
            self.maxDepth = maxDepth
            self.maxActiveChildren = maxActiveChildren
            self.maxCreate = maxCreate
            self.maxWaitSeconds = maxWaitSeconds
            self.readMaxMessages = readMaxMessages
            self.readMaxChars = readMaxChars
        }
    }

    /// `bellocode.info` output.
    public struct Info: Sendable, Equatable, Decodable {
        public var contract: Int
        public var plugin: String
        public var location: String?
        public var limits: Limits
        public var tools: [String]

        public var isCompatible: Bool { contract == OrchestrationContract.version }
        /// Tools the app expects that the plugin did not register.
        public var missingTools: [String] { Tool.all.filter { !tools.contains($0) } }
    }

    /// The `OPENCODE_CONFIG_CONTENT` JSON that loads the plugin from `directory`. `subagent_depth` is aligned with the
    /// plugin's depth limit so native `subagent` calls and `delegate_task` nest equally deep. With `container`, it also
    /// sets the shell to `bellocode-exec`, turns formatters and LSP off, defines the self-check's command and passes the
    /// plugin its container guard options. `mcpServers` replaces those local MCP servers' entries (container execution:
    /// servers configured for all projects are refused, `MCPRouting`).
    public static func serverConfig(pluginDirectory: URL?, limits: Limits = .standard, container: ContainerExecution? = nil,
                                    mcpServers: [String: JSONValue] = [:], projectConfig: ProjectConfigOptions? = nil) -> String {
        var options: [String: JSONValue] = [
            "limits": .object([
                "maxDepth": .number(Double(limits.maxDepth)),
                "maxActiveChildren": .number(Double(limits.maxActiveChildren)),
                "maxCreate": .number(Double(limits.maxCreate)),
                "maxWaitSeconds": .number(Double(limits.maxWaitSeconds)),
                "readMaxMessages": .number(Double(limits.readMaxMessages)),
                "readMaxChars": .number(Double(limits.readMaxChars)),
            ])
        ]
        if let container { options["container"] = container.pluginOptions }
        if let projectConfig { options["projectConfig"] = projectConfig.pluginOptions }
        var config: [String: JSONValue] = [
            "experimental": .object(["subagent_depth": .number(Double(limits.maxDepth))])
        ]
        if let pluginDirectory {
            config["plugins"] = .array([.object(["package": .string(pluginDirectory.path), "options": .object(options)])])
        }
        if let container { config.merge(container.configAdditions) { _, new in new } }
        if !mcpServers.isEmpty { config["mcp"] = .object(["servers": .object(mcpServers)]) }
        let data = (try? JSONEncoder().encode(JSONValue.object(config))) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

extension OrchestrationContract {
    /// How the plugin handles repository opencode configuration (docs/features/opencode-config.md): in `.bellocode`
    /// mode it writes each session's repository `AGENTS.md` text as an instruction entry and, for projects listed in
    /// the trust file, adds their `.opencode/` agents, commands and skills to that location; in `.native` mode opencode
    /// does all of it and the plugin does nothing.
    public struct ProjectConfigOptions: Sendable, Hashable {
        public var policy: RepositoryConfigPolicy
        public var trustFile: URL

        public init(policy: RepositoryConfigPolicy, trustFile: URL) {
            self.policy = policy
            self.trustFile = trustFile
        }

        var pluginOptions: JSONValue {
            .object(["mode": .string(policy.rawValue), "trustFile": .string(trustFile.path)])
        }
    }

    /// The instruction entry carrying a session's repository `AGENTS.md` text in `.bellocode` mode.
    public static let projectInstructionsKey = "bellocode.project-instructions"
    /// RPC methods of the project-config loader.
    public enum ProjectConfigRPC {
        /// Re-reads the trust file and the repository files for the location, then reloads its agents, commands and
        /// skills. Output: `ProjectConfigStatus`.
        public static let reload = "projectConfig"
    }

    /// `bellocode.projectConfig` output for one location.
    public struct ProjectConfigStatus: Sendable, Equatable, Decodable {
        public var mode: String
        public var trusted: Bool
        public var agents: [String]
        public var commands: [String]
        public var skills: [String]
        /// Files skipped, with the reason (unsupported or malformed frontmatter, too large).
        public var skipped: [String]
    }
}

extension OpenCodeClient {
    /// Asks the plugin at `directory` to re-read the trust file and the repository's configuration (`reload: false`
    /// only reports what is loaded).
    public func reloadProjectConfig(directory: String, reload: Bool = true) async throws(BrowserRPCError) -> OrchestrationContract.ProjectConfigStatus {
        let output = try await pluginRPC(
            OrchestrationContract.rpcID, OrchestrationContract.ProjectConfigRPC.reload, input: .object(["reload": .bool(reload)]), directory: directory)
        guard let data = try? output.encodedData(), let status = try? JSONDecoder().decode(OrchestrationContract.ProjectConfigStatus.self, from: data)
        else { throw .rejected(status: 200, tag: "DecodingError", message: "unexpected bellocode.projectConfig output") }
        return status
    }

    /// `POST /api/location/reload` (location.reload): rebuilds every loaded location from its configuration. Pending
    /// permissions and forms are cancelled; running sessions continue with fresh services at the next step boundary.
    public func reloadLocations() async throws {
        let request = try makeRequest(.post, ["api", "location", "reload"], timeout: .seconds(60))
        try await sendIgnoringBody("location.reload", request)
    }

    /// `GET /api/plugin` (plugin.list) for a location.
    public func plugins(directory: String) async throws -> [PluginInfo] {
        let request = try makeRequest(.get, ["api", "plugin"], directory: directory)
        return try await send("plugin.list", request, as: LocatedList<PluginInfo>.self).data
    }
}

/// `GET /api/plugin` entry: id, source type (`builtin`, `local`, `package`) and state (`active`, `failed`, `blocked`, …).
public struct PluginInfo: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var source: String
    public var status: String
    public var error: String?

    public init(id: String, source: String, status: String, error: String? = nil) {
        self.id = id
        self.source = source
        self.status = status
        self.error = error
    }

    enum CodingKeys: String, CodingKey { case id, source, state }
    struct Source: Decodable { var type: String }
    struct State: Decodable { var status: String; var message: String?; var error: String? }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = (try? c.decode(Source.self, forKey: .source).type) ?? "unknown"
        let state = try? c.decode(State.self, forKey: .state)
        status = state?.status ?? "unknown"
        error = state?.message ?? state?.error
    }
}

extension OpenCodeClient {
    /// `bellocode.info` for a location. A location activates on first use, and until then the server answers
    /// `rpc.unavailable` (seen on 2.3.0 for about a second after the first request), so this retries a few times.
    public func orchestrationInfo(directory: String, attempts: Int = 6) async throws(BrowserRPCError) -> OrchestrationContract.Info {
        var lastError = BrowserRPCError.transport("not attempted")
        for attempt in 0..<max(1, attempts) {
            let output: JSONValue
            do {
                output = try await pluginRPC(OrchestrationContract.rpcID, "info", input: .object([:]), directory: directory)
            } catch {
                lastError = error
                guard case .rpc(let type, _) = error, type == "rpc.unavailable" || type == "unavailable" else { throw error }
                if attempt + 1 < attempts {
                    do { try await Task.sleep(for: .milliseconds(250 * (attempt + 1))) } catch { throw .cancelled }
                }
                continue
            }
            guard let data = try? output.encodedData(), let info = try? JSONDecoder().decode(OrchestrationContract.Info.self, from: data)
            else { throw .rejected(status: 200, tag: "DecodingError", message: "unexpected bellocode.info output") }
            return info
        }
        throw lastError
    }
}
