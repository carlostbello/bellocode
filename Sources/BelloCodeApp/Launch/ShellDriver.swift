import AppKit
import BelloCore
import ComposerKit
import Engine

/// Drives the real window from inside the process, through the same views and commands a person uses: select,
/// type into the composer, send, open pickers, act on request cards. Used by `--snapshot` and the scripted
/// end-to-end tests (the shell cannot synthesize input or take screenshots; AGENTS.md "Environment").
@MainActor
struct ShellDriver {
    let controller: MainWindowController

    var workspace: WorkspaceController { controller.workspace }
    var engine: Engine { controller.workspace.engine }
    var window: NSWindow { controller.window! }
    var composerSurface: ComposerSurfaceController? { controller.container.composerController }
    var composer: ComposerViewController? { composerSurface?.composer }
    var requestStack: RequestStackSurfaceController? { controller.container.requestStackController }

    /// Selects and waits until the content area shows it with a composer (the container rebuilds on the next turn).
    func select(_ selection: ShellSelection) async -> Bool {
        workspace.select(selection)
        return await waitUntil(timeout: .seconds(5)) {
            controller.container.displayed == selection && controller.container.composerController != nil
        }
    }

    /// Types into the composer as an edit (undoable, like typing).
    func type(_ text: String) {
        guard let composer else { return }
        window.makeFirstResponder(composer.textView)
        composer.textView.insertText(text, replacementRange: composer.textView.selectedRange())
    }

    /// The menu's Send (⌘↩) through the responder chain, as a key press or click would.
    func send() { perform(.sendMessage) }

    /// A menu command through this window's responder chain (first responder → … → window controller), as its menu
    /// item or shortcut would deliver it. Works when the window is not key (tests, snapshots).
    func perform(_ command: ShellCommand) {
        let responder: NSResponder = window.firstResponder ?? window
        if !responder.tryToPerform(command.selector, with: nil) {
            NSApp.sendAction(command.selector, to: nil, from: nil)
        }
    }

    /// Lets observation loops, layout and SwiftUI updates run.
    func settle(_ rounds: Int = 6) {
        for _ in 0..<rounds {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    /// Windows shown above the main window (popovers, the completion panel, utility windows), front last.
    var overlayWindows: [NSWindow] {
        NSApp.orderedWindows.reversed().filter { other in
            other !== window && other.isVisible && other.frame.intersects(window.frame) && other.alphaValue > 0
        }
    }

    /// Closes popovers and panels left open by a scenario.
    func closeOverlays() {
        for other in overlayWindows where other.className.contains("Popover") || other is NSPanel {
            other.orderOut(nil)
        }
    }
}
