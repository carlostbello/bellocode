// SPIKE G1-B: row-based transcript prototype (docs/spikes/G1-B-rows.md).
//
//   swift build -c release --product TranscriptSpikeB
//   .build/release/TranscriptSpikeB                      # interactive: 10,000 messages, find bar, Edit menu
//   .build/release/TranscriptSpikeB --scenario S3        # one scenario; writes build/spikes/G1-B/S3.json
//   .build/release/TranscriptSpikeB --scenario all       # S1...S7 then S8 in one process
//   options: --stream-seconds N (default 65), --scroll-speed X (multiplier, default 1)

import AppKit
import TranscriptKit

@MainActor
final class SpikeApp: NSObject, NSApplicationDelegate, NSSearchFieldDelegate {
    let window: NSWindow
    let host = NSView()
    let findField = NSSearchField()
    let status = NSTextField(labelWithString: "")
    var runner: ScenarioRunner?
    let scenario: String?

    init(scenario: String?) {
        self.scenario = scenario
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 900),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        window.title = "G1-B rows spike"
        window.isReleasedWhenClosed = false
        let content = NSView()
        findField.placeholderString = "Find in transcript (Return for next)"
        findField.target = self
        findField.action = #selector(findNext(_:))
        findField.sendsSearchStringImmediately = false
        findField.sendsWholeSearchString = true
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        for view in [findField, status, host] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            findField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            findField.widthAnchor.constraint(equalToConstant: 320),
            findField.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: findField.trailingAnchor, constant: 10),
            status.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -10),
            status.centerYAnchor.constraint(equalTo: findField.centerYAnchor),
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.topAnchor.constraint(equalTo: findField.bottomAnchor, constant: 6),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.setFrame(NSRect(x: 80, y: 80, width: 900, height: 900), display: false)
        if scenario != nil { window.level = .floating }  // keep the window unoccluded so the display link runs
        window.orderFrontRegardless()
        if scenario == nil { NSApp.activate() }

        let runner = ScenarioRunner(app: self)
        self.runner = runner
        Task {
            if let scenario {
                await runner.run(scenario)
                exit(0)
            } else {
                await runner.openTranscript()
                status.stringValue = "\(runner.workload.items.count) messages · \(runner.workload.stats.totalUTF8Bytes / 1024) KB"
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func findNext(_ sender: Any?) {
        let query = findField.stringValue
        guard let controller = runner?.controller else { return }
        Task {
            let match = await controller.findNext(query)
            status.stringValue = match == nil ? "No match (index ready: \(controller.searchIndexReady))" : "Found in message \(match!.itemID)"
            window.makeFirstResponder(controller.tableView)
        }
    }

    @objc func focusFind(_ sender: Any?) { window.makeFirstResponder(findField) }

    @objc func jumpToLatest(_ sender: Any?) { runner?.controller?.jumpToLatest(sender) }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(SpikeTableView.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find…", action: #selector(focusFind(_:)), keyEquivalent: "f").target = self
        editItem.submenu = edit
        main.addItem(editItem)
        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        let jump = view.addItem(withTitle: "Jump to Latest", action: #selector(jumpToLatest(_:)), keyEquivalent: "\u{F701}")
        jump.keyEquivalentModifierMask = [.command]
        jump.target = self
        viewItem.submenu = view
        main.addItem(viewItem)
        NSApp.mainMenu = main
    }
}

let arguments = CommandLine.arguments
let scenarioName = arguments.firstIndex(of: "--scenario").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
if arguments.contains("--workload-stats") {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try! encoder.encode(SpikeWorkload.generate().stats), as: UTF8.self))
    exit(0)
}
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = SpikeApp(scenario: scenarioName)
application.delegate = delegate
application.run()
