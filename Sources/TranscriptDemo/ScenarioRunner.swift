import AppKit
import BelloCore
import Engine
import MockOpenCode
import OpenCodeKit
import QuartzCore
import Synchronization
import TranscriptKit

/// S1–S8 from docs/spikes/G1-B-rows.md, run on the production transcript fed by the Engine against MockOpenCodeServer
/// (`.large`: one 10,000-message session with a 100 KB code block). Reports: build/transcript-bench/<scenario>.json.
@MainActor
final class ScenarioRunner {
    let window: NSWindow
    let arguments: [String]
    var recorder: FrameRecorder!
    let watchdog = Watchdog()
    var nominal = 1.0 / 120
    var rng = SplitMix(seed: 42)
    var scrollSpeed = 3.0
    var streamSeconds = 60.0
    var messageCount = 10_000

    var server: MockOpenCodeServer?
    var engine: Engine?
    var sessionID: SessionID?
    var thread: ThreadModel?
    var viewController: TranscriptViewController?
    var controller: TranscriptController? { viewController?.controller }
    let images = ImageGate()

    init(window: NSWindow, arguments: [String]) {
        self.window = window
        self.arguments = arguments
        func option(_ name: String) -> Double? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil }
        }
        scrollSpeed = option("--scroll-speed") ?? 3
        streamSeconds = option("--stream-seconds") ?? 60
        messageCount = Int(option("--large") ?? 10_000)
    }

    // MARK: Setup

    func setUp() async -> Bool {
        window.setFrame(NSRect(x: 80, y: 80, width: 900, height: 900), display: false)
        window.contentView = NSView()
        window.orderFrontRegardless()
        recorder = FrameRecorder(view: window.contentView!)
        await recorder.frames(30)
        nominal = 1.0 / Double(max(60, window.screen?.maximumFramesPerSecond ?? 120))
        let started = CACurrentMediaTime()
        var scenario = FixtureGenerator(seed: 42).workspace(projectCount: 2, sessionCount: 12, messagesPerSession: 6)
        let large = FixtureGenerator(seed: 42).addLargeSession(to: &scenario, messageCount: messageCount)
        let server = MockOpenCodeServer(scenario: scenario, options: MockServerOptions(clock: .realTime))
        do {
            let endpoint = try await server.start()
            let connection = ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? ""))
            let engine = try Engine(configuration: EngineConfiguration(server: .fixed(connection), store: .inMemory))
            await engine.start()
            self.server = server
            self.engine = engine
            sessionID = SessionID(large)
            var waited = 0
            while engine.root.connection != .live, waited < 400 {
                await sleep(0.05)
                waited += 1
            }
            log("mock + engine live in \(Int((CACurrentMediaTime() - started) * 1000)) ms (\(messageCount) messages)")
            return engine.root.connection == .live
        } catch {
            log("FAIL setup: \(error)")
            return false
        }
    }

    func openThread() async -> ThreadModel? {
        guard let engine, let sessionID else { return nil }
        let thread = engine.openThread(sessionID)
        while thread.phase == .opening { await sleep(0.01) }
        self.thread = thread
        return thread
    }

    /// Pages in the whole history (as the reader scrolling to the top would).
    func loadAll() async -> Double {
        guard let thread else { return 0 }
        let start = CACurrentMediaTime()
        while thread.hasOlder {
            await thread.loadOlder()
            if thread.lastError != nil { break }
        }
        return (CACurrentMediaTime() - start) * 1000
    }

    @discardableResult
    func mount(anchor: TranscriptAnchor? = nil) -> TranscriptViewController {
        let controller = TranscriptController(imageLoader: images)
        let viewController = TranscriptViewController(controller: controller)
        window.contentViewController = viewController
        window.setFrame(NSRect(x: 80, y: 80, width: 900, height: 900), display: true)
        viewController.view.layoutSubtreeIfNeeded()
        self.viewController = viewController
        recorder.invalidate()
        recorder = FrameRecorder(view: viewController.view)
        if let thread { viewController.bind(thread, anchor: anchor) }
        return viewController
    }

    func unmount() {
        viewController?.close()
        window.contentViewController = nil
        viewController = nil
    }

    func tearDown() async {
        unmount()
        thread?.close()
        await engine?.stop()
        await server?.stop()
    }

    // MARK: Helpers

    func sleep(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    func log(_ text: String) {
        FileHandle.standardError.write(Data("[\(String(format: "%.1f", ProcessStats.secondsSinceLaunch()))s] \(text)\n".utf8))
    }

    /// Runs `step(dt, elapsed)` once per display frame until it returns false.
    func perFrame(_ step: @escaping (Double, Double) -> Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var last: Double?
            var start: Double?
            recorder.onFrame = { [weak self] link in
                let t = link.timestamp
                let dt = min(0.1, last.map { t - $0 } ?? (self?.nominal ?? 0.008))
                last = t
                if start == nil { start = t }
                if !step(dt, t - start!) {
                    self?.recorder.onFrame = nil
                    continuation.resume()
                }
            }
        }
    }

    struct Flick {
        var velocity = 0.0
        mutating func step(_ dt: Double, rng: inout SplitMix, scale: Double) -> Double {
            if velocity < 500 { velocity = (4_000 + rng.unit() * 10_000) * scale }
            let distance = velocity * dt
            velocity *= exp(-dt / 0.7)
            return distance
        }
    }

    func waitForMeasureAll(timeout: Double = 60) async {
        guard let controller else { return }
        let start = CACurrentMediaTime()
        while !controller.measureAllComplete, CACurrentMediaTime() - start < timeout { await sleep(0.05) }
        await controller.settle()
    }

    /// The table's document height minus the model's (0 when NSTableView uses our heights exactly).
    func geometryError() -> Double {
        guard let controller, !controller.rows.isEmpty else { return -1 }
        var worst = 0.0
        for index in stride(from: 0, to: controller.rows.count, by: max(1, controller.rows.count / 400)) {
            worst = max(worst, abs(Double(controller.tableOffset(ofRow: index) - controller.modelOffset(ofRow: index))))
        }
        return worst
    }

    /// The row at the top of the viewport and its offset (for drift).
    func topAnchor() -> (RowID, Double)? {
        guard let controller else { return nil }
        let visible = controller.scrollView.contentView.bounds
        let tableRow = controller.tableView.row(at: NSPoint(x: 1, y: visible.minY + 1))
        guard tableRow >= 1, tableRow - 1 < controller.rows.count else { return nil }
        return (controller.rows[tableRow - 1].id, Double(controller.rowRect(tableRow - 1).minY - visible.minY))
    }

    func drift(from before: (RowID, Double)?) -> Double {
        guard let before, let controller, let index = controller.rows.firstIndex(where: { $0.id == before.0 }) else { return -1 }
        let visible = controller.scrollView.contentView.bounds
        return abs(Double(controller.rowRect(index).minY - visible.minY) - before.1)
    }

    func header(_ name: String) -> RunHeader {
        RunHeader(
            scenario: name, date: ISO8601DateFormatter().string(from: Date()), messages: messageCount, nominalMs: round2(nominal * 1000),
            window: "900x900", build: "release", memory: Memory.now())
    }

    // MARK: Run

    func run(_ name: String) async -> Bool {
        guard await setUp(), await openThread() != nil else { return false }
        let order = name == "all" ? ["S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8"] : [name]
        for scenario in order {
            log("— \(scenario)")
            switch scenario {
            case "S1": await runS1()
            case "S2": await runS2()
            case "S3": await runS3()
            case "S4": await runS4()
            case "S5": await runS5()
            case "S6": await runS6()
            case "S7": await runS7()
            case "S8": await runS8()
            default: log("unknown scenario \(scenario)")
            }
            if scenario != "S8" { unmount() }
            await sleep(1)
        }
        await tearDown()
        return true
    }

    /// Mounted with the whole history loaded, measured, at the bottom.
    func mountFull() async {
        if thread?.hasOlder == true { _ = await loadAll() }
        mount()
        await controller?.settle()
        await waitForMeasureAll()
    }
}

// MARK: - Reports

struct RunHeader: Codable {
    var scenario: String
    var date: String
    var messages: Int
    var nominalMs: Double
    var window: String
    var build: String
    var memory: Memory
}

struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// Images arrive only when released (S5 "late image above the viewport"); everything else loads at once.
final class ImageGate: TranscriptImageLoading {
    private struct State {
        var held: Set<String> = []
        var holdAll = false
        var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    }

    private let state = Mutex(State())

    func holdAll(_ value: Bool) { state.withLock { $0.holdAll = value } }

    func release(_ source: String) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.held.insert(source)
            return state.waiting.removeValue(forKey: source) ?? []
        }
        for waiter in waiters { waiter.resume() }
    }

    var pending: [String] { state.withLock { Array($0.waiting.keys) } }

    func load(_ source: String) async -> LoadedImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if !state.holdAll || state.held.contains(source) { return true }
                state.waiting[source, default: []].append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        let width = 640
        let height = 360
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let hash = UInt32(truncatingIfNeeded: source.hashValue)
        context.setFillColor(red: CGFloat(hash & 0xFF) / 255, green: CGFloat((hash >> 8) & 0xFF) / 255, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        return LoadedImage(image: image, pixelSize: CGSize(width: width, height: height))
    }
}
