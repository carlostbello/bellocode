// Per-operation implementations of `Browser.Operations` (opencode 2.3.0, contract v4) over one tab. Result shapes
// follow packages/plugin-browser/src/rpc.ts; the server validates every result against them. The support matrix is
// `OperationSupport`; ownership, pause and generation checks happen before this runs (`BrowserTabSet.perform`).

import AppKit
import OpenCodeKit
import WebKit

@MainActor
struct BrowserOperations {
    let set: BrowserTabSet
    let tab: BrowserTab
    let command: BrowserCommand

    private var action: JSONValue { command.action }
    private var webView: BrowserWebView { tab.ensureWebView() }

    init(set: BrowserTabSet, tab: BrowserTab, command: BrowserCommand) {
        self.set = set
        self.tab = tab
        self.command = command
    }

    func run() async throws -> BrowserResult {
        try await execute()
    }

    private var tabValue: JSONValue { tab.info.json }
    private func page(_ fields: [String: JSONValue] = [:]) -> BrowserResult {
        var fields = fields
        fields["tab"] = tabValue
        return BrowserResult(value: .object(fields))
    }
    private var tabResult: BrowserResult { BrowserResult(value: tabValue) }

    private func execute() async throws -> BrowserResult {
        switch command.type {
        case "navigate":
            try await set.navigate(tab, to: action["url"]?.stringValue ?? "about:blank")
            return tabResult
        case "back", "forward", "reload", "stop":
            switch command.type {
            case "back": if webView.canGoBack { webView.goBack() }
            case "forward": if webView.canGoForward { webView.goForward() }
            case "reload": webView.reload()
            default: webView.stopLoading()
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
            try await click(ref: try ref("ref"), button: action["button"]?.stringValue ?? "left", count: action["count"]?.intValue ?? 1,
                            modifiers: action["modifiers"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            return tabResult
        case "hover":
            try await hover(try ref("ref"))
            return tabResult
        case "drag":
            let from = try ref("from"), to = try ref("to")
            guard from.frame == to.frame else { throw BrowserFailure("unsupported", "browser.drag works within one frame in this build.") }
            _ = try await agentCall("dragScript", ["from": .string(from.id), "to": .string(to.id)], frame: from.frame)
            set.logDelivery("drag", "script (synthetic DragEvent)")
            return tabResult
        case "fill":
            try await fill(try ref("ref"), action["text"]?.stringValue ?? "")
            return tabResult
        case "fill_form":
            for field in action["fields"]?.arrayValue ?? [] {
                try Task.checkCancellation()
                guard let id = field["ref"]?.stringValue else { continue }
                let target = try ref(id: id)
                switch field["type"]?.stringValue {
                case "text": try await fill(target, field["value"]?.stringValue ?? "")
                case "select": try await select(target, field["values"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                case "check": try await check(target, field["checked"]?.boolValue ?? true)
                default: throw BrowserFailure("unsupported", "Unknown fill_form field type.")
                }
            }
            return tabResult
        case "select":
            try await select(try ref("ref"), action["values"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            return tabResult
        case "check":
            try await check(try ref("ref"), action["checked"]?.boolValue ?? true)
            return tabResult
        case "press":
            try await press(action["key"]?.stringValue ?? "")
            return tabResult
        case "scroll":
            let result = try await agentCall("scrollPage", ["dx": .number(action["deltaX"]?.numberValue ?? 0), "dy": .number(action["deltaY"]?.numberValue ?? 0)], frame: nil)
            set.logDelivery("scroll", "script (scrollBy, no wheel event); moved to \(result["after"]?.compactText ?? "?")")
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
            var files: [JSONValue] = tab.captures.map { ["id": .string($0.id), "name": .string($0.name), "mime": .string($0.mime), "bytes": .number(Double($0.data.count)), "state": "completed"] }
            for item in set.workspace?.downloads.completed(forTab: tab.id) ?? [] {
                files.append(["id": .string(item.fileID), "name": .string(item.filename), "mime": .string(Self.mime(for: item.filename)), "bytes": .number(Double(item.bytes)), "state": "completed"])
            }
            return page(["files": .array(files)])
        case "files.get":
            let fileID = action["fileID"]?.stringValue
            if let file = tab.captures.first(where: { $0.id == fileID }) {
                return BrowserResult(value: ["tab": tabValue], files: [file])
            }
            guard let item = set.workspace?.downloads.completed(forTab: tab.id).first(where: { $0.fileID == fileID }), let destination = item.destination else {
                throw BrowserFailure("file_unavailable", "This file ID is not a completed capture or download of this tab. Call browser.files.list({tabID}) and use an exact returned id.")
            }
            guard item.bytes <= Int64(BrowserContract.maxFileBytes), let data = try? Data(contentsOf: destination) else {
                throw BrowserFailure("too_large", "The download is larger than 5 MiB, so it stays on the user's Mac (\(item.filename) in Downloads). Tell the user where it is.")
            }
            return BrowserResult(value: ["tab": tabValue], files: [BrowserFile(id: item.fileID, name: item.filename, mime: Self.mime(for: item.filename), data: data)])
        case "console":
            return page(console())
        case "network.list":
            return page(try await networkList())
        case "network.get":
            return page(try await networkGet())
        case "trace.start", "trace.stop", "trace.analyze", "cpu.start", "cpu.stop", "cpu.analyze",
             "heap.snapshot", "heap.summary", "heap.query", "heap.objectValue", "heap.compare", "lighthouse":
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
        guard let id = action[key]?.stringValue else { throw BrowserFailure("invalid_ref", "browser.\(command.type) needs \(key).") }
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
            guard let probe, probe["frameId"]?.stringValue == id else {
                if !entry.isMain { tab.frames[id] = nil; tab.frameOrder.removeAll { $0 == id } }
                continue
            }
            var fields: [String: JSONValue] = ["id": .string(id), "url": .string(probe["url"]?.stringValue ?? entry.url), "name": .string(String((probe["name"]?.stringValue ?? "").prefix(2_048)))]
            if !entry.isMain { fields["parentID"] = .string(mainID) }
            if entry.isMain { live.insert(.object(fields), at: 0) } else { live.append(.object(fields)) }
        }
        if live.isEmpty { live = [["id": .string(mainID), "url": .string(tab.info.url), "name": ""]] }
        return live
    }

    // MARK: Observation

    private func snapshot() async throws -> [String: JSONValue] {
        var frameID = action["frameID"]?.stringValue
        var rootRef: String?
        if command.type == "snapshot", let refID = action["ref"]?.stringValue {
            let target = try ref(id: refID)
            frameID = target.frameID
            rootRef = target.id
        }
        let frameInfo = try frame(frameID)
        let depth = command.type == "snapshot" ? (action["depth"]?.intValue ?? 8) : 8
        var input: [String: JSONValue] = ["base": .number(Double(tab.refCounter)), "depth": .number(Double(depth)), "boxes": .bool(action["boxes"]?.boolValue ?? false)]
        if let rootRef { input["rootRef"] = .string(rootRef) }
        let result = try await agentCall("snapshot", .object(input), frame: frameInfo)
        // Refs expire on the next snapshot of any frame of this tab.
        tab.refs.removeAll()
        let owner = frameID ?? tab.mainFrameID ?? "main"
        for ref in result["refs"]?.arrayValue ?? [] { if let ref = ref.stringValue { tab.refs[ref] = owner } }
        tab.refCounter = result["counter"]?.intValue ?? tab.refCounter
        var lines = result["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if command.type == "find", let text = action["text"]?.stringValue?.lowercased() {
            lines = lines.filter { $0.lowercased().contains(text) }
        }
        let content = lines.joined(separator: "\n")
        return [
            "content": .string(String(content.prefix(BrowserContract.maxText))),
            "truncated": .bool((result["truncated"]?.boolValue ?? false) || content.count > BrowserContract.maxText),
        ]
    }

    private func evaluate() async throws -> JSONValue {
        guard let script = action["script"]?.stringValue else { throw BrowserFailure("invalid_script", "browser.evaluate needs a script.") }
        if action["ref"] != nil, action["frameID"] != nil {
            throw BrowserFailure("invalid_arguments", "Pass either ref or frameID to browser.evaluate, not both. A ref already runs in its element's frame.")
        }
        do {
            if action["ref"] != nil {
                // The element lives in the isolated world's ref table, so the function runs there: same DOM, but the
                // page's own globals are not visible.
                let target = try ref("ref")
                let body = AgentScript.source + "\nconst __element = window.__bc.resolve(ref);\nreturn await (\n\(script)\n).call(__element, __element);"
                return try await tab.callJS(body, arguments: ["ref": target.id], frame: target.frame, world: tab.agentWorld)
            }
            let frameInfo = try frame(action["frameID"]?.stringValue)
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
        let condition = action["condition"]?.stringValue ?? "load"
        let timeout = action["timeoutMs"]?.intValue ?? 10_000
        if condition == "load" {
            try await tab.waitForLoad(timeout: .milliseconds(timeout))
            return
        }
        guard let text = action["text"]?.stringValue, !text.isEmpty else {
            throw BrowserFailure("invalid_arguments", "browser.wait requires non-empty text for condition \"text\" or \"textGone\". Use condition \"load\" without text to wait for loading.")
        }
        let ok = try await agentCall("waitText", ["text": .string(text), "gone": .bool(condition == "textGone"), "timeoutMs": .number(Double(timeout))],
                                     frame: try frame(action["frameID"]?.stringValue), timeout: .milliseconds(timeout + 2_000))
        if ok.boolValue != true {
            throw BrowserFailure("timeout", "browser.wait failed for condition \"\(condition)\" (timeoutMs: \(timeout)). Inspect browser.snapshot({tabID}) and check text/frameID before retrying; timeoutMs can be increased up to 30000 for a genuinely slow page.")
        }
    }

    private func console() -> [String: JSONValue] {
        let order = ["debug": 0, "info": 1, "warning": 2, "error": 3]
        let minimum = order[action["level"]?.stringValue ?? "debug"] ?? 0
        let limit = action["limit"]?.intValue ?? 100
        let matching = tab.console.filter { (order[$0.level] ?? 1) >= minimum }
        let messages: [JSONValue] = matching.suffix(limit).map { entry in
            var fields: [String: JSONValue] = ["id": .string(entry.id), "timestampMs": .number(entry.timestampMs), "level": .string(entry.level), "text": .string(entry.text), "textTruncated": .bool(entry.truncated)]
            if let source = entry.source, source["url"]?.stringValue != nil {
                fields["source"] = ["url": source["url"] ?? "", "line": .number(source["line"]?.numberValue ?? 0), "column": .number(source["column"]?.numberValue ?? 0)]
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
        return (raw.arrayValue ?? []).enumerated().map { index, entry in
            var fields: [String: JSONValue] = [
                "id": .string("req_\(index + 1)"), "url": .string(String((entry["url"]?.stringValue ?? "").prefix(BrowserContract.maxText))),
                "method": "GET", "resourceType": .string(Self.resourceTypes[entry["initiator"]?.stringValue ?? ""] ?? "other"),
                "timestampMs": .number(entry["start"]?.numberValue ?? 0), "state": "completed", "durationMs": .number(entry["duration"]?.numberValue ?? 0),
            ]
            if let status = entry["status"]?.intValue, status > 0 { fields["statusCode"] = .number(Double(status)) }
            return .object(fields)
        }
    }

    private func networkList() async throws -> [String: JSONValue] {
        var requests = try await entries()
        if let needle = action["urlContains"]?.stringValue { requests = requests.filter { $0["url"]?.stringValue?.contains(needle) == true } }
        if let type = action["resourceType"]?.stringValue { requests = requests.filter { $0["resourceType"]?.stringValue == type } }
        let limit = action["limit"]?.intValue ?? 100
        return ["requests": .array(Array(requests.suffix(limit))), "truncated": .bool(requests.count > limit), "dropped": 0]
    }

    private func networkGet() async throws -> [String: JSONValue] {
        guard let request = try await entries().first(where: { $0["id"]?.stringValue == action["id"]?.stringValue }) else {
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
        let rect = CGRect(x: info["x"]?.numberValue ?? 0, y: info["y"]?.numberValue ?? 0, width: info["width"]?.numberValue ?? 0, height: info["height"]?.numberValue ?? 0)
        var offset = CGPoint.zero
        if target.frame != nil {
            let url = tab.frames[target.frameID]?.url ?? ""
            let candidates = (try await agentCall("iframes", [:], frame: nil)).arrayValue?.filter { $0["src"]?.stringValue == url } ?? []
            guard candidates.count == 1, let match = candidates.first else { return nil }
            offset = CGPoint(x: match["x"]?.numberValue ?? 0, y: match["y"]?.numberValue ?? 0)
        }
        let css = CGPoint(x: (info["cx"]?.numberValue ?? 0) + offset.x, y: (info["cy"]?.numberValue ?? 0) + offset.y)
        set.flash(tab, cssRect: rect, offset: offset)
        return Point(css: css, rect: rect, offset: offset, hit: info["hit"]?.boolValue ?? false, info: info)
    }

    /// Lets the web process drain the events: one script round trip on the same connection, cut short by a dialog.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(16))
        _ = try? await tab.callJS("return 1", frame: nil, world: tab.agentWorld, timeout: .seconds(3))
    }

    private func click(ref target: Target, button: String, count: Int, modifiers: [String]) async throws {
        var reason = "script mode"
        if set.inputMode == .native, button != "middle" {
            if let point = try await point(target) {
                set.pointAgentCursor(tab, css: point.css)
                do {
                    try NativeInput.click(webView, css: point.css, button: button, count: count, modifiers: modifiers)
                    await settle()
                    set.logDelivery("click", point.hit ? "native" : "native (element covered by \(point.info["hitTag"]?.stringValue ?? "?"))")
                    return
                } catch let error as NativeInput.Unavailable { reason = error.description }
            } else { reason = "frame offset unknown" }
        } else if button == "middle" { reason = "middle button" }
        do {
            _ = try await agentCall("clickScript", ["ref": .string(target.id), "button": .string(button), "count": .number(Double(count)),
                                                    "alt": .bool(modifiers.contains("Alt")), "ctrl": .bool(modifiers.contains("Control")),
                                                    "meta": .bool(modifiers.contains("Meta")), "shift": .bool(modifiers.contains("Shift"))], frame: target.frame)
        } catch is DialogInterrupted {}
        set.logDelivery("click", "script (\(reason))")
    }

    private func hover(_ target: Target) async throws {
        var reason = "script mode"
        if set.inputMode == .native {
            if let point = try await point(target) {
                do {
                    try NativeInput.move(webView, css: point.css)
                    await settle()
                    if try await agentCall("isHovered", ["ref": .string(target.id)], frame: target.frame).boolValue == true {
                        set.logDelivery("hover", "native")
                        return
                    }
                    reason = "WebKit ignored mouseMoved (window not key)"
                } catch let error as NativeInput.Unavailable { reason = error.description }
            } else { reason = "frame offset unknown" }
        }
        _ = try await agentCall("hoverScript", ["ref": .string(target.id)], frame: target.frame)
        set.logDelivery("hover", "script (\(reason))")
    }

    private func fill(_ target: Target, _ text: String) async throws {
        let info = try await agentCall("point", ["ref": .string(target.id)], frame: target.frame)
        guard info["editable"]?.boolValue == true else {
            throw BrowserFailure("not_editable", "Target is not an enabled editable text field. Take a fresh snapshot and choose a textbox; use browser.select for dropdowns, browser.check for checkboxes/radios, or browser.files.upload for file inputs.")
        }
        let structured = ["date", "time", "datetime-local", "month", "week"].contains(info["type"]?.stringValue ?? "")
        if set.inputMode == .native, !structured {
            do {
                _ = try await agentCall("prepareType", ["ref": .string(target.id)], frame: target.frame)
                try NativeInput.insertText(webView, text)
                await settle()
                let value = try await agentCall("valueOf", ["ref": .string(target.id)], frame: target.frame)
                if value.stringValue == text {
                    set.logDelivery("fill", "native (insertText)")
                    return
                }
                set.logDelivery("fill", "native insertText left \(value.compactText.prefix(40)); retrying by script")
            } catch let error as NativeInput.Unavailable {
                set.logDelivery("fill", "native unavailable: \(error.description)")
            }
        }
        let value = try await agentCall("fillScript", ["ref": .string(target.id), "text": .string(text)], frame: target.frame)
        if structured, value.stringValue != text {
            throw BrowserFailure("invalid_value", "The \(info["type"]?.stringValue ?? "") input rejected this value. Use its required format, for example 2026-09-07 for date or 14:45 for time.")
        }
        set.logDelivery("fill", "script (\(structured ? "structured input" : "script mode"))")
    }

    private func select(_ target: Target, _ values: [String]) async throws {
        _ = try await agentCall("selectOptions", ["ref": .string(target.id), "values": .array(values.map(JSONValue.string))], frame: target.frame)
    }

    private func check(_ target: Target, _ checked: Bool) async throws {
        let current = try await agentCall("checkedState", ["ref": .string(target.id)], frame: target.frame)
        if current.boolValue == checked { return }
        if current.boolValue == true, !checked {
            let info = try await agentCall("point", ["ref": .string(target.id)], frame: target.frame)
            if info["type"]?.stringValue == "radio" {
                throw BrowserFailure("invalid_state", "A selected radio cannot be cleared by clicking it. Select a different radio in its group instead.")
            }
        }
        try await click(ref: target, button: "left", count: 1, modifiers: [])
        if try await agentCall("checkedState", ["ref": .string(target.id)], frame: target.frame).boolValue != checked {
            throw BrowserFailure("invalid_state", "The page did not keep the requested checked state. Inspect the current snapshot and page validation before retrying; do not blindly toggle the control again.")
        }
    }

    private func press(_ chord: String) async throws {
        let key = try NativeInput.parse(chord)
        let trace = ProcessInfo.processInfo.environment["BROWSER_DEMO_TRACE"] != nil
        if set.inputMode == .native {
            do {
                if trace { print("  press: native start") }
                try NativeInput.press(webView, key)
                if trace { print("  press: delivered") }
                await settle()
                if trace { print("  press: settled") }
                set.logDelivery("press", "native")
                return
            } catch let error as NativeInput.Unavailable {
                set.logDelivery("press", "native unavailable: \(error.description)")
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
        do { _ = try await tab.callJS(script, frame: nil, world: tab.agentWorld) } catch is DialogInterrupted {}
        set.logDelivery("press", "script (untrusted KeyboardEvent)")
    }

    // MARK: Screenshot and dialogs

    private func screenshot() async throws -> BrowserResult {
        if action["ref"] != nil, action["fullPage"]?.boolValue == true {
            throw BrowserFailure("invalid_arguments", "Choose either ref for an element screenshot or fullPage:true for the whole page. Remove the other argument before retrying.")
        }
        let format = action["format"]?.stringValue ?? "jpeg"
        guard format == "png" || format == "jpeg" else {
            throw BrowserFailure("unsupported", "WebP screenshots are not supported by this build. Use format \"png\" or \"jpeg\".")
        }
        guard webView.window?.isVisible == true, webView.bounds.width > 0 else {
            throw BrowserFailure("not_visible", "Screenshot needs a visible tab. Call browser.tabs.focus({tabID}) and ask the user to keep BelloCode's window visible.")
        }
        let maxWidth = CGFloat(action["maxWidth"]?.intValue ?? 2_000)
        let image: NSImage
        if action["fullPage"]?.boolValue == true {
            // takeSnapshot only renders the visible area on macOS; createPDF renders the whole document.
            let pdf = try await webView.pdf(configuration: WKPDFConfiguration())
            image = try Self.rasterize(pdf: pdf, maxWidth: maxWidth)
        } else {
            let configuration = WKSnapshotConfiguration()
            if let target = action["ref"]?.stringValue {
                guard let point = try await point(try ref(id: target)) else { throw BrowserFailure("unsupported", "Element screenshots inside this frame are not supported; capture the viewport.") }
                let zoom = webView.pageZoom
                let rect = CGRect(x: (point.rect.minX + point.offset.x) * zoom, y: (point.rect.minY + point.offset.y) * zoom, width: point.rect.width * zoom, height: point.rect.height * zoom)
                    .intersection(webView.bounds)
                guard !rect.isEmpty else { throw BrowserFailure("not_visible", "Element or page has no visible screenshot area. Take a fresh snapshot and choose a visible element, or omit ref to capture the viewport.") }
                configuration.rect = rect
            }
            let width = configuration.rect.isNull ? webView.bounds.width : configuration.rect.width
            if width > maxWidth { configuration.snapshotWidth = NSNumber(value: Double(maxWidth)) }
            image = try await webView.takeSnapshot(configuration: configuration)
        }
        guard let tiff = image.tiffRepresentation else { throw BrowserFailure("operation_failed", "Could not encode the screenshot.") }
        let data = try await Self.encode(tiff: tiff, format: format, quality: action["quality"]?.intValue ?? 80)
        guard data.count <= BrowserContract.maxFileBytes else {
            throw BrowserFailure("too_large", "Screenshot exceeds 5 MiB; capture an element, use jpeg, or a smaller maxWidth.")
        }
        let file = BrowserFile(name: "screenshot.\(format == "jpeg" ? "jpg" : "png")", mime: "image/\(format)", data: data)
        tab.captures.append(file)
        if tab.captures.count > BrowserTab.captureLimit { tab.captures.removeFirst() }
        set.lastScreenshot = data
        return BrowserResult(value: ["tab": tabValue], files: [file])
    }

    private static func rasterize(pdf: Data, maxWidth: CGFloat) throws -> NSImage {
        guard let representation = NSPDFImageRep(data: pdf) else { throw BrowserFailure("operation_failed", "Could not render the page.") }
        let bounds = representation.bounds
        // Pixels, not points: 2x (Retina) density, capped by maxWidth and 16 megapixels like the reference desktop.
        var scale = min(2, maxWidth / max(bounds.width, 1))
        scale = min(scale, (16_000_000 / max(bounds.width * bounds.height, 1)).squareRoot())
        let width = Int((bounds.width * scale).rounded()), height = Int((bounds.height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw BrowserFailure("operation_failed", "Could not render the page.") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        representation.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(bitmap)
        return image
    }

    @concurrent
    private static func encode(tiff: Data, format: String, quality: Int) async throws -> Data {
        guard let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: format == "png" ? .png : .jpeg, properties: format == "png" ? [:] : [.compressionFactor: Double(quality) / 100])
        else { throw BrowserFailure("operation_failed", "Could not encode the screenshot.") }
        return data
    }

    static func mime(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "pdf": "application/pdf"
        case "json": "application/json"
        case "txt", "log", "md": "text/plain"
        case "csv": "text/csv"
        case "html", "htm": "text/html"
        case "zip": "application/zip"
        default: "application/octet-stream"
        }
    }

    private func dialog() throws -> BrowserResult {
        let verb = action["action"]?.stringValue ?? "get"
        if verb != "get" {
            guard tab.dialog != nil else {
                throw BrowserFailure("no_dialog", "This tab has no JavaScript dialog to handle. browser.dialog({tabID,action:\"get\"}) returns null when none is open; continue without accepting or dismissing one.")
            }
            tab.answerDialog(accept: verb == "accept", text: action["promptText"]?.stringValue)
        }
        let dialog: JSONValue = tab.dialog.map { ["type": .string($0.type), "message": .string(String($0.message.prefix(BrowserContract.maxText))), "defaultValue": .string(String($0.defaultValue.prefix(2_048)))] } ?? .null
        return page(["dialog": dialog])
    }
}
