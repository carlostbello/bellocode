import AppKit
import BelloCore
import QuartzCore

/// The streaming state of one assistant text row: incremental Markdown plus cached layouts of its finished blocks.
final class TailState {
    let id: RowID
    var stream = MarkdownStream()
    /// Layouts of `stream.blocks`, index-aligned; the prefix that did not change is reused across commits.
    var blockLayouts: [BlockLayout] = []
    var composed: RowLayout?
    /// The row version whose text the composed layout shows (part of the layout key while streaming).
    var keyVersion = 0
    var pendingText: String?
    var pendingVersion = 0
    var pendingFinished = false
    var task: Task<Void, Never>?
    var jobInFlight = false
    var finished = false
    /// UTF-8 length of the text shown (after line buffering), for delta→visible measurements.
    var displayedLength = 0
    /// UTF-8 length of the text received and parsed (before line buffering).
    var appliedLength = 0

    init(id: RowID) { self.id = id }

    func reset() {
        stream = MarkdownStream()
        blockLayouts = []
    }
}

/// One tail job's output, handed back with `sending`.
final class TailJobResult {
    var stream = MarkdownStream()
    var unchanged = 0
    var layouts: [BlockLayout] = []
    var blocks: [RenderBlock] = []
}

extension TranscriptController {
    /// Applies new text to a streaming row: the job re-parses from the last top-level block and lays out only the
    /// blocks that changed. One job runs at a time per row; the latest text wins.
    func updateTail(row: TranscriptRow, text: String, finished: Bool) {
        let tail = tails[row.id] ?? {
            let state = TailState(id: row.id)
            state.keyVersion = row.version
            tails[row.id] = state
            return state
        }()
        tail.pendingText = text
        tail.pendingVersion = row.version
        tail.pendingFinished = finished
        if !tail.jobInFlight { startTailJob(tail) }
    }

    func relayoutTails() {
        for tail in tails.values {
            tail.reset()
            guard let index = rowIndex[tail.id], case .markdown(let text, let streaming) = rows[index].content else { continue }
            updateTail(row: rows[index], text: text, finished: !streaming)
        }
    }

    func startTailJob(_ tail: TailState) {
        guard let text = tail.pendingText, let index = rowIndex[tail.id] else { return }
        tail.pendingText = nil
        tail.jobInFlight = true
        let version = tail.pendingVersion
        let finished = tail.pendingFinished
        let stream = tail.stream
        let width = contentWidth
        let theme = self.theme
        let highlighter = self.highlighter
        let ui = self.ui[tail.id] ?? RowUIState()
        let content = rows[index].content
        let sizes = imageSizes(for: rows[index])
        let generation = self.generation
        metrics.tailJobs += 1
        tail.task = Task { [weak self] in
            let result = await Self.tailJob(
                stream: stream, text: text, finished: finished, content: content, ui: ui, width: width, theme: theme,
                imageSizes: sizes, highlighter: highlighter)
            guard !Task.isCancelled, let self else { return }
            self.applyTailJob(result, tail: tail, version: version, finished: finished, text: text, generation: generation)
        }
    }

    @concurrent
    static func tailJob(
        stream: MarkdownStream, text: String, finished: Bool, content: RowContent, ui: RowUIState, width: CGFloat,
        theme: TranscriptTheme, imageSizes: [String: CGSize], highlighter: any HighlightService
    ) async -> sending TailJobResult {
        let signpost = transcriptSignposter.beginInterval("tailJob")
        defer { transcriptSignposter.endInterval("tailJob", signpost) }
        var stream = stream
        let unchanged = finished ? stream.finish(text) : stream.update(text)
        let result = TailJobResult()
        result.blocks = stream.blocks.map { RenderBlock(.markdown($0, tone: .normal)) }
        result.unchanged = min(unchanged, result.blocks.count)
        result.layouts = LayoutEngine.layoutBlocks(
            Array(result.blocks[result.unchanged...]), content: content, ui: ui, imageSizes: imageSizes, width: width,
            fonts: TranscriptFonts(theme: theme), highlighter: highlighter)
        result.stream = stream
        return result
    }

    func applyTailJob(_ result: TailJobResult, tail: TailState, version: Int, finished: Bool, text: String, generation: Int) {
        tail.jobInFlight = false
        guard tails[tail.id] === tail, let index = rowIndex[tail.id] else { return }
        guard generation == self.generation else {
            // Width or theme changed meanwhile: redo from scratch with the current state.
            tail.reset()
            if tail.pendingText == nil {
                tail.pendingText = text
                tail.pendingVersion = version
                tail.pendingFinished = finished
            }
            startTailJob(tail)
            return
        }
        let start = CACurrentMediaTime()
        let signpost = transcriptSignposter.beginInterval("tailApply")
        defer { transcriptSignposter.endInterval("tailApply", signpost) }
        let reused = Array(tail.blockLayouts.prefix(result.unchanged))
        guard reused.count == result.unchanged else {
            // The cached prefix no longer matches (reset meanwhile): lay out everything again.
            tail.reset()
            tail.pendingText = tail.pendingText ?? text
            tail.pendingVersion = max(tail.pendingVersion, version)
            tail.pendingFinished = tail.pendingFinished || finished
            startTailJob(tail)
            return
        }
        tail.stream = result.stream
        tail.blockLayouts = reused + result.layouts
        tail.keyVersion = version
        tail.displayedLength = result.stream.displayed.utf8.count
        tail.appliedLength = text.utf8.count
        let key = currentKey(row: index)
        let layout = RowLayout(key: key, blocks: tail.blockLayouts, width: contentWidth, topPadding: topPadding(index), theme: theme)
        tail.composed = layout
        store(layout)
        heightKeys[index] = layout.key
        if let view = cellView(index) {
            let firstChanged = result.unchanged
            let dirtyTop = firstChanged < layout.origins.count ? layout.origins[firstChanged].y : 0
            view.layout = layout
            view.drawState = drawState(for: index)
            view.updateCanvas()
            view.invalidate(CGRect(x: 0, y: dirtyTop - 2, width: view.bounds.width, height: max(layout.height, view.bounds.height) - dirtyTop + 4))
        }
        if abs(heights[index] - layout.height) > 0.25 {
            pendingHeights[tail.id] = layout.height
            flushHeights()
        }
        metrics.maxTailApplyMilliseconds = max(metrics.maxTailApplyMilliseconds, (CACurrentMediaTime() - start) * 1000)
        onTailCommit?(tail.id)
        if finished, tail.pendingText == nil {
            // Reconciled: the finished parse becomes the row's cached blocks and its layout the normal one.
            blockCache.store(result.stream.blocks.map { RenderBlock(.markdown($0, tone: .normal)) }, for: rows[index])
            tails[tail.id] = nil
            let finalKey = currentKey(row: index)
            let final = RowLayout(key: finalKey, blocks: tail.blockLayouts, width: contentWidth, topPadding: topPadding(index), theme: theme)
            store(final)
            heightKeys[index] = finalKey
            if let view = cellView(index) { view.layout = final }
            invalidateFind(rows: [tail.id])
            return
        }
        if tail.pendingText != nil { startTailJob(tail) }
    }

    /// The displayed UTF-8 length of a streaming row (harness: delta→visible latency).
    public func displayedTailLength(_ id: RowID) -> Int? { tails[id]?.displayedLength }

    /// The received UTF-8 length of a streaming row's last commit (before line buffering).
    public func appliedTailLength(_ id: RowID) -> Int? { tails[id]?.appliedLength }

    /// The streaming rows.
    public var streamingRowIDs: [RowID] { Array(tails.keys) }

    // MARK: Announcements

    /// Announces a completed assistant reply once (never per token), for VoiceOver.
    func noteStreamingTransitions(_ dirty: Set<MessageID>, source: any TranscriptSource) {
        for id in dirty {
            guard let message = source.transcriptMessage(id), case .assistant = message.kind else { continue }
            if message.isStreaming {
                streamingSeen.insert(id)
                continue
            }
            guard streamingSeen.remove(id) != nil, !announced.contains(id) else { continue }
            let text = message.parts.compactMap { if case .text(let text) = $0.content { text } else { nil } }.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            announced.insert(id)
            announcedOrder.append(id)
            if announcedOrder.count > 256 { announced.remove(announcedOrder.removeFirst()) }
            announce(text)
        }
    }
}
