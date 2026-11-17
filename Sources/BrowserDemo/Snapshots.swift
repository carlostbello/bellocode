// Pane snapshots in light and dark: agent control (banner, cursor, outline), inspect mode and the note bar, a
// responsive preset, the find bar, the downloads shelf, a page dialog and the tab strip's ownership markers.
// Files: build/snapshots/browser-<state>-<light|dark>.png.

import AppKit
import Foundation
import OpenCodeKit

@testable import BrowserKit

@MainActor
struct Snapshots {
    let harness: Harness
    let origin: String
    let directory: URL

    private var set: BrowserTabSet { harness.set }

    func run() async -> Bool {
        var written: [URL] = []
        func shoot(_ state: String, appearances: [NSAppearance.Name] = [.aqua, .darkAqua], prepare: (() async -> Void)? = nil) async {
            for name in appearances {
                print("snapshot: \(state) \(name.rawValue)")
                NSApp.appearance = NSAppearance(named: name)
                harness.window.appearance = NSAppearance(named: name)
                await prepare?()
                print("snapshot:   prepared")
                await harness.idle(250)
                let mode = name == .darkAqua ? "dark" : "light"
                if let url = await harness.write("browser-\(state)-\(mode)", to: directory) { written.append(url) }
            }
        }
        // Fresh tabs: an agent tab with the form, a shared tab and a private tab.
        for tab in set.tabs { set.close(tab.id) }
        let opened = await harness.call("tabs.open", ["url": .string(origin + "/form.html")])
        guard let tabID = opened.value?["id"]?.stringValue else { print("snapshot: FAIL no tab"); return false }
        let shared = set.newTab(url: URL(string: origin + "/spa.html"), select: false, shared: true)
        let privateTab = set.newTab(url: URL(string: origin + "/landing.html"), isPrivate: true, select: false)
        try? await shared.waitForLoad()
        try? await privateTab.waitForLoad()
        set.select(tabID)
        harness.window.setContentSize(NSSize(width: 980, height: 760))

        func refs() async -> String { (await harness.call("snapshot", tabID: tabID)).value?["content"]?.stringValue ?? "" }
        func ref(_ content: String, _ role: String, _ name: String) -> String? {
            content.split(separator: "\n").first { $0.contains("[\(role)]") && $0.contains(name) }.flatMap { $0.firstMatch(of: /@(e\d+)/).map { String($0.1) } }
        }

        // Agent control: the agent clicked the email field and is now waiting; banner, cursor and outline show.
        await shoot("agent") {
            let content = await refs()
            if let name = ref(content, "textbox", "Full name") { await harness.call("fill", ["ref": .string(name), "text": "Ada Lovelace"], tabID: tabID) }
            if let email = ref(content, "textbox", "Email") { await harness.call("click", ["ref": .string(email)], tabID: tabID) }
            Task { await harness.call("wait", ["condition": "text", "text": "never", "timeoutMs": 1_500], tabID: tabID) }
            try? await Task.sleep(for: .milliseconds(120))
        }
        try? await Task.sleep(for: .milliseconds(1_600))

        // Inspect mode: hovering the submit button.
        await shoot("inspect") {
            set.startPicking()
            try? await Task.sleep(for: .milliseconds(150))
            // WebKit drops synthesized mouse moves while the window is not key (the shell never activates the app), so
            // the hover is dispatched by script; with a person at the screen the real pointer drives it.
            if let tab = set.tab(tabID) {
                _ = try? await tab.agent("hoverScript", ["ref": .string(ref(await refs(), "button", "Create account") ?? "e1")])
            }
        }
        // The note bar after a pick.
        await shoot("pick-note", appearances: [.aqua]) {
            if let tab = set.tab(tabID), let webView = tab.webView,
               let point = try? await tab.agent("point", ["ref": .string(ref(await refs(), "button", "Create account") ?? "e1")]),
               let x = point["cx"]?.numberValue, let y = point["cy"]?.numberValue {
                if set.pickingTabID == nil { set.startPicking(); try? await Task.sleep(for: .milliseconds(150)) }
                try? NativeInput.move(webView, css: CGPoint(x: x, y: y))
                try? NativeInput.click(webView, css: CGPoint(x: x, y: y), button: "left", count: 1, modifiers: [])
                for _ in 0..<40 where harness.workspace.pendingPick == nil { try? await Task.sleep(for: .milliseconds(50)) }
            }
        }
        harness.workspace.discardPick()
        set.stopPicking()

        // Responsive preset on a page that follows the colour scheme.
        await harness.call("navigate", ["url": .string(origin + "/scheme.html")], tabID: tabID)
        harness.pane.setViewport(ViewportPreset.presets.first { $0.name == "iPhone 16" })
        await shoot("responsive")
        harness.pane.setViewport(nil)

        // Find bar.
        await harness.call("navigate", ["url": .string(origin + "/form.html")], tabID: tabID)
        await shoot("find") {
            harness.pane.showFind()
            harness.pane.findBarSet("plan")
            harness.pane.find("plan", forward: true)
            try? await Task.sleep(for: .milliseconds(200))
        }
        harness.pane.hideFind()

        // Downloads shelf (the report download) and a page dialog.
        await harness.call("navigate", ["url": .string(origin + "/popup.html")], tabID: tabID)
        if let download = ref(await refs(), "link", "Download report") {
            await harness.call("click", ["ref": .string(download)], tabID: tabID)
            for _ in 0..<40 where !harness.workspace.downloads.items.contains(where: { $0.state == .finished }) { try? await Task.sleep(for: .milliseconds(50)) }
        }
        await harness.call("navigate", ["url": .string(origin + "/dialogs.html")], tabID: tabID)
        await harness.idle(300)
        _ = await harness.renderPNG()
        if let confirm = ref(await refs(), "button", "Show confirm") { await harness.call("click", ["ref": .string(confirm)], tabID: tabID) }
        await shoot("dialog-downloads")
        set.tab(tabID)?.answerDialog(accept: false)

        NSApp.appearance = nil
        harness.window.appearance = nil
        for url in written { print("snapshot: wrote \(url.path)") }
        print(written.count >= 10 ? "snapshot: PASS \(written.count) images" : "snapshot: FAIL only \(written.count) images")
        return written.count >= 10
    }
}
