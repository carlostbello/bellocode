// G1-A ground truth for scroll jumps: snapshot the window after every scroll step and find the vertical pixel
// shift that best aligns consecutive images. A step whose best shift differs from the requested one (or that
// matches no shift) is a visible jump, independent of TextKit's own geometry queries.

import AppKit
import QuartzCore
import TranscriptKit

struct VisualJumpReport: Encodable {
    var environment: Environment
    var steps = 0
    var stepPT = 0.0
    var visibleJumps = 0
    var unmatchedSteps = 0
    var geometryJumpsOver2PT = 0
    var samples: [[String: Double]] = []
}

extension Scenarios {
    /// Per-row signature: mean luminance in 8 column bands, for rows of the text area.
    func signature(_ view: NSView) -> (rows: [[Float]], scale: Double)? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let w = rep.pixelsWide, hgt = rep.pixelsHigh
        guard let data = rep.bitmapData else { return nil }
        let bpr = rep.bytesPerRow, spp = rep.samplesPerPixel
        let bands = 8
        let usable = w - 40 // skip the scroller
        var rows: [[Float]] = []
        rows.reserveCapacity(hgt)
        for y in 0..<hgt {
            var sig = [Float](repeating: 0, count: bands)
            let row = data + y * bpr
            for x in stride(from: 0, to: usable, by: 2) {
                let p = row + x * spp
                sig[x * bands / usable] += Float(p[0]) + Float(p[1]) + Float(p[2])
            }
            rows.append(sig)
        }
        return (rows, Double(rep.pixelsHigh) / Double(view.bounds.height))
    }

    /// Mean abs difference between a[y + shift] and b[y] over the overlap (lower is better).
    func mismatch(_ a: [[Float]], _ b: [[Float]], shift: Int) -> Float {
        let n = a.count - shift
        guard n > 100 else { return .infinity }
        var total: Float = 0
        for y in stride(from: 0, to: n, by: 2) {
            for k in 0..<a[0].count { total += abs(a[y + shift][k] - b[y][k]) }
        }
        return total / Float(n / 2)
    }

    func visualJump() async -> VisualJumpReport {
        await openLoaded()
        var r = VisualJumpReport(environment: environment())
        c.scrollToTop()
        await h.sleep(0.5)
        let step = 50.0
        r.stepPT = step
        let steps = Int(argument("--steps") ?? "") ?? 400
        guard var previous = signature(h.window.contentView!) else { return r }
        var errors: [Float] = []
        var medianError: Float = .infinity
        let scale = previous.scale
        for i in 0..<steps {
            let before = c.captureTopAnchor()
            let clip0 = c.visibleRect.minY
            if let event = h.scrollEvent(deltaY: -step) { c.scrollView.scrollWheel(with: event) }
            // Let AppKit run a display cycle (layout + draw) as it would for a real event.
            await h.sleep(0.02)
            let moved = c.visibleRect.minY - clip0
            guard let current = signature(h.window.contentView!) else { break }
            let expected = Int((moved * scale).rounded())
            var best = (shift: 0, error: Float.infinity)
            for s in stride(from: 0, through: min(600, current.rows.count - 200), by: 1) {
                let e = mismatch(previous.rows, current.rows, shift: s)
                if e < best.error { best = (s, e) }
            }
            let atExpected = mismatch(previous.rows, current.rows, shift: max(0, expected))
            var geometry = 0.0
            if let before, let frame = c.fragmentFrame(at: before.location) {
                geometry = Double(frame.minY - c.visibleRect.minY) - Double(before.screenY - moved)
                if abs(geometry) > 2 { r.geometryJumpsOver2PT += 1 }
            }
            let visible = abs(best.shift - expected) > 2 && best.error < atExpected * 0.8
            // Unmatched: even the best alignment is poor (content changed rather than moved).
            let unmatched = best.error > 4 * max(1, medianError)
            errors.append(best.error)
            if errors.count % 50 == 0 { medianError = errors.sorted()[errors.count / 2] }
            if visible { r.visibleJumps += 1 }
            if unmatched { r.unmatchedSteps += 1 }
            if visible || unmatched || abs(geometry) > 2, r.samples.count < 40, i > 0 {
                r.samples.append(["step": Double(i), "clipY": c.visibleRect.minY, "expectedPx": Double(expected),
                                  "bestPx": Double(best.shift), "bestError": Double(best.error),
                                  "errorAtExpected": Double(atExpected), "geometryDeviationPT": geometry])
                if r.samples.count <= 3 { Output.snapshot(h.window.contentView!, "visual-\(i)") }
            }
            previous = current
            r.steps = i + 1
        }
        return r
    }
}

extension Scenarios {
    /// Pixel ground truth for anchoring: the vertical shift (in points, positive = content moved down on screen)
    /// that best aligns `after` with `before`, searched over ±`maxPT`.
    func pixelShift(_ before: (rows: [[Float]], scale: Double), _ after: (rows: [[Float]], scale: Double),
                    maxPT: Double = 2_000) -> (shiftPT: Double, error: Float, errorAtZero: Float) {
        let limit = min(Int(maxPT * before.scale), before.rows.count - 120)
        var best = (shift: 0, error: Float.infinity)
        var all: [Float] = []
        for s in stride(from: -limit, through: limit, by: 1) {
            // Content moved down by s px: after[y + s] == before[y].
            let e = s >= 0 ? mismatch(after.rows, before.rows, shift: s) : mismatch(before.rows, after.rows, shift: -s)
            all.append(e)
            if e < best.error { best = (s, e) }
        }
        let median = all.sorted()[all.count / 2]
        // No confident match (content replaced rather than moved, or moved further than the window): NaN.
        let confident = best.error < 0.3 * median
        return (confident ? Double(best.shift) / before.scale : .nan, best.error, mismatch(after.rows, before.rows, shift: 0))
    }

    func windowSignature() -> (rows: [[Float]], scale: Double)? { signature(h.window.contentView!) }
}
