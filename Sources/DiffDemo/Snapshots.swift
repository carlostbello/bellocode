import AppKit
import DiffKit
import Engine

/// Renders diff states to PNG in light and dark (views render themselves; the shell cannot take screenshots).
@MainActor
struct Snapshots {
    let window: NSWindow
    let only: Set<String>
    static let directory = URL(fileURLWithPath: "build/snapshots")

    struct Case {
        var name: String
        var size = NSSize(width: 1000, height: 720)
        var make: @MainActor () -> NSViewController
        var prepare: @MainActor (NSViewController) async -> Void = { _ in }
    }

    static var fixtures: [PanelFixture] = []

    func run() async -> Bool {
        defer { Task { for fixture in Self.fixtures { await fixture.stop() } } }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        var written = 0
        for item in cases where only.isEmpty || only.contains(item.name) {
            for dark in [false, true] {
                guard await render(item, dark: dark) else { return false }
                written += 1
            }
        }
        print("wrote \(written) snapshots to \(Self.directory.path)")
        for fixture in Self.fixtures { await fixture.stop() }
        Self.fixtures.removeAll()
        return true
    }

    func render(_ item: Case, dark: Bool) async -> Bool {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let controller = item.make()
        let backdrop = BackdropController(child: controller)
        window.contentViewController = backdrop
        window.setContentSize(item.size)
        window.setFrameOrigin(NSPoint(x: 60, y: 60))
        window.orderFrontRegardless()
        backdrop.view.layoutSubtreeIfNeeded()
        await item.prepare(controller)
        try? await Task.sleep(for: .milliseconds(150))
        backdrop.view.layoutSubtreeIfNeeded()
        backdrop.view.displayIfNeeded()
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = Self.directory.appending(path: "diff-\(item.name)-\(dark ? "dark" : "light").png")
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url) } catch { print("FAIL \(url.path): \(error)"); return false }
        print("wrote \(url.lastPathComponent)")
        window.contentViewController = nil
        return true
    }

    /// Waits until a diff view shows its rows (and syntax).
    static func settle(_ diff: DiffViewController) async {
        for _ in 0..<200 where diff.isBuilding || diff.rowCount == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(120))
    }

    static func diff(_ files: [DiffFile], layout: DiffLayout = .unified, wraps: Bool = false) -> DiffViewController {
        let controller = DiffViewController()
        controller.options.layout = layout
        controller.options.wraps = wraps
        controller.display(files, revertable: Set(files.map(\.path)))
        return controller
    }

    var cases: [Case] {
        [
            Case(name: "unified", make: { Self.diff(Samples.files) }, prepare: { controller in
                guard let diff = controller as? DiffViewController else { return }
                await Self.settle(diff)
            }),
            Case(name: "split", size: NSSize(width: 1280, height: 720), make: { Self.diff(Samples.files, layout: .split) }, prepare: { controller in
                guard let diff = controller as? DiffViewController else { return }
                await Self.settle(diff)
                diff.nextHunk()
                diff.nextHunk()
            }),
            Case(name: "words", size: NSSize(width: 900, height: 420), make: { Self.diff([Samples.files[1]], layout: .split) }, prepare: { controller in
                guard let diff = controller as? DiffViewController else { return }
                await Self.settle(diff)
            }),
            Case(name: "find", size: NSSize(width: 1000, height: 560), make: { Self.diff(Samples.files) }, prepare: { controller in
                guard let diff = controller as? DiffViewController else { return }
                await Self.settle(diff)
                diff.setFindQuery("store")
                try? await Task.sleep(for: .milliseconds(100))
                diff.findNext()
            }),
            Case(name: "large", size: NSSize(width: 1000, height: 600), make: { Self.diff([Samples.large(total: 20_000, changed: 10_000)]) }, prepare: { controller in
                guard let diff = controller as? DiffViewController else { return }
                await Self.settle(diff)
                diff.scroll(toY: diff.contentHeight / 2)
            }),
            Case(name: "panel-uncommitted", size: NSSize(width: 560, height: 820), make: { ChangesPanelController() }, prepare: { controller in
                guard let panel = controller as? ChangesPanelController, let fixture = try? await PanelFixture.make() else { return }
                Snapshots.fixtures.append(fixture)
                panel.display(fixture.model(scope: .uncommitted))
                await PanelFixture.settle(panel)
                if ProcessInfo.processInfo.environment["DIFFDEMO_DEBUG"] != nil { panel.debugDump() }
            }),
            Case(name: "panel-turn", size: NSSize(width: 620, height: 820), make: { ChangesPanelController() }, prepare: { controller in
                guard let panel = controller as? ChangesPanelController, let fixture = try? await PanelFixture.make() else { return }
                Snapshots.fixtures.append(fixture)
                panel.display(fixture.model(scope: .turn(nil)))
                await PanelFixture.settle(panel)
            }),
            Case(name: "wrap", size: NSSize(width: 700, height: 520), make: { Self.diff([Samples.large(total: 400, changed: 60)], wraps: true) }, prepare: { controller in
                guard let diff = controller as? DiffViewController else { return }
                await Self.settle(diff)
            }),
        ]
    }
}

/// Hosts a snapshot's view over an opaque window-background view (cacheDisplay does not draw the window's background).
@MainActor
final class BackdropController: NSViewController {
    let child: NSViewController
    init(child: NSViewController) {
        self.child = child
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let backdrop = BackdropView()
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: backdrop.topAnchor), child.view.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor), child.view.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
        ])
        view = backdrop
    }
}

final class BackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// Placeholder until the benchmark lands.
@MainActor
struct Bench {
    let window: NSWindow
    let arguments: [String]
    func run() async -> Bool { true }
}
