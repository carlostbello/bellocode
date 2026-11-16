// G1-A harness: owns the window, the transcript controller and the instruments; drives synthetic input.

import AppKit
import QuartzCore
import TranscriptKit

struct JumpStats: Encodable {
    var events = 0
    var distancePT = 0.0
    /// |content motion − requested motion| per frame, excluding frames clamped at the document ends.
    var deviationsOver1PT = 0
    var deviationsOver2PT = 0
    var maxDeviationPT = 0.0
    var sumAbsDeviationPT = 0.0
    /// Sum of |clip view motion − requested motion| (input fidelity, separate from content jumps).
    var clipShortfallPT = 0.0
    var clipMovedPT = 0.0
    /// The first 25 frames whose visible content moved more than 2 pt away from the requested motion.
    var jumps: [[String: Double]] = []
    var documentHeightStart = 0.0
    var documentHeightEnd = 0.0
    var reachedTarget = false
    var seconds = 0.0
}

@MainActor
final class Harness {
    let transcript: SpikeTranscript
    let generationMS: Double
    private(set) var window: NSWindow!
    private(set) var controller: SpikeTranscriptController!
    let frames = FrameRecorder()
    let watchdog = Watchdog()
    private var eventNumber = 0

    init(transcript: SpikeTranscript, generationMS: Double) {
        self.transcript = transcript
        self.generationMS = generationMS
    }

    var screenRefreshHz: Int { window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 0 }

    // MARK: Window lifecycle

    func makeWindow(width: CGFloat = 1_100, height: CGFloat = 820, autoDeliverImages: Bool = true) {
        let rect = NSRect(x: 80, y: 80, width: width, height: height)
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .resizable, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "G1-A TextKit 2 transcript spike"
        window.isReleasedWhenClosed = false
        let controller = SpikeTranscriptController(frame: NSRect(origin: .zero, size: rect.size))
        controller.autoDeliverImages = autoDeliverImages
        controller.container.autoresizingMask = [.width, .height]
        window.contentView = controller.container
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(controller.textView)
        NSApp.activate()
        frames.attach(to: controller.container)
        self.window = window
        self.controller = controller
    }

    func closeWindow() {
        frames.detach()
        controller?.close()
        window?.contentView = nil
        window?.close()
        controller = nil
        window = nil
    }

    /// Loads the standard transcript. Returns (first content installed, first content frame) in ms from `t0`.
    func load(t0: Double) async -> (installed: Double, firstFrame: Double) {
        var installed = 0.0
        var firstFrame = 0.0
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controller.load(transcript.messages) { [weak self] in
                installed = (CACurrentMediaTime() - t0) * 1_000
                self?.frames.onTick = { [weak self] _ in
                    firstFrame = (CACurrentMediaTime() - t0) * 1_000
                    self?.frames.onTick = nil
                    continuation.resume()
                }
            }
        }
        return (installed, firstFrame)
    }

    func sleep(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    // MARK: Synthetic scroll input

    /// A continuous (trackpad-style, pixel unit) scroll-wheel event. Positive `deltaY` moves toward older content.
    func scrollEvent(deltaY: Double) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: Int32(deltaY.rounded()), wheel2: 0, wheel3: 0) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: deltaY)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: deltaY)
        return NSEvent(cgEvent: cg)
    }

    /// Scrolls with one synthetic wheel event per display frame at `velocity` points per second (positive = toward
    /// the bottom/newer content), measuring how far the visible content deviates from the requested motion.
    func driveScroll(velocity: Double, maxSeconds: Double,
                     stop: @escaping @MainActor (SpikeTranscriptController) -> Bool) async -> JumpStats {
        let controller = controller!
        var stats = JumpStats()
        stats.documentHeightStart = controller.textView.frame.height
        var last: Double?
        var elapsed = 0.0
        var pending: (anchor: SpikeTranscriptController.Anchor, requested: Double, clipBefore: Double)?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            frames.onTick = { [weak self] link in
                guard let self else { return }
                let now = link.timestamp
                // Measure the previous frame's motion now that layout for it has run.
                if let p = pending, let frame = controller.fragmentFrame(at: p.anchor.location) {
                    let clipMoved = controller.visibleRect.minY - p.clipBefore
                    let clamped = abs(clipMoved - p.requested) > 0.5
                        && (controller.visibleRect.minY <= 0.5 || controller.isAtBottom)
                    stats.clipMovedPT += abs(clipMoved)
                    if !clamped { stats.clipShortfallPT += abs(clipMoved - p.requested) }
                    if !clamped {
                        let actualScreenY = frame.minY - controller.visibleRect.minY
                        let expected = p.anchor.screenY - p.requested
                        let deviation = abs(actualScreenY - expected)
                        stats.maxDeviationPT = max(stats.maxDeviationPT, deviation)
                        stats.sumAbsDeviationPT += deviation
                        if deviation > 1 { stats.deviationsOver1PT += 1 }
                        if deviation > 2 {
                            stats.deviationsOver2PT += 1
                            if stats.jumps.count < 25 {
                                stats.jumps.append(["t": elapsed, "clipY": controller.visibleRect.minY, "deviation": actualScreenY - expected,
                                                    "clipMoved": clipMoved, "requested": p.requested,
                                                    "docHeight": controller.textView.frame.height, "anchor": Double(p.anchor.location),
                                                    "topNow": Double(controller.captureTopAnchor()?.location ?? -1),
                                                    "anchorFragmentHeight": frame.height])
                                if arguments.contains("--snap-jumps") {
                                    let ns = controller.storage.string as NSString
                                    let at = Int(p.anchor.location)
                                    log("anchor text: \(ns.substring(with: NSRange(location: at, length: min(80, ns.length - at))).debugDescription)")
                                    if let top = controller.captureTopAnchor() {
                                        log("top text: \(ns.substring(with: NSRange(location: top.location, length: 80)).debugDescription) screenY \(top.screenY)")
                                    }
                                    log("anchor frame now \(frame) clip \(controller.visibleRect)")
                                    Output.snapshot(self.window.contentView!, "jump-\(stats.jumps.count)") }
                            }
                        }
                    }
                }
                pending = nil
                guard let previous = last else { last = now; return }
                let dt = min(0.05, now - previous)
                last = now
                elapsed += dt
                if stop(controller) || elapsed > maxSeconds {
                    stats.reachedTarget = stop(controller)
                    stats.seconds = elapsed
                    stats.documentHeightEnd = controller.textView.frame.height
                    self.frames.onTick = nil
                    continuation.resume()
                    return
                }
                let dy = velocity * dt
                guard let event = self.scrollEvent(deltaY: -dy) else { return }
                if let anchor = controller.captureTopAnchor() {
                    pending = (anchor, dy, controller.visibleRect.minY)
                }
                controller.scrollView.scrollWheel(with: event)
                if arguments.contains("--trace-jumps"), let before = pending?.anchor,
                   let after = controller.fragmentFrame(at: before.location) {
                    let deviation = after.minY - controller.visibleRect.minY - (before.screenY - dy)
                    if abs(deviation) > 100 { log("sync jump in scrollWheel: \(deviation) at clip \(controller.visibleRect.minY)") }
                }
                stats.events += 1
                stats.distancePT += abs(dy)
            }
        }
        return stats
    }

    // MARK: Synthetic mouse input

    func mouseEvent(_ type: NSEvent.EventType, at windowPoint: NSPoint, modifiers: NSEvent.ModifierFlags = [],
                    clickCount: Int = 1) -> NSEvent? {
        eventNumber += 1
        return NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: modifiers,
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                  context: nil, eventNumber: eventNumber, clickCount: clickCount,
                                  pressure: type == .leftMouseUp ? 0 : 1)
    }

    /// A click as AppKit delivers it: mouse-up queued, then mouse-down dispatched (the view's tracking loop
    /// dequeues the mouse-up).
    func click(textViewPoint: NSPoint, modifiers: NSEvent.ModifierFlags = []) {
        let point = controller.textView.convert(textViewPoint, to: nil)
        guard let down = mouseEvent(.leftMouseDown, at: point, modifiers: modifiers),
              let up = mouseEvent(.leftMouseUp, at: point, modifiers: modifiers) else { return }
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
    }

    /// Text-view point for a document offset (middle of the first line of its layout fragment).
    func point(atOffset offset: Int, xInset: CGFloat = 4) -> NSPoint? {
        guard let frame = controller.fragmentFrame(at: offset) else { return nil }
        return NSPoint(x: controller.textView.textContainerOrigin.x + xInset, y: frame.minY + 8)
    }
}
