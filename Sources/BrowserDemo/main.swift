// BrowserDemo: the built-in browser's harness (docs/features/browser.md).
//
//   swift run BrowserDemo --selftest    every operation and safety rule against the fixture site (~40 s)
//   swift run BrowserDemo --bridge      the production bridge path: Engine + MockOpenCode + WKWebView
//   swift run BrowserDemo --snapshots   pane PNGs (light and dark) under build/snapshots/
//   swift run BrowserDemo --e2e         one real agent on a zero-cost model (vendored opencode, isolated data)
//   swift run BrowserDemo --all         selftest, bridge and snapshots
//
// All modes open a visible window and exit when done; a watchdog ends a hung run.

import AppKit
import BelloCore
import Foundation

@testable import BrowserKit

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let arguments = Set(CommandLine.arguments.dropFirst())

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
mainMenu.addItem(NSMenuItem(title: "BrowserDemo", action: nil, keyEquivalent: ""))
mainMenu.addItem(editItem)
app.mainMenu = mainMenu

@MainActor
func runDemo() async -> Int32 {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let snapshots = root.appending(path: "build/snapshots")
    try? FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
    let downloads = FileManager.default.temporaryDirectory.appending(path: "bellocode-browser-downloads-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: downloads) }
    let holder = OriginHolder()
    do {
        let route: @Sendable (String, [String]) -> FixtureResponse? = { path, headers in
            Fixtures.route(path, headers: headers, crossOrigin: holder.cross, sameOrigin: holder.same)
        }
        let cross = try await FixtureServer.start(route: route)
        let same = try await FixtureServer.start(route: route)
        holder.set(same: "http://127.0.0.1:\(same.port)", cross: "http://localhost:\(cross.port)")
        defer { same.stop(); cross.stop() }
        var ok = true
        if arguments.contains("--e2e") {
            let binary = root.appending(path: "Vendor/opencode/\(pinnedVersion(root))/opencode")
            return await EndToEnd(fixtures: holder.same, binary: binary, snapshots: snapshots, downloads: downloads).run() ? 0 : 1
        }
        let all = arguments.contains("--all")
        if all || arguments.contains("--selftest") || arguments.contains("--snapshots") {
            let workspace = BrowserWorkspace(engine: nil, isolatedProfiles: true, downloadsFolder: downloads)
            let set = workspace.standaloneSet(key: "selftest", projectDirectory: "/tmp/bellocode-browser-demo")
            let context = BrowserPaneContext(projectName: "bellocode", threadTitle: "Preview the sign-up form", sessionID: nil, projectDirectory: "/tmp/bellocode-browser-demo")
            let harness = Harness(workspace: workspace, set: set, context: context, downloads: downloads)
            if all || arguments.contains("--selftest") {
                ok = await SelfTest(harness: harness, sameOrigin: holder.same, crossOrigin: holder.cross, snapshots: snapshots).run() && ok
            }
            if all || arguments.contains("--snapshots") {
                ok = await Snapshots(harness: harness, origin: holder.same, directory: snapshots).run() && ok
            }
            harness.window.close()
            await workspace.close()
        }
        if all || arguments.contains("--bridge") {
            ok = await BridgeScenario(origin: holder.same, snapshots: snapshots, downloads: downloads).run() && ok
        }
        return ok ? 0 : 1
    } catch {
        print("demo failed: \(error)")
        return 2
    }
}

func pinnedVersion(_ root: URL) -> String {
    OpenCodePin.repositoryVersion(root: root) ?? "unknown"
}

// Watchdog: the demo never outlives a hung run (an opencode child is cleaned up by its stdin lease closing). Wall
// deadline: an uptime-clock timer source may not fire while the process is idle (macOS 27), exactly when it is needed.
let watchdog = DispatchSource.makeTimerSource(queue: .global())
watchdog.schedule(wallDeadline: .now() + (arguments.contains("--e2e") ? 900 : 300))
watchdog.setEventHandler { @Sendable in print("watchdog: timed out"); exit(3) }
watchdog.resume()

Task { @MainActor in
    let code = await runDemo()
    exit(code)
}
app.run()
