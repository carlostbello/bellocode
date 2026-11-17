import AppKit
import ComposerKit
import DesignSystem
import Foundation

/// Window, composer, fake hosts, input synthesis, checks and snapshots.
@MainActor
final class Harness {
    /// Reports itself key so focus rendering shows in snapshots (the demo runs without activating, to leave the
    /// user's frontmost app alone).
    final class DemoWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }
    /// Window background drawn in `draw(_:)`, so snapshots include it in both appearances.
    final class BackgroundView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            DS.Color.canvas.setFill()
            dirtyRect.fill()
        }
    }

    let window: NSWindow
    var composer: ComposerViewController
    let projectRoot: URL
    var failures: [String] = []
    var checks = 0
    var metrics: [String: String] = [:]
    let snapshotFolder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "build/snapshots")

    init(interactive: Bool) {
        projectRoot = Harness.makeProject()
        window = DemoWindow(
            contentRect: NSRect(x: 120, y: 120, width: 760, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = "ComposerDemo"
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        // In-process renders cannot capture vibrancy: glass surfaces draw their solid fallback.
        DSGlassView.forcesSolidFallback = true
        composer = ComposerViewController()
        mount(composer)
    }

    /// Stand-ins for the shell's pickers (agent, model, effort, permission mode), built from the same DesignSystem
    /// ghost select buttons, so snapshots show the whole controls bar.
    static func demoControls() -> (leading: [NSView], trailing: [NSView]) {
        func select(_ title: String, _ symbol: String) -> DSSelectButton {
            let button = DSSelectButton(title: title, symbolName: symbol, chevron: .down, size: .small)
            button.variant = .ghost
            button.isMuted = true
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: DS.Size.composerControl).isActive = true
            return button
        }
        return ([select("Build", "hammer"), select("Claude Sonnet 4.5", "sparkle"), select("High", "cpu"), select("Ask", "lock")], [])
    }

    // MARK: Setup

    static func makeProject() -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ComposerDemo-project-\(ProcessInfo.processInfo.processIdentifier)")
        let files = [
            "Sources/App/main.swift", "Sources/App/AppDelegate.swift", "Sources/ComposerKit/ComposerView.swift",
            "Sources/ComposerKit/Tokens.swift", "Tests/AppTests/MainTests.swift", "README.md", "Package.swift",
            "node_modules/left-pad/index.js",
        ]
        for file in files {
            let url = root.appending(path: file)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("// \(file)\n".utf8).write(to: url)
        }
        return root
    }

    func configuration(sendKey: SendKey = .returnKey) -> ComposerConfiguration {
        var configuration = ComposerConfiguration()
        configuration.sendKey = sendKey
        configuration.completionProviders = [FilePathCompletionProvider(root: projectRoot), StaticSlashCommandProvider.builtIn]
        configuration.completionDebounce = .milliseconds(30)
        configuration.draftSaveDelay = .milliseconds(60)
        return configuration
    }

    /// A fresh composer in the window (each scenario starts clean).
    func reset(sendKey: SendKey = .returnKey, style: ComposerStyle = ComposerStyle()) {
        composer.view.removeFromSuperview()
        composer = ComposerViewController(style: style, configuration: configuration(sendKey: sendKey))
        mount(composer)
    }

    private func mount(_ composer: ComposerViewController) {
        if composer.configuration.completionProviders.isEmpty { composer.configuration = configuration() }
        if !(window.contentView is BackgroundView) { window.contentView = BackgroundView() }
        let content = window.contentView!
        content.subviews.forEach { $0.removeFromSuperview() }

        let transcript = NSTextField(wrappingLabelWithString: "Transcript area. The composer below is the real ComposerKit view with a fake thread.")
        transcript.textColor = DS.Color.text3
        transcript.font = DS.TextRole.body.font
        transcript.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(transcript)

        let controls = Self.demoControls()
        composer.leadingControls.spacing = 2
        composer.leadingControls.setViews(controls.leading, in: .leading)
        composer.trailingControls.setViews(controls.trailing, in: .leading)
        composer.contextLineView = ComposerContextStrip(
            items: [
                .init(symbolName: "folder", text: "bellocode"), .init(symbolName: "arrow.triangle.branch", text: "main"),
                .init(symbolName: "square.on.square.dashed", text: "local checkout"),
            ],
            hint: "↩ sends · ⇧↩ new line")

        let view = composer.view
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        let width = view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            transcript.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            transcript.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            transcript.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            view.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            width,
            view.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        window.makeFirstResponder(composer.textView)
        content.layoutSubtreeIfNeeded()
    }

    func showInteractive() {
        let host = FakeHost(key: "demo", prompts: ["Explain the build script", "Add a test for the token model"])
        composer.host = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(composer.textView)
    }

    // MARK: Running

    func run(_ names: [String]) async -> Int32 {
        window.orderFrontRegardless()
        window.makeKey()
        let scenarios = Scenarios(self)
        let all = scenarios.all
        let selected = names.isEmpty ? all.map(\.0) : names
        for name in selected {
            guard let scenario = all.first(where: { $0.0 == name })?.1 else {
                print("unknown scenario \(name); known: \(all.map(\.0).joined(separator: ", "))")
                return 2
            }
            let before = failures.count
            reset()
            await scenario()
            print(failures.count == before ? "PASS \(name)" : "FAIL \(name)")
        }
        for (key, value) in metrics.sorted(by: { $0.key < $1.key }) { print("metric \(key): \(value)") }
        print("\(checks) checks, \(failures.count) failures")
        for failure in failures { print("  - \(failure)") }
        window.close()
        return failures.isEmpty ? 0 : 1
    }

    func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #fileID, line: Int = #line) {
        checks += 1
        if !condition() { failures.append("\(message) (\(file):\(line))") }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
        checks += 1
        if actual != expected { failures.append("\(message): got \(actual), expected \(expected) (line \(line))") }
    }

    func pause(_ milliseconds: Int = 30) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    // MARK: Input

    var textView: ComposerTextView { composer.textView }
    var text: String { textView.string }

    /// Text as an input method without composition delivers it.
    /// Each call is its own run-loop pass, like a real keystroke, so undo groups match typing.
    func type(_ string: String) async {
        textView.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
        await tick()
    }

    /// Lets the run loop turn (closes the undo group of the previous "event").
    /// Ends the current "event": lets the run loop go idle, which closes the undo manager's event group as the end of
    /// a real key event does.
    func tick() async {
        if let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
        ) {
            NSApp.postEvent(event, atStart: false)
        }
        try? await Task.sleep(for: .milliseconds(5))
    }

    enum Key {
        case returnKey, up, down, left, right, escape, tab, backspace

        var code: UInt16 {
            switch self {
            case .returnKey: 36
            case .up: 126
            case .down: 125
            case .left: 123
            case .right: 124
            case .escape: 53
            case .tab: 48
            case .backspace: 51
            }
        }

        var characters: String {
            switch self {
            case .returnKey: "\r"
            case .up: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
            case .down: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
            case .left: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
            case .right: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
            case .escape: "\u{1B}"
            case .tab: "\t"
            case .backspace: "\u{7F}"
            }
        }
    }

    /// A real key event through the window: key equivalents, then the first responder's `keyDown`, the input
    /// context and `doCommand(by:)`, as for a keyboard.
    func press(_ key: Key, _ modifiers: NSEvent.ModifierFlags = []) async {
        var flags = modifiers
        if [.up, .down, .left, .right].contains(where: { $0 == key }) { flags.insert([.numericPad, .function]) }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: key.characters,
            charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code
        ) else {
            failures.append("could not make key event")
            return
        }
        if window.firstResponder !== textView { window.makeFirstResponder(textView) }
        window.sendEvent(event)
        await tick()
    }

    func flags(_ modifiers: NSEvent.ModifierFlags) {
        guard let event = NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55
        ) else { return }
        textView.flagsChanged(with: event)
    }

    func undo() async {
        textView.undoManager?.undo()
        await tick()
    }

    func redo() async {
        textView.undoManager?.redo()
        await tick()
    }

    func newPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("ComposerDemo-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    static func samplePNG(size: NSSize = NSSize(width: 160, height: 100)) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: NSRect(origin: .zero, size: size), angle: 35)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: 20, y: 20, width: 70, height: 40), xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// All subviews, depth first.
    func allViews(_ root: NSView? = nil) -> [NSView] {
        let start = root ?? composer.view
        return [start] + start.subviews.flatMap { allViews($0) }
    }

    // MARK: Snapshots

    /// Renders the window content (plus the completion popover, composited where it sits) in light and dark.
    func snapshot(_ name: String) async {
        try? FileManager.default.createDirectory(at: snapshotFolder, withIntermediateDirectories: true)
        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let appearance = NSAppearance(named: appearanceName), let content = window.contentView else { continue }
            window.appearance = appearance
            await composer.settle()
            content.layoutSubtreeIfNeeded()
            content.needsDisplay = true
            content.displayIfNeeded()
            guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
            appearance.performAsCurrentDrawingAppearance {
                // Without font smoothing: `cacheDisplay` darkens stems (implementation-guide.md, snapshots).
                if let context = NSGraphicsContext(bitmapImageRep: rep) {
                    context.cgContext.setAllowsFontSmoothing(false)
                    context.cgContext.setShouldSmoothFonts(false)
                    content.displayIgnoringOpacity(content.bounds, in: context)
                }
                if let popover = composer.completionView, let panel = popover.window {
                    popover.appearance = appearance
                    let frame = window.convertFromScreen(panel.frame)
                    if let popoverRep = popover.bitmapImageRepForCachingDisplay(in: popover.bounds) {
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: popoverRep)
                        NSColor.clear.set()
                        NSRect(origin: .zero, size: popoverRep.size).fill(using: .copy)
                        NSGraphicsContext.restoreGraphicsState()
                        if let context = NSGraphicsContext(bitmapImageRep: popoverRep) {
                            context.cgContext.setAllowsFontSmoothing(false)
                            context.cgContext.setShouldSmoothFonts(false)
                            popover.displayIgnoringOpacity(popover.bounds, in: context)
                        }
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                        let shadow = NSShadow()
                        shadow.shadowBlurRadius = 10
                        shadow.shadowOffset = NSSize(width: 0, height: -3)
                        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
                        shadow.set()
                        popoverRep.draw(in: frame)
                        NSGraphicsContext.restoreGraphicsState()
                    }
                }
            }
            let url = snapshotFolder.appending(path: "composer-\(name)-\(suffix).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.appearance = nil
    }
}
