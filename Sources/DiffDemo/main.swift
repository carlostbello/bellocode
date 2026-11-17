// M2-C diff harness (docs/features/diff-git.md).
//
//   swift run DiffDemo                       # interactive: the sample diff
//   swift run DiffDemo --snapshots [names]   # PNGs (light + dark) into build/snapshots/diff-*.png
//   swift build -c release --product DiffDemo && .build/release/DiffDemo --bench
//                                            # scroll benchmarks; build/snapshots/diff-bench.json

import AppKit
import DiffKit

@MainActor
final class DemoApp: NSObject, NSApplicationDelegate {
    let window: NSWindow
    let arguments: [String]

    init(arguments: [String]) {
        self.arguments = arguments
        window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 1000, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let quit = NSMenu()
        quit.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem()
        item.submenu = quit
        let main = NSMenu()
        main.addItem(item)
        NSApp.mainMenu = main
        window.isReleasedWhenClosed = false
        window.title = "Diff"
        Task {
            if arguments.contains("--snapshots") {
                let only = Set(arguments.drop { $0 != "--snapshots" }.dropFirst().prefix { !$0.hasPrefix("--") })
                let ok = await Snapshots(window: window, only: only).run()
                exit(ok ? 0 : 1)
            } else if arguments.contains("--bench") {
                window.level = .floating
                let ok = await Bench(window: window, arguments: arguments).run()
                exit(ok ? 0 : 1)
            } else {
                let controller = DiffViewController()
                window.contentViewController = controller
                window.setFrame(NSRect(x: 80, y: 80, width: 1000, height: 760), display: false)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                controller.display(Samples.files, revertable: Set(Samples.files.map(\.path)))
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = DemoApp(arguments: CommandLine.arguments)
app.delegate = delegate
app.run()
