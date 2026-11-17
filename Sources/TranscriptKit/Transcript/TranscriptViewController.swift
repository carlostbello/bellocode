import AppKit
import BelloCore
import DesignSystem

/// The transcript as a view controller for one thread. Mount it, call `bind(_:anchor:)` once, and release it with the
/// thread; `close()` (also run when the view disappears for good) cancels everything the transcript owns.
///
/// Commands (menu items with a nil target reach it through the responder chain when the transcript is focused; the
/// shell forwards them otherwise): `copy:`, `selectAll:`, `copyTranscriptMessage:`, `copyTranscriptMarkdown:`,
/// `copyTranscriptCode:`, `findInTranscript:`, `findNextInTranscript:`, `findPreviousInTranscript:`,
/// `useSelectionForTranscriptFind:`, `jumpToLatestOutput:`, `showPreviousTurn:`, `showNextTurn:`, `showLastFailure:`.
@MainActor
public final class TranscriptViewController: NSViewController {
    public let controller: TranscriptController

    public init(controller: TranscriptController = TranscriptController()) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = controller.container
        view.setAccessibilityLabel("Transcript")
    }

    /// The view that takes focus for the transcript region.
    public var focusView: NSView { controller.tableView }

    public func bind(_ source: any TranscriptSource, anchor: TranscriptAnchor? = nil) {
        _ = view
        controller.bind(source, anchor: anchor)
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        if controller.contentWidth == 0 { controller.updateContentWidth() }
    }

    public func close() { controller.close() }

    isolated deinit { controller.close() }

    // Forward transcript commands when the view controller is in the chain but the table is not first responder.
    @objc public func findInTranscript(_ sender: Any?) { controller.showFind() }
    @objc public func findNextInTranscript(_ sender: Any?) { controller.findNext() }
    @objc public func findPreviousInTranscript(_ sender: Any?) { controller.findPrevious() }
    @objc public func useSelectionForTranscriptFind(_ sender: Any?) { controller.useSelectionForFind() }
    @objc public func jumpToLatestOutput(_ sender: Any?) { controller.jumpToLatest() }
    @objc public func showPreviousTurn(_ sender: Any?) { controller.goToTurn(previous: true) }
    @objc public func showNextTurn(_ sender: Any?) { controller.goToTurn(previous: false) }
    @objc public func showLastFailure(_ sender: Any?) { controller.goToLastFailure() }
    @objc public func copyTranscriptMessage(_ sender: Any?) { controller.copyMessage() }
    @objc public func copyTranscriptMarkdown(_ sender: Any?) { controller.copyAsMarkdown() }
    @objc public func copyTranscriptCode(_ sender: Any?) { controller.copyCode() }

    /// Whether a transcript command can run now (for the shell's menu validation).
    public func canPerform(_ action: Selector) -> Bool {
        controller.tableView.validate(action, tag: 0) ?? false
    }
}
