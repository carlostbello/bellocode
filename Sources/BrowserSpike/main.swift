// SPIKE (gate G3). `BrowserSpike --selftest` runs the fixture assertions; `BrowserSpike --e2e` drives a real opencode
// agent session through the bridge. Both open a visible window and exit when done.

import AppKit
import BrowserKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let arguments = Array(CommandLine.arguments.dropFirst())

// A standard Edit menu: unhandled key equivalents from the web view (⌘A, ⌘C, ⌘V, ⌘Z) come back to it, as in the app.
let mainMenu = NSMenu()
let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
mainMenu.addItem(NSMenuItem(title: "BrowserSpike", action: nil, keyEquivalent: ""))
mainMenu.addItem(editItem)
app.mainMenu = mainMenu

@MainActor
func runSpike() async -> Int32 {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let snapshots = root.appending(path: "build/snapshots")
    try? FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
    let holder = OriginHolder()
    do {
        let cross = try await FixtureServer.start { path in Fixtures.route(path, crossOrigin: holder.cross, sameOrigin: holder.same) }
        let same = try await FixtureServer.start { path in Fixtures.route(path, crossOrigin: holder.cross, sameOrigin: holder.same) }
        holder.set(same: "http://127.0.0.1:\(same.port)", cross: "http://localhost:\(cross.port)")
        defer { same.stop(); cross.stop() }
        let host = BrowserHost()
        let window = SpikeWindow(host: host)
        defer { host.shutdown(); window.window.close() }
        if arguments.contains("--e2e") {
            let binary = root.appending(path: "Vendor/opencode/2.3.0/opencode")
            return await EndToEnd(host: host, fixtures: holder.same, binary: binary, snapshots: snapshots, prompt: arguments.contains("--prompt") ? arguments[arguments.firstIndex(of: "--prompt")! + 1] : nil).run() ? 0 : 1
        }
        return await SelfTest(host: host, sameOrigin: holder.same, crossOrigin: holder.cross, snapshots: snapshots).run() ? 0 : 1
    } catch {
        print("spike failed: \(error)")
        return 2
    }
}

// Watchdog: the spike never outlives a hung run (its opencode child is cleaned up by the stdin lease closing).
let watchdog = DispatchSource.makeTimerSource(queue: .global())
watchdog.schedule(deadline: .now() + (arguments.contains("--e2e") ? 600 : 120))
watchdog.setEventHandler { @Sendable in print("watchdog: timed out"); exit(3) }
watchdog.resume()

Task { @MainActor in
    let code = await runSpike()
    exit(code)
}
app.run()
