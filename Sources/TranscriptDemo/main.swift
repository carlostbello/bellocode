// M1-F transcript harness (docs/features/transcript.md).
//
//   swift run TranscriptDemo                          # interactive: the mixed sample transcript
//   swift run TranscriptDemo --snapshots              # PNGs (light + dark) into build/snapshots/transcript-*.png
//   swift build -c release --product TranscriptDemo
//   .build/release/TranscriptDemo --scenario all      # S1…S8 against MockOpenCode; build/spikes/M1-F/*.json
//   options: --scenario S3, --stream-seconds N, --large N (messages, default 10,000)

import AppKit
import BelloCore
import TranscriptKit

@MainActor
final class DemoApp: NSObject, NSApplicationDelegate {
    let window: NSWindow
    let arguments: [String]

    init(arguments: [String]) {
        self.arguments = arguments
        window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 900, height: 900),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = DemoMenu.make()
        window.isReleasedWhenClosed = false
        window.title = "Transcript"
        Task {
            if arguments.contains("--snapshots") {
                let only = Set(arguments.drop { $0 != "--snapshots" }.dropFirst().prefix { !$0.hasPrefix("--") })
                let ok = await SnapshotScenarios(window: window, only: only).run()
                exit(ok ? 0 : 1)
            } else if let index = arguments.firstIndex(of: "--scenario"), index + 1 < arguments.count {
                window.level = .floating  // unoccluded so the display link runs
                let runner = ScenarioRunner(window: window, arguments: arguments)
                let ok = await runner.run(arguments[index + 1])
                exit(ok ? 0 : 1)
            } else {
                let controller = TranscriptViewController()
                window.contentViewController = controller
                window.setFrame(NSRect(x: 80, y: 80, width: 900, height: 900), display: false)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                controller.bind(StaticTranscriptSource(messages: TranscriptSamples.mixed()))
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum DemoMenu {
    @MainActor static func make() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(TranscriptTableView.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Copy as Markdown", action: #selector(TranscriptTableView.copyTranscriptMarkdown(_:)), keyEquivalent: "C")
            .keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find…", action: #selector(TranscriptTableView.findInTranscript(_:)), keyEquivalent: "f")
        edit.addItem(withTitle: "Find Next", action: #selector(TranscriptTableView.findNextInTranscript(_:)), keyEquivalent: "g")
        edit.addItem(withTitle: "Find Previous", action: #selector(TranscriptTableView.findPreviousInTranscript(_:)), keyEquivalent: "G")
        edit.addItem(withTitle: "Use Selection for Find", action: #selector(TranscriptTableView.useSelectionForTranscriptFind(_:)), keyEquivalent: "e")
        editItem.submenu = edit
        main.addItem(editItem)
        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Jump to Latest", action: #selector(TranscriptTableView.jumpToLatestOutput(_:)), keyEquivalent: "J")
        view.addItem(withTitle: "Previous Turn", action: #selector(TranscriptTableView.showPreviousTurn(_:)), keyEquivalent: "\u{F700}")
            .keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: "Next Turn", action: #selector(TranscriptTableView.showNextTurn(_:)), keyEquivalent: "\u{F701}")
            .keyEquivalentModifierMask = [.command, .option]
        viewItem.submenu = view
        main.addItem(viewItem)
        return main
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = DemoApp(arguments: CommandLine.arguments)
application.delegate = delegate
application.run()
