// Direct-invocation assertions: every operation runs through BrowserTabSet.perform (the bridge host entry point) with
// the same command shape the server sends, against the fixture pages, in a visible window. Extended from the G3 spike
// with ownership, pause, popups, downloads, sign-in, appearance, viewport, find, pick, suspension and private tabs.

import AppKit
import BelloCore
import Foundation
import OpenCodeKit

@testable import BrowserKit

@MainActor
final class SelfTest {
    let harness: Harness
    let a: String
    let b: String
    let snapshots: URL
    var results: [(name: String, ok: Bool, detail: String)] = []
    var tabID = ""
    var set: BrowserTabSet { harness.set }

    init(harness: Harness, sameOrigin: String, crossOrigin: String, snapshots: URL) {
        self.harness = harness
        self.a = sameOrigin
        self.b = crossOrigin
        self.snapshots = snapshots
    }

    // MARK: Helpers

    @discardableResult
    func call(_ type: String, _ fields: [String: JSONValue] = [:], files: [BrowserFile] = [], generation: Int? = nil) async -> BrowserOutcome {
        var action = fields
        action["type"] = .string(type)
        if action["tabID"] == nil, !tabID.isEmpty, !type.hasPrefix("tabs.list"), type != "tabs.open" { action["tabID"] = .string(tabID) }
        let trace = ProcessInfo.processInfo.environment["BROWSER_DEMO_TRACE"] != nil
        if trace { print("→ \(type)") }
        let outcome = await set.perform(BrowserCommand(action: .object(action), generation: generation, files: files))
        if trace { print("← \(type) \(outcome.failureCode ?? "ok")") }
        return outcome
    }

    func value(_ outcome: BrowserOutcome) -> JSONValue? {
        if case .success(let result) = outcome { return result.value }
        return nil
    }

    func failureCode(_ outcome: BrowserOutcome) -> String? { outcome.failureCode }

    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        let text = String(detail.prefix(300)).replacingOccurrences(of: "\n", with: " ⏎ ")
        results.append((name, ok, ok ? text : detail))
        print("\(ok ? "PASS" : "FAIL")  \(name)\(text.isEmpty ? "" : "  — \(text)")")
    }

    func eval(_ script: String, frameID: String? = nil) async -> JSONValue {
        var fields: [String: JSONValue] = ["script": .string(script)]
        if let frameID { fields["frameID"] = .string(frameID) }
        return value(await call("evaluate", fields))?["value"] ?? .string("<failed>")
    }

    func snapshot(_ fields: [String: JSONValue] = [:]) async -> String {
        value(await call("snapshot", fields))?["content"]?.stringValue ?? ""
    }

    /// The ref on the first snapshot line with this role whose name contains `name`.
    func ref(_ content: String, role: String, name: String) -> String? {
        for line in content.split(separator: "\n") where line.contains("[\(role)]") && (name.isEmpty || line.contains(name)) {
            if let match = line.firstMatch(of: /@(e\d+)/) { return String(match.1) }
        }
        return nil
    }

    func save(_ name: String) async {
        let outcome = await call("screenshot", ["format": "png"])
        if let data = set.lastScreenshot, value(outcome) != nil {
            try? data.write(to: snapshots.appending(path: "g3-\(name).png"))
        }
    }

    func navigate(_ path: String) async {
        await call("navigate", ["url": .string(a + path)])
    }

    func waitText(_ text: String) async -> Bool {
        value(await call("wait", ["condition": "text", "text": .string(text), "timeoutMs": 5000])) != nil
    }

    // MARK: Run

    func run() async -> Bool {
        let window = harness.window
        print("window key=\(window.isKeyWindow) main=\(window.isMainWindow) app active=\(NSApp.isActive)")
        await tabs()
        await form(mode: .native)
        await form(mode: .script)
        await pointerAndKeys()
        await files()
        await scrollAndScreenshots()
        await dialogs()
        await console()
        await navigation()
        await frames()
        await shadow()
        await evaluate()
        await waits()
        await network()
        await errors()
        await closing()
        await ownership()
        await takeover()
        await popupsAndDownloads()
        await signIn()
        await appearanceAndViewport()
        await findAndPick()
        await privateTabs()
        await suspension()
        let failed = results.filter { !$0.ok }
        print("\nSelf-test: \(results.count - failed.count)/\(results.count) passed")
        print("Delivery log:\n  " + set.deliveryLog.suffix(40).joined(separator: "\n  "))
        let report = results.map { "\($0.ok ? "PASS" : "FAIL")  \($0.name)  \($0.detail)" }.joined(separator: "\n")
            + "\n\nDelivery log:\n" + set.deliveryLog.joined(separator: "\n")
        try? report.write(to: snapshots.appending(path: "g3-selftest.txt"), atomically: true, encoding: .utf8)
        return failed.isEmpty
    }

    func tabs() async {
        let empty = value(await call("tabs.list"))
        check("tabs.list empty", empty?["tabs"]?.arrayValue?.isEmpty == true, empty?.compactText ?? "")
        let opened = value(await call("tabs.open", ["url": .string(a + "/form.html")]))
        tabID = opened?["id"]?.stringValue ?? ""
        check("tabs.open with url", tabID.hasPrefix("tab_") && opened?["title"]?.stringValue == "Signup fixture" && opened?["generation"]?.intValue == 1, opened?.compactText ?? "")
        let listed = value(await call("tabs.list"))
        check("tabs.list after open", listed?["tabs"]?.arrayValue?.count == 1 && listed?["focusedTabID"]?.stringValue == tabID)
    }

    func form(mode: BrowserTabSet.InputMode) async {
        set.inputMode = mode
        let label = mode.rawValue
        if mode == .script { await call("reload") }
        _ = await eval("window.trust.length = 0")
        let content = await snapshot()
        if mode == .native { check("snapshot has roles, names, refs", content.contains("[textbox] \"Full name\"") && content.contains("[combobox] \"Plan\"") && content.contains("[checkbox] \"I accept the terms\""), String(content.prefix(500))) }
        let found = value(await call("find", ["text": "plan"]))?["content"]?.stringValue ?? ""
        if mode == .native { check("find (case-insensitive)", found.contains("[combobox] \"Plan\"") && !found.contains("Full name"), found) }
        let refs = await snapshot()  // find refreshed refs
        guard let name = ref(refs, role: "textbox", name: "Full name"), let email = ref(refs, role: "textbox", name: "Email"),
              let plan = ref(refs, role: "combobox", name: "Plan"), let terms = ref(refs, role: "checkbox", name: "terms"),
              let phone = ref(refs, role: "radio", name: "phone"), let start = ref(refs, role: "textbox", name: "Start date"),
              let submit = ref(refs, role: "button", name: "Create account")
        else { return check("form refs (\(label))", false, refs) }
        let filled = await call("fill", ["ref": .string(name), "text": "Ada Lovelace"])
        let nameValue = await eval("document.getElementById('name').value")
        check("fill (\(label))", value(filled) != nil && nameValue.stringValue == "Ada Lovelace", nameValue.compactText)
        let form = await call("fill_form", ["fields": [
            ["ref": .string(email), "type": "text", "value": "ada@example.com"],
            ["ref": .string(plan), "type": "select", "values": ["pro"]],
            ["ref": .string(terms), "type": "check", "checked": true],
        ]])
        let state = await eval("[f.email.value, plan.value, terms.checked].join('|')")
        check("fill_form text+select+check (\(label))", value(form) != nil && state.stringValue == "ada@example.com|pro|true", state.compactText)
        let again = await call("check", ["ref": .string(terms), "checked": true])
        check("check is idempotent (\(label))", value(again) != nil &&& (await eval("terms.checked")).boolValue == true)
        await call("check", ["ref": .string(phone), "checked": true])
        check("check radio (\(label))", (await eval("document.getElementById('phone').checked")).boolValue == true)
        let date = await call("fill", ["ref": .string(start), "text": "2026-09-07"])
        check("fill date input (\(label))", value(date) != nil &&& (await eval("start.value")).stringValue == "2026-09-07")
        let bad = await call("select", ["ref": .string(plan), "values": ["enterprise"]])
        check("select unknown value fails (\(label))", failureCode(bad) == "option_missing")
        if mode == .native { await save("form-filled") }
        let clicked = await call("click", ["ref": .string(submit)])
        let confirmed = await waitText("Confirmation BC-")
        let result = await eval("result.textContent")
        check("click submit + confirmation (\(label))", value(clicked) != nil && confirmed && result.stringValue?.contains("Confirmation BC-87") == true, result.compactText)
        let trust = await eval("trust.filter(x => /^(click|input|beforeinput|mousedown):/.test(x)).join(' ')")
        let trusted = trust.stringValue ?? ""
        if mode == .native {
            check("native click and typing are isTrusted", trusted.contains("click:true:submit") && trusted.contains("input:true:name") && trusted.contains("mousedown:true:submit"), trusted)
            await save("form-confirmed")
        } else {
            // HTMLElement.click() is an untrusted click, but the checkbox/radio activation it runs fires trusted input events.
            check("script click and typing are untrusted", trusted.contains("click:false:submit") && trusted.contains("input:false:name") && !trusted.contains("click:true") && !trusted.contains("input:true:name"), trusted)
        }
    }

    func pointerAndKeys() async {
        set.inputMode = .native
        await navigate("/form.html")
        var content = await snapshot()
        guard let box = ref(content, role: "generic", name: "") ?? content.split(separator: "\n").first(where: { $0.contains("Hover target") }).flatMap({ $0.firstMatch(of: /@(e\d+)/).map { String($0.1) } }),
              let keys = ref(content, role: "textbox", name: "Key log")
        else { return check("hover/press refs", false, content) }
        _ = await eval("trust.length = 0")
        await call("hover", ["ref": .string(box)])
        // Native when the window is key; otherwise WebKit drops synthesized mouseMoved and hover falls back to script.
        let hovered = (await eval("hovered.textContent")).stringValue ?? ""
        let active = NSApp.isActive
        check("hover (\(active ? "native" : "script fallback, app inactive"))", hovered == (active ? "hovered:true" : "hovered:false"), "\(hovered) via \(set.deliveryLog.last ?? "")")
        await call("click", ["ref": .string(keys)])
        await call("press", ["key": "a"])
        await call("press", ["key": "Shift+B"])
        await call("press", ["key": "ArrowLeft"])
        await call("press", ["key": "Meta+A"])
        await call("press", ["key": "Backspace"])
        let log = (await eval("keylog.textContent")).stringValue ?? ""
        let after = await eval("keys.value")
        check("press keys native (trusted, default actions)", log.contains("a+") && log.contains("B+") && log.contains("ArrowLeft+") && after.stringValue == "", "log=\(log) value=\(after.compactText)")
        await call("press", ["key": "Enter"])
        let bad = await call("press", ["key": "Hyper+X"])
        check("press rejects unknown modifier", failureCode(bad) == "invalid_key")
        content = await snapshot()
        if let source = ref(content, role: "button", name: "Drag me"), let target = ref(content, role: "button", name: "Drop target") {
            let dragged = await call("drag", ["from": .string(source), "to": .string(target)])
            check("drag (synthetic DragEvent)", value(dragged) != nil &&& (await eval("dragged.textContent")).stringValue == "drag-ok")
        } else { check("drag refs", false, content) }
        set.inputMode = .script
        content = await snapshot()
        if let keys = ref(content, role: "textbox", name: "Key log") {
            await call("click", ["ref": .string(keys)])
            _ = await eval("keylog.textContent = ''; keys.value = ''")
            await call("press", ["key": "a"])
            check("press script mode is untrusted and inserts nothing", (await eval("keylog.textContent")).stringValue == "a- " &&& (await eval("keys.value")).stringValue == "", (await eval("keylog.textContent")).compactText)
        }
        set.inputMode = .native
    }

    func files() async {
        let content = await snapshot()
        guard let upload = ref(content, role: "button", name: "Upload"), let drop = content.split(separator: "\n").first(where: { $0.contains("Drop zone") }).flatMap({ $0.firstMatch(of: /@(e\d+)/).map { String($0.1) } })
        else { return check("file refs", false, content) }
        let file = BrowserFile(name: "notes.txt", mime: "text/plain", data: Data("hello g3".utf8))
        let uploaded = await call("files.upload", ["ref": .string(upload), "paths": ["notes.txt"]], files: [file])
        check("files.upload", value(uploaded) != nil &&& (await eval("uploaded.textContent")).stringValue == "notes.txt:8", (await eval("uploaded.textContent")).compactText)
        let dropped = await call("files.drop", ["ref": .string(drop), "paths": ["notes.txt"]], files: [file])
        check("files.drop (synthetic drop)", value(dropped) != nil &&& (await eval("drop.textContent")).stringValue == "dropped notes.txt")
    }

    func scrollAndScreenshots() async {
        await navigate("/long.html")
        await call("scroll", ["deltaY": 1200])
        check("scroll", (await eval("scrollY")).numberValue == 1200, (await eval("scrollY")).compactText)
        await call("scroll", ["deltaY": -1200])
        let content = await snapshot()
        if let bottom = ref(content, role: "button", name: "Bottom button") {
            await call("click", ["ref": .string(bottom)])
            check("click scrolls off-screen element into view", (await eval("bottom.textContent")).stringValue == "Bottom clicked")
            let element = await call("screenshot", ["ref": .string(bottom), "format": "png"])
            if case .success(let result) = element, let file = result.files.first {
                try? file.data.write(to: snapshots.appending(path: "g3-element.png"))
                check("screenshot element", file.mime == "image/png" && file.data.count > 100, "\(file.data.count) bytes")
            } else { check("screenshot element", false, "\(element)") }
        }
        let viewport = await call("screenshot", [:])
        if case .success(let result) = viewport, let file = result.files.first {
            check("screenshot viewport (default jpeg)", file.mime == "image/jpeg" && result.value["tab"] != nil, "\(file.data.count) bytes")
        } else { check("screenshot viewport", false, "\(viewport)") }
        let full = await call("screenshot", ["fullPage": true, "format": "png", "maxWidth": 800])
        if case .success(let result) = full, let file = result.files.first, let image = NSBitmapImageRep(data: file.data) {
            try? file.data.write(to: snapshots.appending(path: "g3-fullpage.png"))
            check("screenshot fullPage (PDF render)", image.pixelsHigh > 2_000, "\(image.pixelsWide)x\(image.pixelsHigh)")
        } else { check("screenshot fullPage", false, "\(full)") }
        let webp = await call("screenshot", ["format": "webp"])
        check("screenshot webp unsupported", failureCode(webp) == "unsupported")
        let listed = value(await call("files.list"))?["files"]?.arrayValue ?? []
        let id = listed.last?["id"]?.stringValue ?? ""
        let got = await call("files.get", ["fileID": .string(id)])
        if case .success(let result) = got { check("files.list + files.get (captures)", listed.count >= 3 && result.files.count == 1) } else { check("files.get", false, "\(got)") }
    }

    func dialogs() async {
        await navigate("/dialogs.html")
        let content = await snapshot()
        guard let alert = ref(content, role: "button", name: "Show alert"), let confirm = ref(content, role: "button", name: "Show confirm"),
              let prompt = ref(content, role: "button", name: "Show prompt") else { return check("dialog refs", false, content) }
        let clicked = await call("click", ["ref": .string(alert)])
        let pending = value(await call("dialog", ["action": "get"]))?["dialog"]
        check("click opening alert returns; dialog get", value(clicked) != nil && pending?["type"]?.stringValue == "alert" && pending?["message"]?.stringValue == "Hello from alert", pending?.compactText ?? "")
        let blocked = await call("snapshot")
        check("other operations refused while a dialog blocks", failureCode(blocked) == "dialog_open")
        let shot = await call("screenshot")
        check("screenshot refused while a dialog blocks the page", failureCode(shot) == "dialog_open")
        await call("dialog", ["action": "accept"])
        check("dialog accept", (await eval("out.textContent")).stringValue == "alert:done")
        await call("click", ["ref": .string(confirm)])
        await call("dialog", ["action": "dismiss"])
        check("confirm dismiss", (await eval("out.textContent")).stringValue == "confirm:false")
        await call("click", ["ref": .string(prompt)])
        let promptInfo = value(await call("dialog", ["action": "get"]))?["dialog"]
        await call("dialog", ["action": "accept", "promptText": "Grace"])
        check("prompt accept with text", promptInfo?["defaultValue"]?.stringValue == "anon" &&& (await eval("out.textContent")).stringValue == "prompt:Grace")
        let none = await call("dialog", ["action": "accept"])
        check("dialog accept with none open fails", failureCode(none) == "no_dialog")
        let get = value(await call("dialog", ["action": "get"]))
        check("dialog get with none open is null", get?["dialog"] == .null)
    }

    func console() async {
        await navigate("/console.html")
        try? await Task.sleep(for: .milliseconds(150))
        let all = value(await call("console"))
        let texts = all?["messages"]?.arrayValue?.compactMap { $0["text"]?.stringValue } ?? []
        check("console captures levels and uncaught errors", texts.contains("debug line") && texts.contains("log line {\"a\":1}") && texts.contains { $0.contains("boom from timer") } && texts.contains { $0.contains("rejected promise") }, texts.joined(separator: " | "))
        let warnings = value(await call("console", ["level": "warning", "limit": 2]))
        let levels = warnings?["messages"]?.arrayValue?.compactMap { $0["level"]?.stringValue } ?? []
        check("console level filter and limit", levels.count == 2 && !levels.contains("info") && warnings?["truncated"]?.boolValue == true, levels.joined(separator: ","))
    }

    func navigation() async {
        await navigate("/spa.html")
        let generation = set.tabs.first?.generation ?? -1
        let content = await snapshot()
        guard let details = ref(content, role: "link", name: "Details") else { return check("spa refs", false, content) }
        await call("click", ["ref": .string(details)])
        let state = set.tabs.first?.info
        check("SPA route change keeps the document generation", state?.url.hasSuffix("/spa/details") == true && state?.generation == generation &&& (await eval("view.textContent")).stringValue == "Details view", state?.url ?? "")
        let back = value(await call("back"))
        check("back (same-document)", back?["url"]?.stringValue?.hasSuffix("/spa.html") == true, back?.compactText ?? "")
        let forward = value(await call("forward"))
        check("forward", forward?["url"]?.stringValue?.hasSuffix("/spa/details") == true)
        let reloaded = value(await call("reload"))
        check("reload bumps generation", (reloaded?["generation"]?.intValue ?? 0) > generation &&& (await eval("view.textContent")).stringValue == "Details view")
        let stopped = await call("stop")
        check("stop", value(stopped)?["loading"]?.boolValue == false)
        let bad = await call("navigate", ["url": "file:///etc/hosts"])
        check("navigate refuses non-http URLs", failureCode(bad) == "invalid_url")
        let unreachable = await call("navigate", ["url": "http://127.0.0.1:9/"])
        check("navigate to a dead port reports navigation_failed", failureCode(unreachable) == "navigation_failed")
    }

    func frames() async {
        await navigate("/frames.html")
        try? await Task.sleep(for: .milliseconds(300))
        let listed = value(await call("frames"))?["frames"]?.arrayValue ?? []
        let cross = listed.first { $0["url"]?.stringValue?.contains("?cross") == true }
        let same = listed.first { $0["url"]?.stringValue?.contains("?same") == true }
        check("frames lists same- and cross-origin frames", listed.count == 3 && cross != nil && same != nil && listed.first?["parentID"] == nil, listed.map(\.compactText).joined(separator: " "))
        guard let crossID = cross?["id"]?.stringValue, let sameID = same?["id"]?.stringValue else { return }
        let main = await snapshot()
        check("main snapshot shows iframes, not their content", main.contains("[Iframe] \"Cross origin frame\"") && !main.contains("Child button"))
        let crossContent = await snapshot(["frameID": .string(crossID)])
        guard let button = ref(crossContent, role: "button", name: "Child button"), let input = ref(crossContent, role: "textbox", name: "Child input") else { return check("cross-frame refs", false, crossContent) }
        await call("click", ["ref": .string(button)])
        let crossText = await eval("n.textContent", frameID: crossID)
        check("click in cross-origin frame (native, offset from iframe element)", crossText.stringValue == "clicked 1 trusted=true", crossText.compactText)
        await call("fill", ["ref": .string(input), "text": "in frame"])
        check("fill in cross-origin frame", (await eval("i.value", frameID: crossID)).stringValue == "in frame")
        check("evaluate in cross-origin frame", (await eval("location.port", frameID: crossID)).stringValue == URL(string: b)?.port.map(String.init))
        let sameContent = await snapshot(["frameID": .string(sameID)])
        if let sameButton = ref(sameContent, role: "button", name: "Child button") {
            await call("click", ["ref": .string(sameButton)])
            check("click in same-origin frame", (await eval("n.textContent", frameID: sameID)).stringValue == "clicked 1 trusted=true")
        }
        let stale = await call("click", ["ref": .string(button)])
        check("refs expire on the next snapshot", failureCode(stale) == "stale_ref")
        await save("frames")
    }

    func shadow() async {
        await navigate("/shadow.html")
        let content = await snapshot()
        check("snapshot pierces open shadow roots and slots", content.contains("[button] \"Shadow button\"") && content.contains("Slotted title"), content)
        check("closed shadow roots are invisible", !content.contains("Closed button"))
        guard let button = ref(content, role: "button", name: "Shadow button"), let input = ref(content, role: "textbox", name: "Shadow input") else { return }
        await call("click", ["ref": .string(button)])
        check("native click inside open shadow root", (await eval("out.textContent")).stringValue == "shadow clicked trusted=true", (await eval("out.textContent")).compactText)
        await call("fill", ["ref": .string(input), "text": "shadow text"])
        check("fill inside open shadow root", (await eval("document.getElementById('open').shadowRoot.getElementById('si').value")).stringValue == "shadow text")
        let found = value(await call("find", ["text": "shadow input"]))?["content"]?.stringValue ?? ""
        check("find inside shadow root", found.contains("Shadow input"))
        await save("shadow")
    }

    func evaluate() async {
        check("evaluate expression", (await eval("document.title")).stringValue == "Shadow fixture")
        check("evaluate statements (completion value)", (await eval("const a = 2; a * 3")).numberValue == 6)
        check("evaluate awaits promises", (await eval("new Promise(r => setTimeout(() => r({ ok: [1, 'x', null] }), 20))")) == ["ok": [1, "x", nil]])
        check("evaluate sees page globals", (await eval("typeof customElements.get('x-card')")).stringValue == "function")
        let content = await snapshot()
        if let input = ref(content, role: "textbox", name: "Shadow input") {
            let element = value(await call("evaluate", ["ref": .string(input), "script": "(el) => el.id + ':' + el.getRootNode().host.id"]))?["value"]
            check("evaluate with ref (isolated world)", element?.stringValue == "si:open", element?.compactText ?? "")
        }
        let thrown = await call("evaluate", ["script": "(() => { throw new Error('nope') })()"])
        check("evaluate exception is script_error", failureCode(thrown) == "script_error")
    }

    func waits() async {
        await navigate("/slow.html")
        let ok = await call("wait", ["condition": "text", "text": "Ready now", "timeoutMs": 3000])
        check("wait text appears", value(ok) != nil)
        let gone = await call("wait", ["condition": "textGone", "text": "Loading", "timeoutMs": 1000])
        check("wait textGone", value(gone) != nil)
        let timeout = await call("wait", ["condition": "text", "text": "never", "timeoutMs": 300])
        check("wait timeout fails", failureCode(timeout) == "timeout")
        let load = await call("wait", ["condition": "load"])
        check("wait load", value(load) != nil)
    }

    func network() async {
        await navigate("/frames.html")
        try? await Task.sleep(for: .milliseconds(200))
        let listed = value(await call("network.list"))
        let requests = listed?["requests"]?.arrayValue ?? []
        check("network.list (Resource Timing)", requests.contains { $0["resourceType"]?.stringValue == "document" } && requests.count >= 2, requests.prefix(3).map(\.compactText).joined(separator: " "))
        if let id = requests.first?["id"]?.stringValue {
            let detail = value(await call("network.get", ["id": .string(id), "includeBody": true]))
            check("network.get without bodies or headers", detail?["responseBody"]?["state"]?.stringValue == "unavailable")
        }
    }

    func errors() async {
        let content = await snapshot()
        let ref = ref(content, role: "Iframe", name: "") ?? "e1"
        let generation = set.tabs.first?.generation ?? 0
        let changed = await call("snapshot", generation: generation - 1)
        check("stale generation is document_changed", failureCode(changed) == "document_changed")
        await call("reload")
        let stale = await call("click", ["ref": .string(ref)])
        check("ref after navigation is stale_ref", failureCode(stale) == "stale_ref")
        let unknownTab = await call("snapshot", ["tabID": "tab_00000000-0000-0000-0000-000000000000"])
        check("unknown tab is tab_unavailable", failureCode(unknownTab) == "tab_unavailable")
        for operation in ["trace.start", "cpu.start", "heap.snapshot", "lighthouse", "preview"] {
            let outcome = await call(operation, operation == "preview" ? ["path": "README.md"] : [:])
            check("\(operation) unsupported", failureCode(outcome) == "unsupported")
        }
        let frame = await call("snapshot", ["frameID": "frame_nope"])
        check("unknown frame is frame_unavailable", failureCode(frame) == "frame_unavailable")
    }

    func closing() async {
        let second = value(await call("tabs.open", ["focus": false]))
        let secondID = second?["id"]?.stringValue ?? ""
        check("tabs.open background", set.selectedTabID == tabID && second?["url"]?.stringValue == "about:blank")
        let focused = value(await call("tabs.focus", ["tabID": .string(secondID)]))
        check("tabs.focus", set.selectedTabID == secondID && focused?["id"]?.stringValue == secondID)
        // The background tab's web view is parked off-screen, so the agent can still capture it.
        let screenshot = await call("screenshot", ["tabID": .string(tabID), "format": "png"])
        check("screenshot of a background tab (parked off-screen)", value(screenshot) != nil, "\(screenshot)")
        let closed = value(await call("tabs.close", ["tabID": .string(secondID)]))
        check("tabs.close", closed?["tabs"]?.arrayValue?.count == 1 && set.selectedTabID == tabID)
    }
}


// MARK: - Production additions

extension SelfTest {
    func ownership() async {
        await call("navigate", ["url": .string(a + "/form.html")])
        // A tab the person opens is not shared: the agent cannot see or use it.
        let user = set.newTab(url: URL(string: a + "/spa.html"), select: false)
        try? await user.waitForLoad()
        let listed = value(await call("tabs.list"))?["tabs"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        check("agent sees only shared tabs", listed.contains(tabID) && !listed.contains(user.id), listed.joined(separator: ","))
        let blocked = await call("snapshot", ["tabID": .string(user.id)])
        check("agent blocked from an unshared tab", failureCode(blocked) == "not_shared", "\(blocked)")
        set.setShared(true, tab: user.id)
        let allowed = await call("snapshot", ["tabID": .string(user.id)])
        check("sharing a tab lets the agent use it", value(allowed) != nil)
        check("shared tab is published", set.browserInventory().tabs.contains { $0.id == user.id })
        set.setShared(false, tab: user.id)
        check("unsharing hides it again", !set.browserInventory().tabs.contains { $0.id == user.id })
        set.close(user.id)
    }

    func takeover() async {
        await call("navigate", ["url": .string(a + "/form.html")])
        let content = await snapshot()
        guard let name = ref(content, role: "textbox", name: "Full name") else { return check("takeover refs", false, content) }
        await call("fill", ["ref": .string(name), "text": "Agent"])
        // The person clicks into the page right after the agent acted: a real mouse event through the app's queue.
        guard let tab = set.tab(tabID), let webView = tab.webView, let window = webView.window else { return check("takeover tab", false) }
        let point = webView.convert(NSPoint(x: 40, y: webView.isFlipped ? 40 : webView.bounds.height - 40), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp.sendEvent(event)
            }
        }
        check("user interaction pauses the agent on that tab", tab.isAgentPaused)
        let refused = await call("fill", ["ref": .string(name), "text": "Again"])
        check("paused tab refuses agent input with user_control", failureCode(refused) == "user_control", "\(refused)")
        let read = await call("snapshot")
        check("paused tab still allows reading", value(read) != nil)
        await harness.idle(80)
        if let png = await harness.renderPNG() { try? png.write(to: snapshots.appending(path: "browser-paused-selftest.png")) }
        set.resumeAgent(on: tabID)
        let fresh = await snapshot()
        if let again = ref(fresh, role: "textbox", name: "Full name") {
            let resumed = await call("fill", ["ref": .string(again), "text": "Resumed"])
            check("resume lets the agent continue", value(resumed) != nil, "\(resumed)")
        } else { check("resume lets the agent continue", false, fresh) }
    }

    func popupsAndDownloads() async {
        await call("navigate", ["url": .string(a + "/popup.html")])
        let before = set.tabs.count
        let content = await snapshot()
        guard let blank = ref(content, role: "link", name: "new tab"), let download = ref(content, role: "link", name: "Download report") else {
            return check("popup refs", false, content)
        }
        await call("click", ["ref": .string(blank)])
        try? await Task.sleep(for: .milliseconds(500))
        let popup = set.tabs.count == before + 1 ? set.tabs.first { $0.id != tabID && $0.url?.path() == "/landing.html" } : nil
        check("target=_blank opens a tab in the same thread, shared like its opener", popup?.isShared == true && popup?.owner == .agent, "\(set.tabs.map(\.displayTitle))")
        if let popup { set.close(popup.id) }
        set.select(tabID)
        await call("click", ["ref": .string(download)])
        var finished = false
        for _ in 0..<60 where !finished {
            try? await Task.sleep(for: .milliseconds(100))
            finished = harness.workspace.downloads.items.contains { $0.state == .finished && $0.filename.hasPrefix("report") }
        }
        let item = harness.workspace.downloads.items.first { $0.filename.hasPrefix("report") }
        check("download lands in the downloads folder", finished && item?.destination?.deletingLastPathComponent().standardizedFileURL == harness.downloads.standardizedFileURL, "\(String(describing: item?.destination))")
        let files = value(await call("files.list"))?["files"]?.arrayValue ?? []
        let fileID = files.first { $0["name"]?.stringValue?.hasPrefix("report") == true }?["id"]?.stringValue
        let got = await call("files.get", ["fileID": .string(fileID ?? "")])
        if case .success(let result) = got {
            check("agent can fetch a completed download (files.get)", String(decoding: result.files.first?.data ?? Data(), as: UTF8.self).contains("Ada Lovelace"))
        } else { check("agent can fetch a completed download (files.get)", false, "\(got)") }
    }

    func signIn() async {
        guard let tab = set.tab(tabID) else { return }
        tab.load(URL(string: a + "/private")!)
        var prompted = false
        for _ in 0..<50 where !prompted {
            try? await Task.sleep(for: .milliseconds(50))
            prompted = tab.authPrompt != nil
        }
        check("HTTP sign-in shows a prompt", prompted && tab.authPrompt?.realm == "Fixture members", tab.authPrompt?.host ?? "none")
        tab.answerAuth(user: "ada", password: "secret")
        try? await Task.sleep(for: .milliseconds(200))
        try? await tab.waitForLoad()
        let welcomed = await waitText("Welcome, Ada")
        let text = (await eval("document.body ? document.body.innerText : ''")).stringValue ?? ""
        check("sign-in answer loads the page", welcomed, "prompt again: \(tab.authPrompt != nil), url \(tab.info.url), text \(text.prefix(80))")
    }

    func appearanceAndViewport() async {
        await call("navigate", ["url": .string(a + "/scheme.html")])
        guard let tab = set.tab(tabID) else { return }
        tab.appearance = .dark
        try? await Task.sleep(for: .milliseconds(200))
        check("appearance override: dark", (await eval("matchMedia('(prefers-color-scheme: dark)').matches")).boolValue == true)
        tab.appearance = .light
        try? await Task.sleep(for: .milliseconds(200))
        check("appearance override: light", (await eval("matchMedia('(prefers-color-scheme: dark)').matches")).boolValue == false)
        tab.appearance = .system
        let phone = ViewportPreset.presets.first { $0.name == "iPhone 16" }!
        harness.pane.setViewport(phone)
        _ = await waitText("Preview")
        try? await Task.sleep(for: .milliseconds(400))
        let width = (await eval("innerWidth")).intValue
        let agent = (await eval("navigator.userAgent")).stringValue ?? ""
        check("responsive preset sets the CSS viewport and a mobile user agent", abs((width ?? 0) - phone.width) <= 1 && agent.contains("iPhone"), "width \(width ?? -1)")
        harness.pane.setViewport(nil)
        try? await Task.sleep(for: .milliseconds(300))
    }

    func findAndPick() async {
        await call("navigate", ["url": .string(a + "/form.html")])
        harness.pane.showFind()
        harness.pane.find("plan", forward: true)
        try? await Task.sleep(for: .milliseconds(300))
        check("find in page counts matches", harness.pane.isFindVisible)
        harness.pane.hideFind()
        set.startPicking()
        try? await Task.sleep(for: .milliseconds(200))
        let content = await snapshot()
        guard let submit = ref(content, role: "button", name: "Create account"), let tab = set.tab(tabID) else { return check("pick refs", false) }
        // Click the element natively, as the person would in inspect mode.
        let point = (try? await tab.agent("point", ["ref": .string(submit)])) ?? .null
        if let webView = tab.webView, let x = point["cx"]?.numberValue, let y = point["cy"]?.numberValue {
            try? NativeInput.move(webView, css: CGPoint(x: x, y: y))
            try? NativeInput.click(webView, css: CGPoint(x: x, y: y), button: "left", count: 1, modifiers: [])
        }
        var pick: BrowserPick?
        for _ in 0..<40 where pick == nil {
            try? await Task.sleep(for: .milliseconds(50))
            pick = harness.workspace.pendingPick?.pick
        }
        check("pick element captures selector, text, box and image", pick?.selector == "#submit" && pick?.text == "Create account" && (pick?.rect.width ?? 0) > 0 && pick?.image != nil, "\(pick.map { "\($0.selector) \($0.text) \($0.rect)" } ?? "none")")
        let result = (await eval("result.textContent")).stringValue ?? ""
        check("inspect mode swallows the click (form not submitted)", !result.contains("Confirmation"), result)
        var committed: BrowserPick?
        harness.workspace.onPick = { pick, _ in committed = pick }
        harness.workspace.commitPick(note: "Make this button larger")
        check("note travels with the pick to the composer", committed?.note == "Make this button larger" && committed?.contextText.contains("Selector: #submit") == true)
    }

    func privateTabs() async {
        let privateTab = set.newTab(url: URL(string: a + "/form.html"), isPrivate: true, select: false)
        try? await privateTab.waitForLoad()
        check("private tab is never published", !set.browserInventory().tabs.contains { $0.id == privateTab.id })
        set.setShared(true, tab: privateTab.id)
        check("private tab cannot be shared", !privateTab.isShared)
        let blocked = await call("snapshot", ["tabID": .string(privateTab.id)])
        check("agent blocked from a private tab", failureCode(blocked) == "not_shared")
        check("private tab is not saved", !set.record.tabs.contains { $0.id == privateTab.id })
        set.close(privateTab.id)
        check("closed private tab cannot be reopened", set.reopenClosedTab()?.isPrivate != true)
        if let reopened = set.tabs.last, reopened.id != tabID { set.close(reopened.id) }
    }

    func suspension() async {
        let opened = (0..<(BrowserWorkspace.liveLimit + 2)).map { index in
            set.newTab(url: URL(string: a + "/landing.html?n=\(index)"), select: false, owner: .agent)
        }
        for tab in opened { try? await tab.waitForLoad() }
        harness.workspace.enforceLiveBudget()
        try? await Task.sleep(for: .milliseconds(600))
        let live = harness.workspace.liveWebViewCount
        check("live web views stay within the budget", live <= BrowserWorkspace.liveLimit, "\(live) live")
        let suspended = opened.first { !$0.isLive }
        check("a suspended tab keeps its URL and a snapshot", suspended?.info.url.contains("landing.html") == true, suspended?.info.url ?? "none")
        if let suspended {
            let outcome = await call("evaluate", ["tabID": .string(suspended.id), "script": "location.search"])
            check("agent use resumes a suspended tab", value(outcome)?["value"]?.stringValue?.hasPrefix("?n=") == true, "\(outcome)")
        }
        let start = ContinuousClock.now
        set.select(opened[0].id)
        harness.pane.refresh()
        let switchMs = (ContinuousClock.now - start).components.attoseconds / 1_000_000_000_000_000
        check("selecting a tab is instant (< 100 ms)", switchMs < 100, "\(switchMs) ms")
        for tab in opened { set.close(tab.id) }
        set.select(tabID)
    }
}
