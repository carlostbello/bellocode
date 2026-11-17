import Foundation
import TranscriptKit

/// M3 (docs/reviews/M2-M4-review.md): the main-actor cost of each streaming commit against history length.
///
///   .build/release/TranscriptDemo --scenario stream-cost --large 1000 --rate 150 --stream-seconds 12
///
/// Streams a reply into the tail of a fully loaded history (MockOpenCode `.large`, `--large` messages) and records
/// every transcript sync: wall time, main-thread CPU time and the rows it touched. Report:
/// build/transcript-bench/stream-cost-<messages>.json.
extension ScenarioRunner {
    struct StreamCostReport: Codable {
        var header: RunHeader
        var rows: Int
        var ratePerSecond: Double
        var syncs: Int
        var tailOnlySyncs: Int
        var wallMs: Percentiles
        var cpuMicroseconds: Percentiles
        var rowWork: Percentiles
        var nonTail: [Sample]
        var frames: FrameStats
        var deltasShown: Int
        var finalTextMatches: Bool
    }

    struct Sample: Codable {
        var wallMs: Double
        var cpuMicroseconds: Double
        var rowWork: Int
    }

    struct Percentiles: Codable {
        var p50 = 0.0
        var p95 = 0.0
        var max = 0.0
        var mean = 0.0

        init(_ values: [Double]) {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return }
            func p(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
            p50 = round2(p(0.5))
            p95 = round2(p(0.95))
            max = round2(sorted.last!)
            mean = round2(sorted.reduce(0, +) / Double(sorted.count))
        }
    }

    func runStreamCost() async {
        await mountFull()
        guard let controller else { return }
        controller.jumpToLatest()
        await sleep(0.5)
        var samples: [TranscriptController.SyncSample] = []
        controller.onSync = { samples.append($0) }
        let stats = await stream(seconds: streamSeconds)
        controller.onSync = nil
        let tail = samples.filter(\.tailOnly)
        let report = StreamCostReport(
            header: header("stream-cost"), rows: controller.rows.count, ratePerSecond: streamRate, syncs: samples.count,
            tailOnlySyncs: tail.count, wallMs: Percentiles(tail.map(\.milliseconds)),
            cpuMicroseconds: Percentiles(tail.map(\.cpuMicroseconds)), rowWork: Percentiles(tail.map { Double($0.rowWork) }),
            nonTail: samples.filter { !$0.tailOnly }.map { Sample(wallMs: round2($0.milliseconds), cpuMicroseconds: round2($0.cpuMicroseconds), rowWork: $0.rowWork) },
            frames: stats.frames, deltasShown: stats.deltasShown, finalTextMatches: stats.finalTextMatches)
        Report.write(report, name: "stream-cost-\(messageCount)")
        log(
            "stream-cost \(messageCount) messages, \(controller.rows.count) rows: \(tail.count) tail syncs; wall p50/p95/max "
                + "\(report.wallMs.p50)/\(report.wallMs.p95)/\(report.wallMs.max) ms; CPU p50/p95 \(report.cpuMicroseconds.p50)/\(report.cpuMicroseconds.p95) µs; "
                + "rowWork p50/max \(report.rowWork.p50)/\(report.rowWork.max); other syncs \(samples.count - tail.count)")
    }
}
