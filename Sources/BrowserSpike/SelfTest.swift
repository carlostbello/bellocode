// SPIKE (gate G3). Direct-invocation assertions: every implemented operation runs through BrowserHost.perform with
// the same command shape the server sends, against the fixture pages, in a visible window.

import AppKit
import BrowserKit
import Foundation

@MainActor
final class SelfTest {
    let host: BrowserHost
    let a: String
    let b: String
    let snapshots: URL
    var results: [(name: String, ok: Bool, detail: String)] = []
    var tabID = ""

    init(host: BrowserHost, sameOrigin: String, crossOrigin: String, snapshots: URL) {
        self.host = host
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
        return await host.perform(BrowserCommand(action: .object(action), generation: generation, files: files))
    }

    func value(_ outcome: BrowserOutcome) -> JSONValue? {
        if case .success(let result) = outcome { return result.value }
        return nil
    }

    func failureCode(_ outcome: BrowserOutcome) -> String? {
        if case .failure(let failure) = outcome { return failure.code }
        return nil
    }

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
        value(await call("snapshot", fields))?["content"]?.string ?? ""
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
        if let data = host.lastScreenshot, value(outcome) != nil {
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
        let failed = results.filter { !$0.ok }
        print("\nSelf-test: \(results.count - failed.count)/\(results.count) passed")
        print("Delivery log:\n  " + host.deliveryLog.suffix(40).joined(separator: "\n  "))
        let report = results.map { "\($0.ok ? "PASS" : "FAIL")  \($0.name)  \($0.detail)" }.joined(separator: "\n")
            + "\n\nDelivery log:\n" + host.deliveryLog.joined(separator: "\n")
        try? report.write(to: snapshots.appending(path: "g3-selftest.txt"), atomically: true, encoding: .utf8)
        return failed.isEmpty
    }

    func tabs() async {
        let empty = value(await call("tabs.list"))
        check("tabs.list empty", empty?["tabs"]?.array?.isEmpty == true, empty?.compactText ?? "")
        let opened = value(await call("tabs.open", ["url": .string(a + "/form.html")]))
        tabID = opened?["id"]?.string ?? ""
        check("tabs.open with url", tabID.hasPrefix("tab_") && opened?["title"]?.string == "Signup fixture" && opened?["generation"]?.int == 1, opened?.compactText ?? "")
        let listed = value(await call("tabs.list"))
        check("tabs.list after open", listed?["tabs"]?.array?.count == 1 && listed?["focusedTabID"]?.string == tabID)
    }

    func form(mode: BrowserHost.InputMode) async {
        host.inputMode = mode
        let label = mode.rawValue
        if mode == .script { await call("reload") }
        _ = await eval("window.trust.length = 0")
        let content = await snapshot()
        if mode == .native { check("snapshot has roles, names, refs", content.contains("[textbox] \"Full name\"") && content.contains("[combobox] \"Plan\"") && content.contains("[checkbox] \"I accept the terms\""), String(content.prefix(500))) }
        let found = value(await call("find", ["text": "plan"]))?["content"]?.string ?? ""
        if mode == .native { check("find (case-insensitive)", found.contains("[combobox] \"Plan\"") && !found.contains("Full name"), found) }
        let refs = await snapshot()  // find refreshed refs
        guard let name = ref(refs, role: "textbox", name: "Full name"), let email = ref(refs, role: "textbox", name: "Email"),
              let plan = ref(refs, role: "combobox", name: "Plan"), let terms = ref(refs, role: "checkbox", name: "terms"),
              let phone = ref(refs, role: "radio", name: "phone"), let start = ref(refs, role: "textbox", name: "Start date"),
              let submit = ref(refs, role: "button", name: "Create account")
        else { return check("form refs (\(label))", false, refs) }
        let filled = await call("fill", ["ref": .string(name), "text": "Ada Lovelace"])
        let nameValue = await eval("document.getElementById('name').value")
        check("fill (\(label))", value(filled) != nil && nameValue.string == "Ada Lovelace", nameValue.compactText)
        let form = await call("fill_form", ["fields": [
            ["ref": .string(email), "type": "text", "value": "ada@example.com"],
            ["ref": .string(plan), "type": "select", "values": ["pro"]],
            ["ref": .string(terms), "type": "check", "checked": true],
        ]])
        let state = await eval("[f.email.value, plan.value, terms.checked].join('|')")
        check("fill_form text+select+check (\(label))", value(form) != nil && state.string == "ada@example.com|pro|true", state.compactText)
        let again = await call("check", ["ref": .string(terms), "checked": true])
        check("check is idempotent (\(label))", value(again) != nil &&& (await eval("terms.checked")).bool == true)
        await call("check", ["ref": .string(phone), "checked": true])
        check("check radio (\(label))", (await eval("document.getElementById('phone').checked")).bool == true)
        let date = await call("fill", ["ref": .string(start), "text": "2026-09-07"])
        check("fill date input (\(label))", value(date) != nil &&& (await eval("start.value")).string == "2026-09-07")
        let bad = await call("select", ["ref": .string(plan), "values": ["enterprise"]])
        check("select unknown value fails (\(label))", failureCode(bad) == "option_missing")
        if mode == .native { await save("form-filled") }
        let clicked = await call("click", ["ref": .string(submit)])
        let confirmed = await waitText("Confirmation BC-")
        let result = await eval("result.textContent")
        check("click submit + confirmation (\(label))", value(clicked) != nil && confirmed && result.string?.contains("Confirmation BC-87") == true, result.compactText)
        let trust = await eval("trust.filter(x => /^(click|input|beforeinput|mousedown):/.test(x)).join(' ')")
        let trusted = trust.string ?? ""
        if mode == .native {
            check("native click and typing are isTrusted", trusted.contains("click:true:submit") && trusted.contains("input:true:name") && trusted.contains("mousedown:true:submit"), trusted)
            await save("form-confirmed")
        } else {
            // HTMLElement.click() is an untrusted click, but the checkbox/radio activation it runs fires trusted input events.
            check("script click and typing are untrusted", trusted.contains("click:false:submit") && trusted.contains("input:false:name") && !trusted.contains("click:true") && !trusted.contains("input:true:name"), trusted)
        }
    }

    func pointerAndKeys() async {
        host.inputMode = .native
        await navigate("/form.html")
        var content = await snapshot()
        guard let box = ref(content, role: "generic", name: "") ?? content.split(separator: "\n").first(where: { $0.contains("Hover target") }).flatMap({ $0.firstMatch(of: /@(e\d+)/).map { String($0.1) } }),
              let keys = ref(content, role: "textbox", name: "Key log")
        else { return check("hover/press refs", false, content) }
        await call("hover", ["ref": .string(box)])
        check("hover (native mouseMoved)", (await eval("hovered.textContent")).string == "hovered:true", (await eval("hovered.textContent")).compactText)
        await call("click", ["ref": .string(keys)])
        await call("press", ["key": "a"])
        await call("press", ["key": "Shift+B"])
        await call("press", ["key": "ArrowLeft"])
        await call("press", ["key": "Meta+A"])
        await call("press", ["key": "Backspace"])
        let log = (await eval("keylog.textContent")).string ?? ""
        let after = await eval("keys.value")
        check("press keys native (trusted, default actions)", log.contains("a+") && log.contains("B+") && log.contains("ArrowLeft+") && after.string == "", "log=\(log) value=\(after.compactText)")
        await call("press", ["key": "Enter"])
        let bad = await call("press", ["key": "Hyper+X"])
        check("press rejects unknown modifier", failureCode(bad) == "invalid_key")
        content = await snapshot()
        if let source = ref(content, role: "button", name: "Drag me"), let target = ref(content, role: "button", name: "Drop target") {
            let dragged = await call("drag", ["from": .string(source), "to": .string(target)])
            check("drag (synthetic DragEvent)", value(dragged) != nil &&& (await eval("dragged.textContent")).string == "drag-ok")
        } else { check("drag refs", false, content) }
        host.inputMode = .script
        content = await snapshot()
        if let keys = ref(content, role: "textbox", name: "Key log") {
            await call("click", ["ref": .string(keys)])
            _ = await eval("keylog.textContent = ''; keys.value = ''")
            await call("press", ["key": "a"])
            check("press script mode is untrusted and inserts nothing", (await eval("keylog.textContent")).string == "a- " &&& (await eval("keys.value")).string == "", (await eval("keylog.textContent")).compactText)
        }
        host.inputMode = .native
    }

    func files() async {
        let content = await snapshot()
        guard let upload = ref(content, role: "button", name: "Upload"), let drop = content.split(separator: "\n").first(where: { $0.contains("Drop zone") }).flatMap({ $0.firstMatch(of: /@(e\d+)/).map { String($0.1) } })
        else { return check("file refs", false, content) }
        let file = BrowserFile(name: "notes.txt", mime: "text/plain", data: Data("hello g3".utf8))
        let uploaded = await call("files.upload", ["ref": .string(upload), "paths": ["notes.txt"]], files: [file])
        check("files.upload", value(uploaded) != nil &&& (await eval("uploaded.textContent")).string == "notes.txt:8", (await eval("uploaded.textContent")).compactText)
        let dropped = await call("files.drop", ["ref": .string(drop), "paths": ["notes.txt"]], files: [file])
        check("files.drop (synthetic drop)", value(dropped) != nil &&& (await eval("drop.textContent")).string == "dropped notes.txt")
    }

    func scrollAndScreenshots() async {
        await navigate("/long.html")
        await call("scroll", ["deltaY": 1200])
        check("scroll", (await eval("scrollY")).double == 1200, (await eval("scrollY")).compactText)
        await call("scroll", ["deltaY": -1200])
        let content = await snapshot()
        if let bottom = ref(content, role: "button", name: "Bottom button") {
            await call("click", ["ref": .string(bottom)])
            check("click scrolls off-screen element into view", (await eval("bottom.textContent")).string == "Bottom clicked")
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
        let listed = value(await call("files.list"))?["files"]?.array ?? []
        let id = listed.last?["id"]?.string ?? ""
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
        check("click opening alert returns; dialog get", value(clicked) != nil && pending?["type"]?.string == "alert" && pending?["message"]?.string == "Hello from alert", pending?.compactText ?? "")
        let blocked = await call("snapshot")
        check("other operations refused while a dialog blocks", failureCode(blocked) == "dialog_open")
        let shot = await call("screenshot")
        check("screenshot refused while a dialog blocks the page", failureCode(shot) == "dialog_open")
        await call("dialog", ["action": "accept"])
        check("dialog accept", (await eval("out.textContent")).string == "alert:done")
        await call("click", ["ref": .string(confirm)])
        await call("dialog", ["action": "dismiss"])
        check("confirm dismiss", (await eval("out.textContent")).string == "confirm:false")
        await call("click", ["ref": .string(prompt)])
        let promptInfo = value(await call("dialog", ["action": "get"]))?["dialog"]
        await call("dialog", ["action": "accept", "promptText": "Grace"])
        check("prompt accept with text", promptInfo?["defaultValue"]?.string == "anon" &&& (await eval("out.textContent")).string == "prompt:Grace")
        let none = await call("dialog", ["action": "accept"])
        check("dialog accept with none open fails", failureCode(none) == "no_dialog")
        let get = value(await call("dialog", ["action": "get"]))
        check("dialog get with none open is null", get?["dialog"] == .null)
    }

    func console() async {
        await navigate("/console.html")
        try? await Task.sleep(for: .milliseconds(150))
        let all = value(await call("console"))
        let texts = all?["messages"]?.array?.compactMap { $0["text"]?.string } ?? []
        check("console captures levels and uncaught errors", texts.contains("debug line") && texts.contains("log line {\"a\":1}") && texts.contains { $0.contains("boom from timer") } && texts.contains { $0.contains("rejected promise") }, texts.joined(separator: " | "))
        let warnings = value(await call("console", ["level": "warning", "limit": 2]))
        let levels = warnings?["messages"]?.array?.compactMap { $0["level"]?.string } ?? []
        check("console level filter and limit", levels.count == 2 && !levels.contains("info") && warnings?["truncated"]?.bool == true, levels.joined(separator: ","))
    }

    func navigation() async {
        await navigate("/spa.html")
        let generation = host.tabs.first?.state.generation ?? -1
        let content = await snapshot()
        guard let details = ref(content, role: "link", name: "Details") else { return check("spa refs", false, content) }
        await call("click", ["ref": .string(details)])
        let state = host.tabs.first?.state
        check("SPA route change keeps the document generation", state?.url.hasSuffix("/spa/details") == true && state?.generation == generation &&& (await eval("view.textContent")).string == "Details view", state?.url ?? "")
        let back = value(await call("back"))
        check("back (same-document)", back?["url"]?.string?.hasSuffix("/spa.html") == true, back?.compactText ?? "")
        let forward = value(await call("forward"))
        check("forward", forward?["url"]?.string?.hasSuffix("/spa/details") == true)
        let reloaded = value(await call("reload"))
        check("reload bumps generation", (reloaded?["generation"]?.int ?? 0) > generation &&& (await eval("view.textContent")).string == "Details view")
        let stopped = await call("stop")
        check("stop", value(stopped)?["loading"]?.bool == false)
        let bad = await call("navigate", ["url": "file:///etc/hosts"])
        check("navigate refuses non-http URLs", failureCode(bad) == "invalid_url")
        let unreachable = await call("navigate", ["url": "http://127.0.0.1:9/"])
        check("navigate to a dead port reports navigation_failed", failureCode(unreachable) == "navigation_failed")
    }

    func frames() async {
        await navigate("/frames.html")
        try? await Task.sleep(for: .milliseconds(300))
        let listed = value(await call("frames"))?["frames"]?.array ?? []
        let cross = listed.first { $0["url"]?.string?.contains("?cross") == true }
        let same = listed.first { $0["url"]?.string?.contains("?same") == true }
        check("frames lists same- and cross-origin frames", listed.count == 3 && cross != nil && same != nil && listed.first?["parentID"] == nil, listed.map(\.compactText).joined(separator: " "))
        guard let crossID = cross?["id"]?.string, let sameID = same?["id"]?.string else { return }
        let main = await snapshot()
        check("main snapshot shows iframes, not their content", main.contains("[Iframe] \"Cross origin frame\"") && !main.contains("Child button"))
        let crossContent = await snapshot(["frameID": .string(crossID)])
        guard let button = ref(crossContent, role: "button", name: "Child button"), let input = ref(crossContent, role: "textbox", name: "Child input") else { return check("cross-frame refs", false, crossContent) }
        await call("click", ["ref": .string(button)])
        let crossText = await eval("n.textContent", frameID: crossID)
        check("click in cross-origin frame (native, offset from iframe element)", crossText.string == "clicked 1 trusted=true", crossText.compactText)
        await call("fill", ["ref": .string(input), "text": "in frame"])
        check("fill in cross-origin frame", (await eval("i.value", frameID: crossID)).string == "in frame")
        check("evaluate in cross-origin frame", (await eval("location.port", frameID: crossID)).string == URL(string: b)?.port.map(String.init))
        let sameContent = await snapshot(["frameID": .string(sameID)])
        if let sameButton = ref(sameContent, role: "button", name: "Child button") {
            await call("click", ["ref": .string(sameButton)])
            check("click in same-origin frame", (await eval("n.textContent", frameID: sameID)).string == "clicked 1 trusted=true")
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
        check("native click inside open shadow root", (await eval("out.textContent")).string == "shadow clicked trusted=true", (await eval("out.textContent")).compactText)
        await call("fill", ["ref": .string(input), "text": "shadow text"])
        check("fill inside open shadow root", (await eval("document.getElementById('open').shadowRoot.getElementById('si').value")).string == "shadow text")
        let found = value(await call("find", ["text": "shadow input"]))?["content"]?.string ?? ""
        check("find inside shadow root", found.contains("Shadow input"))
        await save("shadow")
    }

    func evaluate() async {
        check("evaluate expression", (await eval("document.title")).string == "Shadow fixture")
        check("evaluate statements (completion value)", (await eval("const a = 2; a * 3")).double == 6)
        check("evaluate awaits promises", (await eval("new Promise(r => setTimeout(() => r({ ok: [1, 'x', null] }), 20))")) == ["ok": [1, "x", nil]])
        check("evaluate sees page globals", (await eval("typeof customElements.get('x-card')")).string == "function")
        let content = await snapshot()
        if let input = ref(content, role: "textbox", name: "Shadow input") {
            let element = value(await call("evaluate", ["ref": .string(input), "script": "(el) => el.id + ':' + el.getRootNode().host.id"]))?["value"]
            check("evaluate with ref (isolated world)", element?.string == "si:open", element?.compactText ?? "")
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
        let requests = listed?["requests"]?.array ?? []
        check("network.list (Resource Timing)", requests.contains { $0["resourceType"]?.string == "document" } && requests.count >= 2, requests.prefix(3).map(\.compactText).joined(separator: " "))
        if let id = requests.first?["id"]?.string {
            let detail = value(await call("network.get", ["id": .string(id), "includeBody": true]))
            check("network.get without bodies or headers", detail?["responseBody"]?["state"]?.string == "unavailable")
        }
    }

    func errors() async {
        let content = await snapshot()
        let ref = ref(content, role: "Iframe", name: "") ?? "e1"
        let generation = host.tabs.first?.state.generation ?? 0
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
        let secondID = second?["id"]?.string ?? ""
        check("tabs.open background", host.focusedTabID == tabID && second?["url"]?.string == "about:blank")
        let focused = value(await call("tabs.focus", ["tabID": .string(secondID)]))
        check("tabs.focus", host.focusedTabID == secondID && focused?["id"]?.string == secondID)
        let screenshot = await call("screenshot", ["tabID": .string(tabID)])
        check("screenshot of a background tab fails", failureCode(screenshot) == "not_visible")
        let closed = value(await call("tabs.close", ["tabID": .string(secondID)]))
        check("tabs.close", closed?["tabs"]?.array?.count == 1 && host.focusedTabID == tabID)
    }
}

infix operator &&& : LogicalConjunctionPrecedence
/// Non-short-circuiting `and`, so both sides may contain `await`.
func &&& (lhs: Bool, rhs: Bool) -> Bool { lhs && rhs }
