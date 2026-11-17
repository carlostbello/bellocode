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
    public static let version = 1
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
    /// plugin's depth limit so native `subagent` calls and `delegate_task` nest equally deep.
    public static func serverConfig(pluginDirectory: URL, limits: Limits = .standard) -> String {
        let config: JSONValue = .object([
            "plugins": .array([
                .object([
                    "package": .string(pluginDirectory.path),
                    "options": .object([
                        "limits": .object([
                            "maxDepth": .number(Double(limits.maxDepth)),
                            "maxActiveChildren": .number(Double(limits.maxActiveChildren)),
                            "maxCreate": .number(Double(limits.maxCreate)),
                            "maxWaitSeconds": .number(Double(limits.maxWaitSeconds)),
                            "readMaxMessages": .number(Double(limits.readMaxMessages)),
                            "readMaxChars": .number(Double(limits.readMaxChars)),
                        ])
                    ]),
                ])
            ]),
            "experimental": .object(["subagent_depth": .number(Double(limits.maxDepth))]),
        ])
        let data = (try? JSONEncoder().encode(config)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
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
