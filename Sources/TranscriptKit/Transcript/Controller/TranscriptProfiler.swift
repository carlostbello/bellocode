import QuartzCore
import os

/// In-process attribution of the transcript's main-thread time by phase (harness and tests). Off by default: a probe
/// then costs one branch. Phases nest; each records its *exclusive* time (a sync layout inside `configure` counts as
/// `syncLayout`, not twice). The harness calls `takeFrame()` once per display frame and attributes slow frames.
/// Every phase is also an `os_signpost` interval (`transcriptSignposter`), so Instruments sees the same breakdown.
@MainActor
public final class TranscriptProfiler {
    public static let shared = TranscriptProfiler()

    public enum Phase: Int, CaseIterable, Sendable, Codable {
        /// `tableView(_:viewFor:row:)` outside `configure`: making or dequeuing a cell view.
        case viewCreation
        /// Applying a layout and state to a cell (`configure`), excluding nested phases.
        case configure
        /// Accessibility label, value and actions of a configured cell.
        case accessibility
        /// A layout computed on the main thread because none was ready.
        case syncLayout
        /// An async layout arriving: store, height acceptance, re-configure.
        case layoutApply
        /// CoreText drawing of a canvas.
        case draw
        /// Height changes applied to the table (`noteHeightOfRows`, forced geometry, anchoring).
        case heightFlush
        /// Layout cache eviction (including deallocation of evicted layouts).
        case eviction
        /// Prefetch planning and layout requests.
        case prefetch
        /// Scroll bookkeeping: bounds change handling, tall-row canvas moves.
        case scroll

        public var name: String {
            switch self {
            case .viewCreation: "viewCreation"
            case .configure: "configure"
            case .accessibility: "accessibility"
            case .syncLayout: "syncLayout"
            case .layoutApply: "layoutApply"
            case .draw: "draw"
            case .heightFlush: "heightFlush"
            case .eviction: "eviction"
            case .prefetch: "prefetch"
            case .scroll: "scroll"
            }
        }
    }

    public var isEnabled = false
    private var frame = [Double](repeating: 0, count: Phase.allCases.count)
    private var stack: [(phase: Phase, start: CFTimeInterval, child: CFTimeInterval)] = []
    /// Event counts since the last `resetCounters()` (views created, layouts evicted…).
    public private(set) var counters: [String: Int] = [:]

    public init() {}

    /// Runs `body`, charging its exclusive main-thread time to `phase` when enabled.
    @inline(__always)
    public func measure<T>(_ phase: Phase, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let signpost = transcriptSignposter.beginInterval("phase", "\(phase.name, privacy: .public)")
        stack.append((phase, CACurrentMediaTime(), 0))
        defer {
            let entry = stack.removeLast()
            let total = CACurrentMediaTime() - entry.start
            frame[phase.rawValue] += max(0, total - entry.child)
            if !stack.isEmpty { stack[stack.count - 1].child += total }
            transcriptSignposter.endInterval("phase", signpost)
        }
        return try body()
    }

    public func count(_ name: String, _ amount: Int = 1) {
        guard isEnabled else { return }
        counters[name, default: 0] += amount
    }

    /// Milliseconds per phase since the previous call, indexed by `Phase.rawValue`.
    public func takeFrame() -> [Double] {
        let result = frame.map { $0 * 1000 }
        for index in frame.indices { frame[index] = 0 }
        return result
    }

    public func resetCounters() { counters.removeAll() }
}
