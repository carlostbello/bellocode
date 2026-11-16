// G5 spike: a substitute frame clock for runs where the Mac is locked or its display is asleep. SwiftTerm suspends
// its display-link frame driver while the window is occluded (correct product behaviour), so neither frames nor
// snapshots happen. Built with
//   swift build -c release --product TerminalSpike -Xswiftc -enable-testing -Xswiftc -DSPIKE_FORCE_FRAMES
// this clock calls SwiftTerm's internal `frameTick()` and forces the CoreGraphics draw at 60 Hz on the main thread,
// timing the work. It approximates the main-thread cost of rendering (not WindowServer compositing). Without the
// flag it is inert and `available` is false.

import AppKit
import Foundation
import QuartzCore
import TerminalKit
#if SPIKE_FORCE_FRAMES
@testable import SwiftTerm
#else
import SwiftTerm
#endif

@MainActor
final class ForcedFrameClock: NSObject {
    static var available: Bool {
        #if SPIKE_FORCE_FRAMES
        true
        #else
        false
        #endif
    }

    private var timer: Timer?
    private weak var view: TerminalView?
    private var last: CFTimeInterval = 0
    private(set) var intervals: [Double] = []
    private(set) var work: [Double] = []

    func start(_ view: TerminalView) {
        guard Self.available else { return }
        self.view = view
        intervals.removeAll()
        work.removeAll()
        last = 0
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Renders one frame now (used before snapshots).
    static func renderOnce(_ view: TerminalView) {
        #if SPIKE_FORCE_FRAMES
        view.frameTick()
        view.display()
        #endif
    }

    @objc private func tick() {
        guard let view else { return }
        let start = CACurrentMediaTime()
        if last > 0 { intervals.append((start - last) * 1000) }
        last = start
        Self.renderOnce(view)
        work.append((CACurrentMediaTime() - start) * 1000)
    }

    func stop() -> (intervals: SpikeStats, work: SpikeStats, intervalsOver33ms: Int, intervalsOver50ms: Int) {
        timer?.invalidate()
        timer = nil
        return (SpikeStats(intervals), SpikeStats(work), intervals.count { $0 > 33.4 }, intervals.count { $0 > 50 })
    }
}
