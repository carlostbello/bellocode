import AppKit
import DiffKit
import Engine
import SwiftUI

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
            Case(name: "comment", size: NSSize(width: 900, height: 560), make: { CommentDemoController() }, prepare: { controller in
                guard let demo = controller as? CommentDemoController else { return }
                await Snapshots.settle(demo.diff)
                demo.diff.scroll(toFile: "Sources/Auth/LoginService.swift")
                demo.diff.selectLines(path: "Sources/Auth/LoginService.swift", side: .new, 11...14)
                demo.diff.commentMarks = Set((33...35).map { DiffCommentMark(path: "Sources/Auth/LoginService.swift", side: .new, line: $0) })
            }),
            Case(name: "pickers", size: NSSize(width: 760, height: 470), make: { PickerDemoController() }, prepare: { controller in
                guard let demo = controller as? PickerDemoController, let fixture = try? await PanelFixture.make() else { return }
                Snapshots.fixtures.append(fixture)
                await demo.show(fixture)
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

/// A diff with a selection and comment marks above the comment editor (popovers are separate windows, so the editor is
/// rendered in place for the snapshot).
@MainActor
final class CommentDemoController: NSViewController {
    let diff = Snapshots.diff([Samples.files[0]])
    let editor = CommentEditorController(location: "Sources/Auth/LoginService.swift:11–14")

    override func loadView() {
        addChild(diff)
        addChild(editor)
        editor.text = "Hash with a salt and a slow KDF (PBKDF2 or Argon2), not a bare SHA-256."
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 10
        card.borderColor = .separatorColor
        card.fillColor = .windowBackgroundColor
        card.contentView = editor.view
        let stack = NSStackView(views: [diff.view, card])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .centerX
        diff.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        diff.view.heightAnchor.constraint(equalToConstant: 330).isActive = true
        view = stack
    }
}

/// The workspace and branch pickers' popover content side by side, plus the controls-bar buttons.
@MainActor
final class PickerDemoController: NSViewController {
    let container = NSStackView()

    override func loadView() {
        container.orientation = .vertical
        container.alignment = .leading
        container.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view = container
    }

    func show(_ fixture: PanelFixture) async {
        _ = try? await fixture.runner.run(["branch", "release/1.2", "main"], in: fixture.repo.path)
        _ = try? await fixture.runner.run(["worktree", "add", "-q", "-b", "fix/flaky-test", fixture.root.appending(path: "wt-fix").path, "main"], in: fixture.repo.path)
        let draft = WorkspaceDraft(git: fixture.git, projectDirectory: fixture.repo.path, projectID: nil)
        draft.load()
        for _ in 0..<200 where draft.repository.phase == .loading || draft.worktrees.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        draft.mode = .newWorktree
        draft.repository.loadBranches(force: true)
        for _ in 0..<200 where draft.repository.branches.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        let buttons = NSStackView(views: [host(WorkspacePickerButton(draft: draft)), host(BranchPickerButton(draft: draft))])
        buttons.spacing = 16
        let workspace = host(WorkspacePickerView(draft: draft) {})
        let branch = host(BranchPickerView(draft: draft) {})
        for view in [workspace, branch] {
            view.wantsLayer = true
            view.layer?.cornerRadius = 10
            view.layer?.borderWidth = 1
            view.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        let pickers = NSStackView(views: [workspace, branch])
        pickers.alignment = .top
        pickers.spacing = 16
        container.addArrangedSubview(buttons)
        container.addArrangedSubview(pickers)
    }

    private func host<V: View>(_ view: V) -> NSView {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        return hosting
    }
}
