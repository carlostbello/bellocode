import BelloCore
import Foundation

/// Merges a message fetched from a list endpoint with the copy the projection already holds.
///
/// The server copy wins, except where the local copy is provably ahead of it: a resync snapshot can be taken while a
/// turn streams, so it may predate deltas and events already applied. Local text that extends the server's text, a tool
/// call further along its state machine, and a step the local copy already closed are kept. Anything else (an edit or
/// revert on the server) takes the server's version. `revision` increases only if the result differs from the local copy.
enum SnapshotMerge {
    static func message(local: Message?, server: Message) -> Message {
        guard let local else { return server }
        var merged = server
        merged.delivery = local.delivery.map { _ in .delivered }

        if case .assistant(let localInfo) = local.kind, case .assistant(var serverInfo) = server.kind {
            if !localInfo.isOpen, serverInfo.isOpen {
                serverInfo = localInfo
                merged.completed = merged.completed ?? local.completed
            }
            merged.kind = .assistant(serverInfo)
        }
        let open: Bool = if case .assistant(let info) = merged.kind { info.isOpen } else { false }

        let localParts = Dictionary(local.parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var parts: [Part] = []
        for serverPart in server.parts {
            guard let localPart = localParts[serverPart.id] else {
                parts.append(serverPart)
                continue
            }
            parts.append(part(local: localPart, server: serverPart, open: open))
        }
        if open {
            // Blocks that started after the snapshot was taken.
            let known = Set(server.parts.map(\.id))
            for localPart in local.parts where !known.contains(localPart.id) {
                var extra = localPart
                extra.index = parts.count
                parts.append(extra)
            }
        }
        if !open {
            for index in parts.indices { parts[index].isStreaming = false }
        }
        merged.parts = parts

        var comparable = merged
        comparable.revision = local.revision
        merged.revision = comparable == local ? local.revision : local.revision + 1
        return merged
    }

    private static func part(local: Part, server: Part, open: Bool) -> Part {
        var result = server
        switch (local.content, server.content) {
        case (.text(let mine), .text(let theirs)) where mine.count > theirs.count && mine.hasPrefix(theirs):
            result.content = .text(mine)
            result.isStreaming = local.isStreaming && open
        case (.reasoning(let mine), .reasoning(let theirs)) where mine.count > theirs.count && mine.hasPrefix(theirs):
            result.content = .reasoning(mine)
            result.isStreaming = local.isStreaming && open
        case (.text, .text), (.reasoning, .reasoning):
            if !local.isStreaming { result.isStreaming = false }
        default:
            if let mine = local.content.toolCall, let theirs = server.content.toolCall, mine.status.rank > theirs.status.rank {
                result.content = local.content
            }
        }
        result.index = server.index
        return result
    }
}
