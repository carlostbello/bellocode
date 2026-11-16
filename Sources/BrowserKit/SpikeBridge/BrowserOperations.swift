// SPIKE (gate G3). Per-operation implementations of `Browser.Operations` (opencode 2.3.0) over one WebTab.
// Result shapes follow packages/plugin-browser/src/rpc.ts; the server validates every result against them.

import AppKit
import WebKit

@MainActor
struct BrowserOperations {
    let host: BrowserHost
    let tab: WebTab

    private var action: JSONValue { command.action }
    private let command: BrowserCommand

    init(host: BrowserHost, tab: WebTab, command: BrowserCommand = BrowserCommand(action: [:])) {
        self.host = host
        self.tab = tab
        self.command = command
    }

    func run(_ command: BrowserCommand) async throws -> BrowserResult {
        try await BrowserOperations(host: host, tab: tab, command: command).execute()
    }

    private var tabValue: JSONValue { tab.state.json }
    private func page(_ fields: [String: JSONValue] = [:]) -> BrowserResult {
        var fields = fields
        fields["tab"] = tabValue
        return BrowserResult(value: .object(fields))
    }
    private var tabResult: BrowserResult { BrowserResult(value: tabValue) }

    private func execute() async throws -> BrowserResult {
        switch command.type {
        case "navigate":
            try await host.navigate(tab, to: action["url"]?.string ?? "about:blank")
            return tabResult
        case "back", "forward", "reload", "stop":
            switch command.type {
            case "back": if tab.webView.canGoBack { tab.webView.goBack() }
            case "forward": if tab.webView.canGoForward { tab.webView.goForward() }
            case "reload": tab.webView.reload()
            default: tab.webView.stopLoading()
            }
            if command.type != "stop" { try await tab.waitForLoad() }
            return tabResult
        case "frames":
            return page(["frames": .array(try await frames())])
        case "snapshot", "find":
            return page(try await snapshot())
        case "evaluate":
            return page(["value": try await evaluate()])
        case "click":
            try await click(ref: try ref("ref"), button: action["button"]?.string ?? "left", count: action["count"]?.int ?? 1,
                            modifiers: action["modifiers"]?.array?.compactMap(\.string) ?? [])
            return tabResult
        case "hover":
            try await hover(try ref("ref"))
            return tabResult
        case "drag":
            let from = try ref("from"), to = try ref("to")
            guard from.frame == to.frame else { throw BrowserFailure("unsupported", "browser.drag works within one frame in this build.") }
            _ = try await agentCall("dragScript", ["from": .string(from.id), "to": .string(to.id)], frame: from.frame)
            host.logDelivery("drag", "script (synthetic DragEvent)")
            return tabResult
        case "fill":
            try await fill(try ref("ref"), action["text"]?.string ?? "")
            return tabResult
        case "fill_form":
            for field in action["fields"]?.array ?? [] {
                try Task.checkCancellation()
                guard let id = field["ref"]?.string else { continue }
                let target = try ref(id: id)
                switch field["type"]?.string {
                case "text": try await fill(target, field["value"]?.string ?? "")
                case "select": try await select(target, field["values"]?.array?.compactMap(\.string) ?? [])
                case "check": try await check(target, field["checked"]?.bool ?? true)
                default: throw BrowserFailure("unsupported", "Unknown fill_form field type.")
                }
            }
            return tabResult
        case "select":
            try await select(try ref("ref"), action["values"]?.array?.compactMap(\.string) ?? [])
            return tabResult
        case "check":
            try await check(try ref("ref"), action["checked"]?.bool ?? true)
            return tabResult
        case "press":
            try await press(action["key"]?.string ?? "")
            return tabResult
        case "scroll":
            let result = try await agentCall("scrollPage", ["dx": .number(action["deltaX"]?.double ?? 0), "dy": .number(action["deltaY"]?.double ?? 0)], frame: nil)
            host.logDelivery("scroll", "script (scrollBy, no wheel event); moved to \(result["after"]?.compactText ?? "?")")
            return tabResult
        case "wait":
            try await wait()
            return tabResult
        case "screenshot":
            return try await screenshot()
        case "dialog":
            return try dialog()
        case "files.upload", "files.drop":
            let target = try ref("ref")
            let files: [JSONValue] = command.files.map { ["name": .string($0.name), "mime": .string($0.mime), "data": .string($0.data.base64EncodedString())] }
            _ = try await agentCall("filesScript", ["ref": .string(target.id), "files": .array(files), "drop": .bool(command.type == "files.drop")], frame: target.frame)
            return tabResult
        case "files.list":
            let files: [JSONValue] = tab.captures.map { ["id": .string($0.id), "name": .string($0.name), "mime": .string($0.mime), "bytes": .number(Double($0.data.count)), "state": "completed"] }
            return page(["files": .array(files)])
        case "files.get":
            guard let file = tab.captures.first(where: { $0.id == action["fileID"]?.string }) else {
                throw BrowserFailure("file_unavailable", "This file ID is not a completed capture of this tab. Call browser.files.list({tabID}). Downloads are not captured by this build.")
            }
            return BrowserResult(value: ["tab": tabValue], files: [file])
        case "console":
            return page(console())
        case "network.list":
            return page(try await networkList())
        case "network.get":
            return page(try await networkGet())
        case "trace.start", "trace.stop", "trace.analyze", "cpu.start", "cpu.stop", "cpu.analyze",
             "heap.snapshot", "heap.summary", "heap.query", "heap.object", "heap.compare", "lighthouse":
            throw BrowserFailure("unsupported", "browser.\(command.type) needs the Chromium DevTools protocol, which the BelloCode WebKit browser does not have. Use browser.evaluate with the Performance API (performance.getEntries, performance.memory is unavailable) or ask the user to profile in Safari Web Inspector.")
        default:
            throw BrowserFailure("unsupported", "This desktop app does not support browser.\(command.type). Ask the user to update the desktop app, or use another operation.")
        }
    }

    // MARK: Frames and refs

    struct Target {
        var id: String
        var frameID: String
        var frame: WKFrameInfo?
    }

    private func ref(_ key: String) throws -> Target {
        guard let id = action[key]?.string else { throw BrowserFailure("invalid_ref", "browser.\(command.type) needs \(key).") }
        return try ref(id: id)
    }

    private func ref(id raw: String) throws -> Target {
        let id = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
        guard let frameID = tab.refs[id] else {
            throw BrowserFailure("stale_ref", "Element ref is stale or belongs to another tab. Call browser.snapshot({tabID}) and use a ref from that tab's newest snapshot. Do not reuse refs after navigation or a newer snapshot.")
        }
        return Target(id: id, frameID: frameID, frame: try frame(frameID))
    }

    /// nil means the main frame.
    private func frame(_ frameID: String?) throws -> WKFrameInfo? {
        guard let frameID, frameID != "main" else { return nil }
        guard let frame = tab.frames[frameID] else {
            throw BrowserFailure("frame_unavailable", "Frame context is unavailable. Call browser.frames({tabID}) and use a current frameID from this tab, or omit frameID to target the main frame.")
        }
        return frame.isMain ? nil : frame.info
    }

    private func agentCall(_ name: String, _ input: JSONValue, frame: WKFrameInfo?, timeout: Duration = .seconds(30)) async throws -> JSONValue {
        try await tab.agent(name, input, frame: frame, timeout: timeout)
    }

    /// Pings every registered frame, drops the ones that are gone or reloaded, and lists the rest (main frame first).
    private func frames() async throws -> [JSONValue] {
        var live: [JSONValue] = []
        let mainID = tab.mainFrameID ?? "main"
        for id in tab.frameOrder {
            guard let entry = tab.frames[id] else { continue }
            let probe = try? await agentCall("frameInfo", [:], frame: entry.isMain ? nil : entry.info, timeout: .seconds(2))
            guard let probe, probe["frameId"]?.string == id else {
                if !entry.isMain { tab.frames[id] = nil; tab.frameOrder.removeAll { $0 == id } }
                continue
            }
            var fields: [String: JSONValue] = ["id": .string(id), "url": .string(probe["url"]?.string ?? entry.url), "name": .string(String((probe["name"]?.string ?? "").prefix(2_048)))]
            if !entry.isMain { fields["parentID"] = .string(mainID) }
            if entry.isMain { live.insert(.object(fields), at: 0) } else { live.append(.object(fields)) }
        }
        if live.isEmpty { live = [["id": .string(mainID), "url": .string(tab.state.url), "name": ""]] }
        return live
    }

    // MARK: Observation

    private func snapshot() async throws -> [String: JSONValue] {
        var frameID = action["frameID"]?.string
        var rootRef: String?
        if command.type == "snapshot", let refID = action["ref"]?.string {
            let target = try ref(id: refID)
            frameID = target.frameID
            rootRef = target.id
        }
        let frameInfo = try frame(frameID)
        let depth = command.type == "snapshot" ? (action["depth"]?.int ?? 8) : 8
        var input: [String: JSONValue] = ["base": .number(Double(tab.refCounter)), "depth": .number(Double(depth)), "boxes": .bool(action["boxes"]?.bool ?? false)]
        if let rootRef { input["rootRef"] = .string(rootRef) }
        let result = try await agentCall("snapshot", .object(input), frame: frameInfo)
        // Refs expire on the next snapshot of any frame of this tab.
        tab.refs.removeAll()
        let owner = frameID ?? tab.mainFrameID ?? "main"
        for ref in result["refs"]?.array ?? [] { if let ref = ref.string { tab.refs[ref] = owner } }
        tab.refCounter = result["counter"]?.int ?? tab.refCounter
        var lines = result["lines"]?.array?.compactMap(\.string) ?? []
        if command.type == "find", let text = action["text"]?.string?.lowercased() {
            lines = lines.filter { $0.lowercased().contains(text) }
        }
        let content = lines.joined(separator: "\n")
        return [
            "content": .string(String(content.prefix(BrowserContract.maxText))),
            "truncated": .bool((result["truncated"]?.bool ?? false) || content.count > BrowserContract.maxText),
        ]
    }

    private func evaluate() async throws -> JSONValue {
        guard let script = action["script"]?.string else { throw BrowserFailure("invalid_script", "browser.evaluate needs a script.") }
        if action["ref"] != nil, action["frameID"] != nil {
            throw BrowserFailure("invalid_arguments", "Pass either ref or frameID to browser.evaluate, not both. A ref already runs in its element's frame.")
        }
        do {
            if action["ref"] != nil {
                // The element lives in the isolated world's ref table, so the function runs there: same DOM, but the
                // page's own globals are not visible.
                let target = try ref("ref")
                let body = AgentScript.source + "\nconst __element = window.__bc.resolve(ref);\nreturn await (\n\(script)\n).call(__element, __element);"
                return try await tab.callJS(body, arguments: ["ref": target.id], frame: target.frame, world: host.agentWorld)
            }
            let frameInfo = try frame(action["frameID"]?.string)
            do {
                return try await tab.callJS("return await (\n\(script)\n);", frame: frameInfo, world: .page)
            } catch let failure as BrowserFailure where failure.message.contains("SyntaxError") {
                // Statements rather than one expression: evaluate as a program; its completion value is the result.
                return try await tab.callJS(script, frame: frameInfo, world: .page, program: true)
            }
        } catch let failure as BrowserFailure where failure.code == "script_error" {
            throw BrowserFailure("script_error", "Page JavaScript threw an exception. Check the script and \(action["ref"] != nil ? "ref" : "frameID"); inspect the page before repeating code with side effects. Details: \(failure.message)")
        }
    }

    private func wait() async throws {
        let condition = action["condition"]?.string ?? "load"
        let timeout = action["timeoutMs"]?.int ?? 10_000
        if condition == "load" {
            try await tab.waitForLoad(timeout: .milliseconds(timeout))
            return
        }
        guard let text = action["text"]?.string, !text.isEmpty else {
            throw BrowserFailure("invalid_arguments", "browser.wait requires non-empty text for condition \"text\" or \"textGone\". Use condition \"load\" without text to wait for loading.")
        }
        let ok = try await agentCall("waitText", ["text": .string(text), "gone": .bool(condition == "textGone"), "timeoutMs": .number(Double(timeout))],
                                     frame: try frame(action["frameID"]?.string), timeout: .milliseconds(timeout + 2_000))
        if ok.bool != true {
            throw BrowserFailure("timeout", "browser.wait failed for condition \"\(condition)\" (timeoutMs: \(timeout)). Inspect browser.snapshot({tabID}) and check text/frameID before retrying; timeoutMs can be increased up to 30000 for a genuinely slow page.")
        }
    }

    private func console() -> [String: JSONValue] {
        let order = ["debug": 0, "info": 1, "warning": 2, "error": 3]
        let minimum = order[action["level"]?.string ?? "debug"] ?? 0
        let limit = action["limit"]?.int ?? 100
        let matching = tab.console.filter { (order[$0.level] ?? 1) >= minimum }
        let messages: [JSONValue] = matching.suffix(limit).map { entry in
            var fields: [String: JSONValue] = ["id": .string(entry.id), "timestampMs": .number(entry.timestampMs), "level": .string(entry.level), "text": .string(entry.text), "textTruncated": .bool(entry.truncated)]
            if let source = entry.source, source["url"]?.string != nil {
                fields["source"] = ["url": source["url"] ?? "", "line": .number(source["line"]?.double ?? 0), "column": .number(source["column"]?.double ?? 0)]
            }
            return .object(fields)
        }
        return ["messages": .array(messages), "truncated": .bool(matching.count > limit), "dropped": .number(Double(tab.consoleDropped))]
    }

    // MARK: Network (Resource Timing only: no headers, bodies, methods or failures)

    private static let resourceTypes: [String: String] = [
        "navigation": "document", "link": "stylesheet", "css": "stylesheet", "img": "image", "image": "image", "video": "media",
        "audio": "media", "script": "script", "xmlhttprequest": "xhr", "fetch": "fetch", "beacon": "fetch", "iframe": "document",
    ]

    private func entries() async throws -> [JSONValue] {
        let raw = try await agentCall("network", [:], frame: nil)
        return (raw.array ?? []).enumerated().map { index, entry in
            var fields: [String: JSONValue] = [
                "id": .string("req_\(index + 1)"), "url": .string(String((entry["url"]?.string ?? "").prefix(BrowserContract.maxText))),
                "method": "GET", "resourceType": .string(Self.resourceTypes[entry["initiator"]?.string ?? ""] ?? "other"),
                "timestampMs": .number(entry["start"]?.double ?? 0), "state": "completed", "durationMs": .number(entry["duration"]?.double ?? 0),
            ]
            if let status = entry["status"]?.int, status > 0 { fields["statusCode"] = .number(Double(status)) }
            return .object(fields)
        }
    }

    private func networkList() async throws -> [String: JSONValue] {
        var requests = try await entries()
        if let needle = action["urlContains"]?.string { requests = requests.filter { $0["url"]?.string?.contains(needle) == true } }
        if let type = action["resourceType"]?.string { requests = requests.filter { $0["resourceType"]?.string == type } }
        let limit = action["limit"]?.int ?? 100
        return ["requests": .array(Array(requests.suffix(limit))), "truncated": .bool(requests.count > limit), "dropped": 0]
    }

    private func networkGet() async throws -> [String: JSONValue] {
        guard let request = try await entries().first(where: { $0["id"]?.string == action["id"]?.string }) else {
            throw BrowserFailure("request_unavailable", "Network request ID is unknown or expired. Call browser.network.list({tabID}) and use an exact returned id.")
        }
        let unavailable: JSONValue = ["state": "unavailable", "reason": "backendUnavailable"]
        return ["request": request, "requestHeaders": [], "responseHeaders": [], "headersTruncated": false, "requestBody": unavailable, "responseBody": unavailable]
    }

    // MARK: Input

    private struct Point {
        var css: CGPoint
        var rect: CGRect
        var offset: CGPoint
        var hit: Bool
        var info: JSONValue
    }

    /// Scrolls the element into view and returns its centre in main-frame CSS pixels. Subframe offsets come from
    /// the main document's iframe element whose src matches the frame URL; nil when that is ambiguous.
    private func point(_ target: Target) async throws -> Point? {
        let info = try await agentCall("point", ["ref": .string(target.id)], frame: target.frame)
        let rect = CGRect(x: info["x"]?.double ?? 0, y: info["y"]?.double ?? 0, width: info["width"]?.double ?? 0, height: info["height"]?.double ?? 0)
        var offset = CGPoint.zero
        if target.frame != nil {
            let url = tab.frames[target.frameID]?.url ?? ""
            let candidates = (try await agentCall("iframes", [:], frame: nil)).array?.filter { $0["src"]?.string == url } ?? []
            guard candidates.count == 1, let match = candidates.first else { return nil }
            offset = CGPoint(x: match["x"]?.double ?? 0, y: match["y"]?.double ?? 0)
        }
        let css = CGPoint(x: (info["cx"]?.double ?? 0) + offset.x, y: (info["cy"]?.double ?? 0) + offset.y)
        host.flash(tab, cssRect: rect, offset: offset)
        return Point(css: css, rect: rect, offset: offset, hit: info["hit"]?.bool ?? false, info: info)
    }

    /// Lets the web process drain the events: one script round trip on the same connection, cut short by a dialog.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(16))
        _ = try? await tab.callJS("return 1", frame: nil, world: host.agentWorld, timeout: .seconds(3))
    }

    private func click(ref target: Target, button: String, count: Int, modifiers: [String]) async throws {
        var reason = "script mode"
        if host.inputMode == .native, button != "middle" {
            if let point = try await point(target) {
                do {
                    try NativeInput.click(tab.webView, css: point.css, button: button, count: count, modifiers: modifiers)
                    await settle()
                    host.logDelivery("click", point.hit ? "native" : "native (element covered by \(point.info["hitTag"]?.string ?? "?"))")
                    return
                } catch let error as NativeInput.Unavailable { reason = error.description }
            } else { reason = "frame offset unknown" }
        } else if button == "middle" { reason = "middle button" }
        do {
            _ = try await agentCall("clickScript", ["ref": .string(target.id), "button": .string(button), "count": .number(Double(count)),
                                                    "alt": .bool(modifiers.contains("Alt")), "ctrl": .bool(modifiers.contains("Control")),
                                                    "meta": .bool(modifiers.contains("Meta")), "shift": .bool(modifiers.contains("Shift"))], frame: target.frame)
        } catch is DialogInterrupted {}
        host.logDelivery("click", "script (\(reason))")
    }

    private func hover(_ target: Target) async throws {
        var reason = "script mode"
        if host.inputMode == .native {
            if let point = try await point(target) {
                do {
                    try NativeInput.move(tab.webView, css: point.css)
                    await settle()
                    host.logDelivery("hover", "native")
                    return
                } catch let error as NativeInput.Unavailable { reason = error.description }
            } else { reason = "frame offset unknown" }
        }
        _ = try await agentCall("hoverScript", ["ref": .string(target.id)], frame: target.frame)
        host.logDelivery("hover", "script (\(reason))")
    }

    private func fill(_ target: Target, _ text: String) async throws {
        let info = try await agentCall("point", ["ref": .string(target.id)], frame: target.frame)
        guard info["editable"]?.bool == true else {
            throw BrowserFailure("not_editable", "Target is not an enabled editable text field. Take a fresh snapshot and choose a textbox; use browser.select for dropdowns, browser.check for checkboxes/radios, or browser.files.upload for file inputs.")
        }
        let structured = ["date", "time", "datetime-local", "month", "week"].contains(info["type"]?.string ?? "")
        if host.inputMode == .native, !structured {
            do {
                _ = try await agentCall("prepareType", ["ref": .string(target.id)], frame: target.frame)
                try NativeInput.insertText(tab.webView, text)
                await settle()
                let value = try await agentCall("valueOf", ["ref": .string(target.id)], frame: target.frame)
                if value.string == text {
                    host.logDelivery("fill", "native (insertText)")
                    return
                }
                host.logDelivery("fill", "native insertText left \(value.compactText.prefix(40)); retrying by script")
            } catch let error as NativeInput.Unavailable {
                host.logDelivery("fill", "native unavailable: \(error.description)")
            }
        }
        let value = try await agentCall("fillScript", ["ref": .string(target.id), "text": .string(text)], frame: target.frame)
        if structured, value.string != text {
            throw BrowserFailure("invalid_value", "The \(info["type"]?.string ?? "") input rejected this value. Use its required format, for example 2026-09-07 for date or 14:45 for time.")
        }
        host.logDelivery("fill", "script (\(structured ? "structured input" : "script mode"))")
    }

    private func select(_ target: Target, _ values: [String]) async throws {
        _ = try await agentCall("selectOptions", ["ref": .string(target.id), "values": .array(values.map(JSONValue.string))], frame: target.frame)
    }

    private func check(_ target: Target, _ checked: Bool) async throws {
        let current = try await agentCall("checkedState", ["ref": .string(target.id)], frame: target.frame)
        if current.bool == checked { return }
        if current.bool == true, !checked {
            let info = try await agentCall("point", ["ref": .string(target.id)], frame: target.frame)
            if info["type"]?.string == "radio" {
                throw BrowserFailure("invalid_state", "A selected radio cannot be cleared by clicking it. Select a different radio in its group instead.")
            }
        }
        try await click(ref: target, button: "left", count: 1, modifiers: [])
        if try await agentCall("checkedState", ["ref": .string(target.id)], frame: target.frame).bool != checked {
            throw BrowserFailure("invalid_state", "The page did not keep the requested checked state. Inspect the current snapshot and page validation before retrying; do not blindly toggle the control again.")
        }
    }

    private func press(_ chord: String) async throws {
        let key = try NativeInput.parse(chord)
        if host.inputMode == .native {
            do {
                try NativeInput.press(tab.webView, key)
                await settle()
                host.logDelivery("press", "native")
                return
            } catch let error as NativeInput.Unavailable {
                host.logDelivery("press", "native unavailable: \(error.description)")
            }
        }
        // Untrusted KeyboardEvents run no default action; Enter in a form field submits explicitly.
        let script = """
        const el = document.activeElement || document.body;
        const init = { key: \(jsString(key.charactersIgnoringModifiers == "\r" ? "Enter" : chord.split(separator: "+").last.map(String.init) ?? chord)), bubbles: true, cancelable: true, composed: true,
          altKey: \(key.flags.contains(.option)), ctrlKey: \(key.flags.contains(.control)), metaKey: \(key.flags.contains(.command)), shiftKey: \(key.flags.contains(.shift)) };
        const proceed = el.dispatchEvent(new KeyboardEvent('keydown', init));
        el.dispatchEvent(new KeyboardEvent('keyup', init));
        if (proceed && init.key === 'Enter' && el.form && el.localName === 'input') el.form.requestSubmit();
        return true;
        """
        do { _ = try await tab.callJS(script, frame: nil, world: host.agentWorld) } catch is DialogInterrupted {}
        host.logDelivery("press", "script (untrusted KeyboardEvent)")
    }

    // MARK: Screenshot and dialogs

    private func screenshot() async throws -> BrowserResult {
        if action["ref"] != nil, action["fullPage"]?.bool == true {
            throw BrowserFailure("invalid_arguments", "Choose either ref for an element screenshot or fullPage:true for the whole page. Remove the other argument before retrying.")
        }
        let format = action["format"]?.string ?? "jpeg"
        guard format == "png" || format == "jpeg" else {
            throw BrowserFailure("unsupported", "WebP screenshots are not supported by this build. Use format \"png\" or \"jpeg\".")
        }
        guard host.focusedTabID == tab.id, tab.webView.window?.isVisible == true else {
            throw BrowserFailure("not_visible", "Screenshot needs a visible tab. Call browser.tabs.focus and keep its desktop window visible.")
        }
        let maxWidth = CGFloat(action["maxWidth"]?.int ?? 2_000)
        let image: NSImage
        if action["fullPage"]?.bool == true {
            // takeSnapshot only renders the visible area on macOS; createPDF renders the whole document.
            let pdf = try await tab.webView.pdf(configuration: WKPDFConfiguration())
            image = try Self.rasterize(pdf: pdf, maxWidth: maxWidth)
        } else {
            let configuration = WKSnapshotConfiguration()
            if let target = action["ref"]?.string {
                guard let point = try await point(try ref(id: target)) else { throw BrowserFailure("unsupported", "Element screenshots inside this frame are not supported; capture the viewport.") }
                let zoom = tab.webView.pageZoom
                let rect = CGRect(x: (point.rect.minX + point.offset.x) * zoom, y: (point.rect.minY + point.offset.y) * zoom, width: point.rect.width * zoom, height: point.rect.height * zoom)
                    .intersection(tab.webView.bounds)
                guard !rect.isEmpty else { throw BrowserFailure("not_visible", "Element or page has no visible screenshot area. Take a fresh snapshot and choose a visible element, or omit ref to capture the viewport.") }
                configuration.rect = rect
            }
            let width = configuration.rect.isNull ? tab.webView.bounds.width : configuration.rect.width
            if width > maxWidth { configuration.snapshotWidth = NSNumber(value: Double(maxWidth)) }
            image = try await tab.webView.takeSnapshot(configuration: configuration)
        }
        guard let tiff = image.tiffRepresentation else { throw BrowserFailure("operation_failed", "Could not encode the screenshot.") }
        let data = try await Self.encode(tiff: tiff, format: format, quality: action["quality"]?.int ?? 80)
        guard data.count <= BrowserContract.maxFileBytes else {
            throw BrowserFailure("too_large", "Screenshot exceeds 5 MiB; capture an element, use jpeg, or a smaller maxWidth.")
        }
        let file = BrowserFile(name: "screenshot.\(format == "jpeg" ? "jpg" : "png")", mime: "image/\(format)", data: data)
        tab.captures.append(file)
        if tab.captures.count > 20 { tab.captures.removeFirst() }
        host.lastScreenshot = data
        return BrowserResult(value: ["tab": tabValue], files: [file])
    }

    private static func rasterize(pdf: Data, maxWidth: CGFloat) throws -> NSImage {
        guard let representation = NSPDFImageRep(data: pdf) else { throw BrowserFailure("operation_failed", "Could not render the page.") }
        let bounds = representation.bounds
        let scale = min(1, maxWidth / max(bounds.width, 1), 16_000 / max(bounds.height, 1))
        let size = NSSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        representation.draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        return image
    }

    @concurrent
    private static func encode(tiff: Data, format: String, quality: Int) async throws -> Data {
        guard let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: format == "png" ? .png : .jpeg, properties: format == "png" ? [:] : [.compressionFactor: Double(quality) / 100])
        else { throw BrowserFailure("operation_failed", "Could not encode the screenshot.") }
        return data
    }

    private func dialog() throws -> BrowserResult {
        let verb = action["action"]?.string ?? "get"
        if verb != "get" {
            guard tab.dialog != nil else {
                throw BrowserFailure("no_dialog", "This tab has no JavaScript dialog to handle. browser.dialog({tabID,action:\"get\"}) returns null when none is open; continue without accepting or dismissing one.")
            }
            tab.answerDialog(accept: verb == "accept", text: action["promptText"]?.string)
            host.show("Agent \(verb == "accept" ? "accepted" : "dismissed") the page dialog")
        }
        let dialog: JSONValue = tab.dialog.map { ["type": .string($0.type), "message": .string(String($0.message.prefix(BrowserContract.maxText))), "defaultValue": .string(String($0.defaultValue.prefix(2_048)))] } ?? .null
        return page(["dialog": dialog])
    }
}
