import BelloCore
import Foundation
import OpenCodeKit

/// Binds one agent call to its thread's place in the shared browser before it leaves BelloCode (review: "Bind the
/// default before a call leaves BelloCode"). Pure; unit-tested.
///
/// - A call without `tab` goes to the thread's selected tab (its main tab by default), created in its group first.
/// - `tabs new` always lands in the thread's group with a group-prefixed string ID.
/// - A string tab must be the thread's own or one the person shared with it; a numeric tab is translated to its string
///   ID when known (browse reserves only string tabs) and refused otherwise.
/// - `tabs list` and group operations are limited to the thread's group; multi-tab arrays must be all its own.
/// - Global or unmanaged tools (`settings`, `recording`) are not offered.
public enum BrowserCallPolicy {
    /// Tools never offered to agents (global settings; captures writing files in the container).
    public static let hiddenTools: Set<String> = ["settings", "recording"]

    public struct Context: Sendable {
        public var binding: BrowserBinding
        /// Tabs other threads shared with this one.
        public var sharedWithMe: Set<String>
        /// This thread's tabs that it shared with others (the driver lease applies to them too).
        public var sharedByMe: Set<String>
        /// Numeric relay IDs → string IDs seen in results.
        public var numeric: [Int: String]
        /// Who owns a tab (for messages), by tab ID.
        public var ownerName: @Sendable (String) -> String?

        public init(binding: BrowserBinding, sharedWithMe: Set<String> = [], sharedByMe: Set<String> = [], numeric: [Int: String] = [:],
                    ownerName: @escaping @Sendable (String) -> String? = { _ in nil }) {
            self.binding = binding
            self.sharedWithMe = sharedWithMe
            self.sharedByMe = sharedByMe
            self.numeric = numeric
            self.ownerName = ownerName
        }
    }

    public enum Plan: Sendable, Equatable {
        /// Forward `arguments` to `tool`; serialise on `tab`; `shared` applies the driver lease; `ensure` creates the
        /// tab in the group first (idempotent); `remember` records a new tab of the thread.
        case forward(tool: String, arguments: JSONValue, tab: String, shared: Bool, ensure: Bool, remember: String?)
        case refuse(String)
    }

    enum Resolved {
        case success(String)
        case failure(String)
    }

    public static func plan(tool: String, arguments: JSONValue, context: Context) -> Plan {
        if hiddenTools.contains(tool) { return .refuse("The \(tool) tool is not available in BelloCode's shared Chrome.") }
        var args: [String: JSONValue] = arguments.objectValue ?? [:]
        let binding = context.binding

        func resolve(_ value: JSONValue?) -> Resolved {
            switch value {
            case nil, .null?: return .success(binding.selectedTab)
            case .number(let n)?:
                guard let id = context.numeric[Int(n)] else {
                    return .failure("Use your tab's string ID (\(binding.selectedTab), or one from `tabs` with action list), not a number.")
                }
                return .success(id)
            case .string(let s)?:
                if let n = Int(s), let id = context.numeric[n] { return .success(id) }
                return .success(s)
            default: return .failure("tab must be a tab ID string.")
            }
        }
        func access(_ tab: String) -> String? {
            if binding.owns(tab) || context.sharedWithMe.contains(tab) { return nil }
            if let owner = context.ownerName(tab) {
                return "The tab \(tab) belongs to the thread “\(owner)”. Work in your own tabs (group \(binding.group)); ask the person to share that tab with you if you need it."
            }
            return "The tab \(tab) is not one of yours. Your tabs are in the group \(binding.group) (default \(binding.selectedTab)); list them with `tabs` action list."
        }
        func isShared(_ tab: String) -> Bool { context.sharedWithMe.contains(tab) || context.sharedByMe.contains(tab) }

        if tool == "tabs" {
            let action = args["action"]?.stringValue ?? "list"
            switch action {
            case "list":
                args["group"] = .string(binding.group)
                args.removeValue(forKey: "tab")
                return .forward(tool: tool, arguments: .object(args), tab: "list:" + binding.group, shared: false, ensure: false, remember: nil)
            case "new":
                let id = BrowserNaming.tabID(group: binding.group, requested: args["id"]?.stringValue, existing: binding.tabs)
                args["id"] = .string(id)
                args["group"] = .string(binding.group)
                args.removeValue(forKey: "tab")
                return .forward(tool: tool, arguments: .object(args), tab: id, shared: false, ensure: false, remember: id)
            default:
                if case .array(let entries)? = args["tabs"] {
                    var mapped: [JSONValue] = []
                    for entry in entries {
                        switch resolve(entry) {
                        case .failure(let message): return .refuse(message)
                        case .success(let tab):
                            if context.sharedWithMe.contains(tab) { return .refuse("You can close or change only your own tabs; \(tab) was shared with you.") }
                            if let refusal = access(tab) { return .refuse(refusal) }
                            mapped.append(.string(tab))
                        }
                    }
                    args["tabs"] = .array(mapped)
                    return .forward(tool: tool, arguments: .object(args), tab: "group:" + binding.group, shared: false, ensure: false, remember: nil)
                }
                if args["tab"] == nil, args["id"] == nil, args["group"] != nil || action == "close" && args["tab"] == nil {
                    // A group operation acts on this thread's group only.
                    args["group"] = .string(binding.group)
                    return .forward(tool: tool, arguments: .object(args), tab: "group:" + binding.group, shared: false, ensure: false, remember: nil)
                }
                let target: Resolved = args["tab"] != nil ? resolve(args["tab"]) : resolve(args["id"])
                switch target {
                case .failure(let message): return .refuse(message)
                case .success(let tab):
                    if let refusal = access(tab) { return .refuse(refusal) }
                    if action == "close", context.sharedWithMe.contains(tab) {
                        return .refuse("\(tab) was shared with you; only its own thread or the person can close it. Stop using it instead.")
                    }
                    if args["tab"] != nil { args["tab"] = .string(tab) } else { args["id"] = .string(tab) }
                    return .forward(tool: tool, arguments: .object(args), tab: tab, shared: isShared(tab), ensure: false, remember: nil)
                }
            }
        }

        switch resolve(args["tab"]) {
        case .failure(let message): return .refuse(message)
        case .success(let tab):
            if let refusal = access(tab) { return .refuse(refusal) }
            args["tab"] = .string(tab)
            if tool == "navigate" {
                // A navigation never opens a stray background tab: it goes to the bound tab, created in the group.
                args.removeValue(forKey: "group")
            }
            let ensure = binding.owns(tab) && !context.sharedWithMe.contains(tab)
            return .forward(tool: tool, arguments: .object(args), tab: tab, shared: isShared(tab), ensure: ensure, remember: nil)
        }
    }

    /// Learns numeric → string tab IDs from a result's JSON text (`"tab":123,…,"id":"bc-…"` objects).
    public static func learnTabIDs(from text: String) -> [Int: String] {
        guard let data = text.data(using: .utf8), let value = try? JSONValue.parse(data) else { return [:] }
        var out: [Int: String] = [:]
        func walk(_ value: JSONValue) {
            switch value {
            case .object(let object):
                if case .number(let n)? = object["tab"], case .string(let id)? = object["id"] { out[Int(n)] = id }
                object.values.forEach(walk)
            case .array(let items): items.forEach(walk)
            default: break
            }
        }
        walk(value)
        return out
    }
}
