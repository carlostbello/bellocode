// G1-A spike: streaming tail. A producer emits 1–16 character deltas at a fixed rate; a coalescer commits at most
// every `commitInterval`; the tail parser re-parses only from the last committed block boundary, so finished blocks
// are never re-parsed or re-sent. Parsing runs on this actor (off the main actor); only the splice runs on main.

import Foundation
import QuartzCore

public actor SpikeStreamPipeline {
    public struct Stats: Sendable {
        public var deltas = 0
        public var commits = 0
        public var bytes = 0
        public var parseMS: [Double] = []
    }

    private let script: [Character]
    private var cursor = 0
    private var rng: SpikeRNG
    private var source = ""
    private var pendingStamps: [Double] = []
    private var parser = SpikeTailParser()
    private var producing = true
    public private(set) var stats = Stats()
    /// The full streamed Markdown so far (for the end-of-stream equivalence check).
    public var streamedSource: String { source }

    public init(script: String, seed: UInt64 = 7) {
        self.script = Array(script)
        rng = SpikeRNG(seed: seed)
    }

    /// Streams for `duration` seconds at `rate` deltas per second, committing every `commitInterval` seconds.
    public func run(into controller: SpikeTranscriptController, generation: Int, rate: Double = 100,
                    duration: Double = 60, commitInterval: Double = 0.033) async {
        producing = true
        async let produced: Void = produce(rate: rate, duration: duration)
        async let committed: Void = commitLoop(controller: controller, generation: generation, interval: commitInterval)
        _ = await (produced, committed)
    }

    private func produce(rate: Double, duration: Double) async {
        let clock = ContinuousClock()
        let start = clock.now
        let step = Duration.seconds(1 / rate)
        var next = start
        let end = start + .seconds(duration)
        while clock.now < end, !Task.isCancelled {
            next += step
            try? await clock.sleep(until: next)
            emitDelta()
        }
        producing = false
    }

    private func emitDelta() {
        let size = rng.int(1...16)
        if cursor >= script.count { cursor = 0 }
        let end = min(script.count, cursor + size)
        source.append(contentsOf: script[cursor..<end])
        stats.bytes += end - cursor
        cursor = end
        pendingStamps.append(CACurrentMediaTime())
        stats.deltas += 1
    }

    private func commitLoop(controller: SpikeTranscriptController, generation: Int, interval: Double) async {
        let clock = ContinuousClock()
        var next = clock.now
        while !Task.isCancelled {
            next += .seconds(interval)
            try? await clock.sleep(until: next)
            let done = !producing
            if !pendingStamps.isEmpty, let update = makeUpdate(generation: generation) {
                stats.commits += 1
                await controller.applyTail(update)
            }
            if done && pendingStamps.isEmpty { break }
        }
    }

    private func makeUpdate(generation: Int) -> SpikeTailUpdate? {
        let started = CACurrentMediaTime()
        let (replaceFrom, rich) = parser.update(source: source)
        let update = SpikeTailUpdate(generation: generation, replaceFrom: replaceFrom, rich: rich, deltaStamps: pendingStamps)
        pendingStamps.removeAll(keepingCapacity: true)
        stats.parseMS.append((CACurrentMediaTime() - started) * 1_000)
        return update
    }
}

/// Tail-only incremental Markdown: blocks that are closed and followed by another block are committed and never
/// parsed again; each update re-parses from the last committed block boundary and says where (UTF-16, relative to
/// the message body) the view's text must be replaced from.
public struct SpikeTailParser: Sendable {
    private var committedSourceOffset = 0 // UTF-8 offset in the source of the first uncommitted block
    private var committedRenderedLength = 0 // UTF-16 length of committed rendered blocks

    public init() {}

    public mutating func update(source: String) -> (replaceFrom: Int, rich: SpikeRich) {
        let utf8 = source.utf8
        let tail = source[utf8.index(utf8.startIndex, offsetBy: committedSourceOffset)...]
        let blocks = SpikeMarkdown.blocks(tail)
        var rich = SpikeRich()
        var newSourceOffset = committedSourceOffset
        var newRenderedLength = committedRenderedLength
        var allClosed = true
        for (i, block) in blocks.enumerated() {
            SpikeMarkdown.render(block, into: &rich)
            if allClosed, block.closed, i < blocks.count - 1 {
                newSourceOffset = committedSourceOffset + block.sourceEnd
                newRenderedLength = committedRenderedLength + rich.length
            } else {
                allClosed = false
            }
        }
        let replaceFrom = committedRenderedLength
        committedSourceOffset = newSourceOffset
        committedRenderedLength = newRenderedLength
        return (replaceFrom, rich)
    }
}
