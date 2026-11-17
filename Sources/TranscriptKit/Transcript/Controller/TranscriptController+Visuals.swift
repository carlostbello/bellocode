import AppKit

// HTML visuals (docs/features/orchestration-extras.md): the transcript draws each visual's snapshot like an image; the
// host may lay a bounded number of live views over the visuals on screen, using these frames. Additive: no change to
// layout or drawing.

extension TranscriptController {
    /// Visual images on screen, in `tableView` coordinates, ordered by how much of each is visible (most first).
    public func visibleVisualFrames() -> [(visualID: String, frame: CGRect)] {
        let visible = tableView.visibleRect
        var result: [(String, CGRect, CGFloat)] = []
        for (index, view) in visibleCells() {
            guard case .visual(let visual) = rows[index].content, visual.status == .ready, let layout = view.layout else { continue }
            for (block, origin) in zip(layout.blocks, layout.origins) {
                guard let image = block.images.first, image.source.hasPrefix(VisualCardContent.scheme + "://") else { continue }
                let column = view.columnFrame()
                let local = image.rect.offsetBy(dx: column.x + TranscriptCellView.gutter + origin.x, dy: origin.y)
                let frame = view.convert(local, to: tableView)
                let shown = frame.intersection(visible)
                if !shown.isNull, shown.height > 0 { result.append((visual.visualID, frame, shown.height)) }
            }
        }
        return result.sorted { $0.2 > $1.2 }.map { ($0.0, $0.1) }
    }
}
