import Foundation

// The bellocode plugin as the mock plays it (docs/features/orchestration.md): `bellocode.info`, `delegate_task` children
// with `metadata.bellocode` and summaries (TurnEngine), opencode's `<subagent>` reports that wake the parent, and the
// cascade stop (the mock's `interrupt` stops children first, as the plugin does on the real server).

extension JSONValue {
    /// The members of an object, by key (nil for other values).
    var objectEntries: [String: JSONValue]? {
        guard case let .object(pairs) = self else { return nil }
        return Dictionary(pairs, uniquingKeysWith: { _, last in last })
    }
}

extension MockOpenCodeServer {
    /// The tools the real plugin registers (`Plugin/server.ts`), for `bellocode.info`.
    static let orchestrationTools = [
        "orchestrator_capabilities", "delegate_task", "task_status", "task_cancel", "create_threads", "thread_list",
        "thread_search", "project_list", "thread_read", "thread_send", "thread_wait", "thread_interrupt",
        "pending_requests", "send_to_user",
    ]

    var orchestrationPluginEnabled: Bool { state.orchestrationPlugin }

    /// Child reports wake parents, as opencode does (off by default for older scripted tests).
    public func setChildReports(_ enabled: Bool) { state.childReports = enabled }

    /// Whether the simulated plugin is loaded (off: `bellocode.info` answers `rpc.unavailable`, like a server without it).
    public func setOrchestrationPlugin(_ enabled: Bool) { state.orchestrationPlugin = enabled }

    func orchestrationRPC(_ method: String, directory: String?) -> ResponsePlan {
        guard state.orchestrationPlugin else {
            return .response(.error(400, tag: "RpcError", message: "RPC is unavailable: bellocode", extra: [("type", "rpc.unavailable")]))
        }
        guard method == "info" else {
            return .response(.error(400, tag: "RpcError", message: "Unknown method \(method)", extra: [("type", "rpc.method_not_found")]))
        }
        let limits: JSONValue = [
            "maxDepth": 2, "maxActiveChildren": 6, "maxCreate": 8, "maxWaitSeconds": 45, "readMaxMessages": 20,
            "readMaxChars": 12000,
        ]
        let output: JSONValue = [
            "contract": 1, "plugin": "bellocode", "location": directory.map(JSONValue.string) ?? .null, "limits": limits,
            "tools": .array(Self.orchestrationTools.map(JSONValue.string)),
        ]
        return .response(.json(["output": output]))
    }

    /// What the plugin's `create_threads` does: top-level sessions in the creator's directory with
    /// `metadata.bellocode {kind: created, by, group}`. Returns their IDs (demos and snapshots).
    public func simulateCreateThreads(by creator: String, titles: [String]) -> [String] {
        guard let owner = state.sessions[creator] else { return [] }
        let group = "grp_" + makeID("grp")
        return titles.map { title in
            makeSession(
                parentID: nil, directory: owner.directory, title: title,
                metadata: ["bellocode": ["kind": "created", "by": .string(creator), "group": .string(group), "workspace": "shared", "background": true]]
            ).id
        }
    }
}
