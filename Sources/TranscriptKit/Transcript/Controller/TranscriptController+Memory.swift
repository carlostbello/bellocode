import AppKit
import Synchronization

/// Sizes of the transcript's caches and views at one moment (harness, tests, regression guards).
public struct TranscriptCacheReport: Sendable, Codable, Equatable {
    public var layoutCount = 0
    /// Layout cost units (see `RowLayout.cost`) and the bound.
    public var layoutCost = 0
    public var layoutCostLimit = 0
    public var parseCacheEntries = 0
    /// Parse cache cost (estimated bytes of parsed blocks) and the bound.
    public var parseCacheCost = 0
    public var parseCacheCostLimit = 0
    public var highlightCacheEntries = 0
    public var highlightCacheCost = 0
    public var findIndexEntries = 0
    /// UTF-16 units held by the find index (original plus folded text).
    public var findIndexUTF16 = 0
    public var imageCount = 0
    public var imageBytes = 0
    /// Cell views AppKit holds for display (visible plus prepared), and all live cell views (including reuse queue).
    public var availableCellViews = 0
    public var liveCellViews = 0
    public var liveRowViews = 0
    /// Estimated bytes of canvas backing stores of the available cell views (width × height × scale² × 4).
    public var canvasBackingBytes = 0
    public var segmentCacheEntries = 0
    public var rows = 0
}

extension TranscriptController {
    public func cacheReport() -> TranscriptCacheReport {
        var report = TranscriptCacheReport()
        report.layoutCount = layouts.count
        report.layoutCost = layoutCacheCost
        report.layoutCostLimit = layoutCacheCostLimit
        let parse = blockCache.statistics
        report.parseCacheEntries = parse.entries
        report.parseCacheCost = parse.cost
        report.parseCacheCostLimit = parse.costLimit
        if let tokenizer = highlighter as? TokenizerHighlighter {
            let stats = tokenizer.statistics
            report.highlightCacheEntries = stats.entries
            report.highlightCacheCost = stats.cost
        }
        report.findIndexEntries = findIndex.count
        report.findIndexUTF16 = findIndex.values.reduce(0) { total, entry in
            total + entry.blocks.reduce(0) { $0 + $1.utf16.count } + entry.folded.reduce(0) { $0 + ($1?.utf16.count ?? 0) }
        }
        report.imageCount = images.count
        report.imageBytes = imageBytes
        let scale = tableView.window?.backingScaleFactor ?? 2
        let cells = availableCells()
        report.availableCellViews = cells.count
        report.liveCellViews = TranscriptCellView.liveCount.load(ordering: .relaxed)
        report.liveRowViews = TranscriptRowView.liveCount.load(ordering: .relaxed)
        report.canvasBackingBytes = cells.reduce(0) { total, cell in
            let size = cell.view.canvas.bounds.size
            return total + Int(size.width * scale) * Int(size.height * scale) * 4
        }
        report.segmentCacheEntries = segmentCache.count
        report.rows = rows.count
        return report
    }
}

/// The transcript's caches, for targeted purges (memory pressure, harness attribution).
public enum TranscriptCacheKind: String, CaseIterable, Sendable, Codable {
    case layouts, parse, highlight, images, findIndex
}

extension TranscriptController {
    /// Drops one cache. Layouts of rows AppKit currently displays and streaming tails are kept, so nothing on screen
    /// goes blank; everything else is rebuilt on demand.
    public func purge(_ kind: TranscriptCacheKind) {
        switch kind {
        case .layouts:
            let keep = Set(availableCells().map { rows[$0.index].id })
            for id in Array(layouts.keys) where !keep.contains(id) && tails[id] == nil {
                if let old = layouts.removeValue(forKey: id) { layoutCacheCost -= old.cost }
                layoutTick[id] = nil
            }
        case .parse:
            blockCache.removeAll()
        case .highlight:
            (highlighter as? TokenizerHighlighter)?.removeAll()
        case .images:
            let visible = Set(availableCells().flatMap { cell in
                cell.view.layout?.blocks.flatMap { $0.images.map(\.source) } ?? []
            })
            for source in Array(images.keys) where !visible.contains(source) {
                if let image = images.removeValue(forKey: source) { imageBytes -= image.bytesPerRow * image.height }
                imageRequests.remove(source)
            }
            imageOrder.removeAll { images[$0] == nil }
        case .findIndex:
            findIndex.removeAll()
        }
    }
}
