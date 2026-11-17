import BelloCore
import Foundation

/// What can be expanded or collapsed inside a row.
public enum ExpansionKey: Hashable, Sendable {
    case reasoning
    case group
    case tool(PartID)
}

/// Per-row presentation state that changes layout but not content. Lives in the controller, outside reusable views.
public struct RowUIState: Sendable, Equatable {
    /// Explicit choices; keys without one use the content's default.
    public var overrides: [ExpansionKey: Bool] = [:]
    /// Bumped on every change; part of the layout cache key.
    public var version = 0

    public init() {}
}

/// One addressable block of a row. A row's block list depends only on its content, never on what is expanded, so a
/// position (row, block, offset) stays valid across expansion; collapsed blocks lay out at zero height.
public struct RenderBlock: Sendable, Equatable {
    public enum Tone: Sendable, Hashable { case normal, muted }

    public enum Kind: Sendable, Equatable {
        case markdown(MarkdownBlock, tone: Tone)
        case user(UserRowContent)
        case groupSummary(WorkGroupContent)
        case toolHeader(ToolItem)
        case toolDetail(ToolItem)
        case reasoningHeader(ReasoningContent)
        case todo(TodoListContent)
        case file(FileChip)
        case subagent(SubagentCardContent)
        case error(ErrorBannerContent)
        case lifecycle(LifecycleContent)
        case working
        case unknown(String)
    }

    public enum Visibility: Sendable, Hashable {
        case always
        /// Shown when `key` is expanded.
        case expanded(ExpansionKey)
    }

    public var kind: Kind
    public var visibility: Visibility

    public init(_ kind: Kind, visibility: Visibility = .always) {
        self.kind = kind
        self.visibility = visibility
    }

    /// The block's full text for find and for copy when it is shown. Must equal what layout makes selectable.
    public var plainText: String {
        switch kind {
        case .markdown(let block, _): block.plainText
        case .user(let user): user.text
        case .groupSummary(let group): RenderBlocks.summaryText(group)
        case .toolHeader(let item): RenderBlocks.headerText(item)
        case .toolDetail(let item): RenderBlocks.detailText(item)
        case .reasoningHeader(let reasoning): RenderBlocks.reasoningText(reasoning)
        case .todo(let list): RenderBlocks.todoText(list)
        case .file(let file): file.name
        case .subagent(let card): RenderBlocks.subagentText(card)
        case .error(let error): error.title + "\n" + error.message
        case .lifecycle(let event): event.text
        case .working: "Working…"
        case .unknown(let type): "Unsupported content (\(type))"
        }
    }

    public var isCollapsibleHeader: ExpansionKey? {
        switch kind {
        case .groupSummary: .group
        case .toolHeader(let item): .tool(item.id)
        case .reasoningHeader: .reasoning
        default: nil
        }
    }
}

public enum RenderBlocks {
    /// The blocks of a row, in order. Markdown is parsed here (callers cache by row ID and version).
    public static func blocks(for row: TranscriptRow, markdown: [MarkdownBlock]? = nil) -> [RenderBlock] {
        switch row.content {
        case .user(let user):
            return [RenderBlock(.user(user))]
        case .markdown(let text, _):
            return (markdown ?? MarkdownParser.blocks(text)).map { RenderBlock(.markdown($0, tone: .normal)) }
        case .reasoning(let reasoning):
            var blocks = [RenderBlock(.reasoningHeader(reasoning))]
            let body = markdown ?? MarkdownParser.blocks(reasoning.text)
            blocks += body.map { RenderBlock(.markdown($0, tone: .muted), visibility: .expanded(.reasoning)) }
            return blocks
        case .work(let group):
            var blocks: [RenderBlock] = []
            let collapsible = group.isCollapsible
            if collapsible { blocks.append(RenderBlock(.groupSummary(group))) }
            for item in group.items {
                // Successful calls hide behind the summary; failures and running calls always show.
                let header: RenderBlock.Visibility = collapsible && item.status.isSuccess ? .expanded(.group) : .always
                blocks.append(RenderBlock(.toolHeader(item), visibility: header))
                if !item.input.isEmpty || !item.output.isEmpty {
                    blocks.append(RenderBlock(.toolDetail(item), visibility: .expanded(.tool(item.id))))
                }
            }
            return blocks
        case .todo(let list): return [RenderBlock(.todo(list))]
        case .file(let file): return [RenderBlock(.file(file))]
        case .subagent(let card): return [RenderBlock(.subagent(card))]
        case .error(let error): return [RenderBlock(.error(error))]
        case .lifecycle(let event): return [RenderBlock(.lifecycle(event))]
        case .working: return [RenderBlock(.working)]
        case .unknown(let type): return [RenderBlock(.unknown(type))]
        }
    }

    /// The default expansion of `key` for a row's content.
    public static func defaultExpanded(_ key: ExpansionKey, content: RowContent) -> Bool {
        switch key {
        case .reasoning: return false
        case .group: return false
        case .tool(let id):
            // Live output shows while the call runs.
            guard case .work(let group) = content, let item = group.items.first(where: { $0.id == id }) else { return false }
            return item.status.isActive && !item.output.isEmpty
        }
    }

    public static func isExpanded(_ key: ExpansionKey, content: RowContent, ui: RowUIState) -> Bool {
        ui.overrides[key] ?? defaultExpanded(key, content: content)
    }

    public static func isVisible(_ block: RenderBlock, content: RowContent, ui: RowUIState) -> Bool {
        switch block.visibility {
        case .always: true
        case .expanded(let key): isExpanded(key, content: content, ui: ui)
        }
    }

    // MARK: Texts (shared by layout and copy so they always agree)

    static func summaryText(_ group: WorkGroupContent) -> String {
        var text = group.summary
        let failures = group.items.filter { if case .failed = $0.status { true } else { false } }.count
        if failures > 0 { text += failures == 1 ? ", 1 failed" : ", \(failures) failed" }
        if let duration = group.duration { text += " · " + DurationText.format(duration) }
        return text
    }

    static func headerText(_ item: ToolItem) -> String {
        var text = item.title
        switch item.status {
        case .done: break
        case .failed: text += " · Failed"
        case .preparing, .running: text += "…"  // the progressive verb and the glyph say it is running
        case .unknown(let raw): text += " · " + raw
        }
        if let duration = item.duration, !item.status.isActive { text += " · " + DurationText.format(duration) }
        return text
    }

    static func detailText(_ item: ToolItem) -> String {
        switch (item.input.isEmpty, item.output.isEmpty) {
        case (false, false): item.input + "\n\n" + item.output
        case (false, true): item.input
        case (true, false): item.output
        case (true, true): ""
        }
    }

    static func reasoningText(_ reasoning: ReasoningContent) -> String {
        if reasoning.isStreaming { return "Thinking…" }
        if let duration = reasoning.duration { return "Thought for " + DurationText.format(duration) }
        return "Thought"
    }

    static func todoText(_ list: TodoListContent) -> String {
        let done = list.items.filter { $0.state == .completed }.count
        var lines = ["To-dos · \(done) of \(list.items.count) done"]
        for item in list.items {
            let glyph: String =
                switch item.state {
                case .completed: "☑"
                case .inProgress: "◐"
                case .pending: "☐"
                case .cancelled: "☒"
                }
            lines.append(glyph + " " + item.text)
        }
        return lines.joined(separator: "\n")
    }

    static func subagentText(_ card: SubagentCardContent) -> String {
        var detail = [card.agent.map { "@" + $0 } ?? "Sub-agent", card.status.label]
        if let duration = card.duration { detail.append(DurationText.format(duration)) }
        return card.title + "\n" + detail.joined(separator: " · ")
    }
}
