// ChromeLiveViewDemo (spike G7): the containerised Chromium's live view as BelloCode would show it, a WKWebView
// running noVNC's RFB client against the browser container's websockify port (forwarded to host loopback).
//
//   swift run ChromeLiveViewDemo --url http://127.0.0.1:16080 [--password P] [--latency N] [--cpu SECONDS]
//                                [--no-jpeg] [--probe] [--eval JS] [--clip-in TEXT] [--clip-out-wait SECONDS] [--snapshot PATH]
//
// --latency N: N key presses and N clicks sent through noVNC; each one flips the page in Chromium (fixture
//   toggle.html) and the time until the flip reaches the noVNC canvas is recorded (input → container → canvas;
//   compositing to the screen adds up to one frame).
// --cpu S: CPU of this web view's WebContent process over S seconds (whatever Chromium is showing).
// --clip-in / --clip-out-wait: clipboard Mac → container (VNC cut text) and container → Mac (server cut text).
// Prints one JSON object. Not production code; see docs/spikes/G7-chrome-browse-container.md.

import AppKit
import Darwin
import Foundation
import WebKit

setvbuf(stdout, nil, _IOLBF, 0)
// A measurement run in a window nobody looks at: without this, App Nap stalls the whole process (sleeps included).
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "G7 live-view measurement")
let app = NSApplication.shared
app.setActivationPolicy(.regular)

func option(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

let page = """
    <!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;height:100%;background:#222}\
    #screen{width:100%;height:100%}</style></head><body><div id="screen"></div>
    <script type="module">
    import RFB from './core/rfb.js';
    const g7 = window.g7 = { connected: false, clip: null };
    const params = new URLSearchParams(location.hash.slice(1));
    if (params.get('nojpeg') === '1') {
      // Without a JPEG quality level TigerVNC sends lossless Tight (zlib), decoded synchronously; JPEG rects are
      // decoded through Image loads, which WebKit defers for a page it considers hidden (this harness's window).
      const send = RFB.messages.clientEncodings;
      RFB.messages.clientEncodings = (sock, encs) => send(sock, encs.filter(e => e < -32 || e > -23));
    }
    const rfb = new RFB(document.getElementById('screen'), params.get('ws'), { credentials: { password: params.get('pw') || '' } });
    rfb.scaleViewport = true;
    rfb.addEventListener('connect', () => { g7.connected = true; });
    rfb.addEventListener('disconnect', e => { g7.disconnected = JSON.stringify(e.detail); });
    rfb.addEventListener('clipboard', e => { g7.clip = e.detail.text; });
    g7.rfb = rfb;
    const canvas = () => document.querySelector('#screen canvas');
    // The visible canvas (what the person sees, updated on requestAnimationFrame) or noVNC's backbuffer (decoded).
    const bright = (back) => {
      const c = back ? rfb._display._backbuffer : canvas();
      const d = c.getContext('2d').getImageData(Math.floor(c.width * 0.3), Math.floor(c.height * 0.875), 1, 1).data;
      return d[0] + d[1] + d[2] > 384;
    };
    const click = () => {
      const c = canvas(), r = c.getBoundingClientRect();
      const at = { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0, bubbles: true };
      c.dispatchEvent(new MouseEvent('mousedown', { ...at, buttons: 1 }));
      c.dispatchEvent(new MouseEvent('mouseup', { ...at, buttons: 0 }));
    };
    g7.bright = bright; g7.click = click; g7.key = () => rfb.sendKey(0x20, 'Space');
    </script></body></html>
    """

@MainActor
func cpuSeconds(_ pid: pid_t) -> Double? {
    var info = rusage_info_v2()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
    }
    guard result == 0 else { return nil }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticks = Double(info.ri_user_time + info.ri_system_time)
    return ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9
}

func stats(_ values: [Double]) -> [String: Double] {
    let ok = values.filter { $0 >= 0 }.sorted()
    guard !ok.isEmpty else { return ["n": 0] }
    let p = { (q: Double) in ok[min(ok.count - 1, Int((Double(ok.count - 1) * q).rounded()))] }
    return ["n": Double(ok.count), "failed": Double(values.count - ok.count), "p50": p(0.5), "p90": p(0.9),
            "min": ok.first!, "max": ok.last!]
}

@MainActor
func run() async -> Int32 {
    let base = option("--url") ?? "http://127.0.0.1:16080"
    guard let baseURL = URL(string: base + "/"), let host = baseURL.host, let port = baseURL.port else { return 2 }
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 800), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
    window.title = "G7 live view"
    // In a login session that shows no windows (the G7 run) WebKit reports the page hidden and suspends its
    // process between calls: connect, first frame, snapshot and input work; continuous frame updates do not.
    let webView = WKWebView(frame: window.contentLayoutRect)
    webView.autoresizingMask = [.width, .height]
    window.contentView = webView
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    let ws = "ws://\(host):\(port)/websockify"
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    let noJPEG = CommandLine.arguments.contains("--no-jpeg") ? "1" : "0"
    components.fragment = "ws=\(ws)&pw=\(option("--password") ?? "")&nojpeg=\(noJPEG)"
    webView.loadHTMLString(page, baseURL: components.url)
    var report: [String: Any] = ["url": base]
    let clock = ContinuousClock()
    let started = clock.now
    var connected = false
    while clock.now - started < .seconds(15) {
        try? await Task.sleep(for: .milliseconds(10))
        if let value = try? await webView.evaluateJavaScript("window.g7 && g7.connected") as? Bool, value {
            connected = true
            break
        }
    }
    let connectMs = (clock.now - started) / .milliseconds(1)
    report["connected"] = connected
    report["connect_ms"] = connectMs
    guard connected else {
        report["error"] = (try? await webView.evaluateJavaScript("window.g7 && g7.disconnected")) as? String ?? "timeout"
        print(String(data: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
        return 1
    }
    try? await Task.sleep(for: .milliseconds(800))
    if let n = option("--latency").flatMap(Int.init) {
        // Polled from here (each poll is one evaluateJavaScript round trip, ~0.2-0.5 ms), not with page timers,
        // which WebKit throttles in a window that is not frontmost.
        for (kind, back) in [("key", true), ("click", true), ("key_visible_canvas", false)] {
            var values: [Double] = []
            let probe = "g7.bright(\(back))"
            for _ in 0..<n {
                let before = (try? await webView.evaluateJavaScript(probe)) as? Bool ?? false
                let t0 = clock.now
                _ = try? await webView.evaluateJavaScript(kind == "click" ? "g7.click(), 0" : "g7.key(), 0")
                var dt = -1.0
                while clock.now - t0 < .milliseconds(1500) {
                    if let now = (try? await webView.evaluateJavaScript(probe)) as? Bool, now != before {
                        dt = (clock.now - t0) / .milliseconds(1)
                        break
                    }
                }
                values.append((dt * 10).rounded() / 10)
                try? await Task.sleep(for: .milliseconds(150))
            }
            report["latency_\(kind)_ms"] = stats(values)
            report["latency_\(kind)_raw"] = values
        }
    }
    if let seconds = option("--cpu").flatMap(Double.init) {
        let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
        let before = cpuSeconds(pid), t0 = clock.now
        try? await Task.sleep(for: .seconds(seconds))
        let after = cpuSeconds(pid), elapsed = (clock.now - t0) / .seconds(1)
        if let before, let after { report["webcontent_cpu_percent"] = ((after - before) / elapsed * 1000).rounded() / 10 }
        if let own = cpuSeconds(getpid()) { report["harness_cpu_seconds_total"] = own }
    }
    if let text = option("--clip-in") {
        _ = try? await webView.callAsyncJavaScript("g7.rfb.clipboardPasteFrom(text)", arguments: ["text": text], contentWorld: .page)
        report["clip_in_sent"] = text
    }
    if let wait = option("--clip-out-wait").flatMap(Double.init) {
        let t0 = clock.now
        var clip: String?
        while clock.now - t0 < .seconds(wait), clip == nil {
            try? await Task.sleep(for: .milliseconds(50))
            clip = try? await webView.evaluateJavaScript("g7.clip") as? String
        }
        report["clip_out_received"] = clip ?? NSNull()
    }
    if CommandLine.arguments.contains("--probe") {
        var trace: [String] = []
        for step in 0..<6 {
            let state = try? await webView.evaluateJavaScript("[g7.bright(true), g7.bright(false), rfb_state = g7.rfb._rfbConnectionState].join(' ')")
            trace.append("\(step): \(String(describing: state))")
            if step == 1 { _ = try? await webView.evaluateJavaScript("g7.key(), 0") }
            try? await Task.sleep(for: .milliseconds(500))
        }
        report["probe"] = trace
    }
    if let script = option("--eval") {
        do { report["eval"] = String(describing: try await webView.evaluateJavaScript(script)) } catch { report["eval_error"] = "\(error)" }
    }
    if let path = option("--snapshot") {
        let configuration = WKSnapshotConfiguration()
        if let image = try? await webView.takeSnapshot(configuration: configuration),
           let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            report["snapshot"] = path
        }
    }
    print(String(data: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
    window.close()
    return 0
}

Task { @MainActor in
    let deadline = Task {
        try? await Task.sleep(for: .seconds(180))
        print("{\"error\":\"timed out\"}")
        exit(3)
    }
    let code = await run()
    deadline.cancel()
    exit(code)
}
app.run()
