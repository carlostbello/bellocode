import AgentUI
import AppKit
import DesignSystem
import Engine

/// The pending approvals and questions of the displayed thread (AgentUI's stack), pinned above the composer. Its
/// height follows its content (zero when nothing is pending). A draft has no requests and shows nothing.
///
/// Arriving requests never take focus: the stack is focusable only through F6 / ⇧F6 or a click, so typing in the
/// composer continues (AGENTS.md UX rule 4 keeps it visible instead).
@MainActor
final class RequestStackSurfaceController: NSViewController, FocusableSurface {
    let context: ThreadSurfaceContext
    private(set) var model: PendingRequestStackModel?
    private var stackView: NSView?

    init(context: ThreadSurfaceContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = NSView()
        container.setAccessibilityLabel("Pending requests")
        if let thread = context.thread {
            let (view, model) = AgentUIFactories.pendingRequestStack(
                thread: thread, engine: context.engine, style: AppStyle.agentUI, attachedOverlap: DS.Size.attachedOverlap)
            self.model = model
            stackView = view
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        } else {
            let empty = container.heightAnchor.constraint(equalToConstant: 0)
            empty.isActive = true
        }
        view = container
    }

    /// Requests waiting (for focus cycling: an empty stack is skipped).
    var hasRequests: Bool { !(model?.requests.isEmpty ?? true) }

    var preferredFocusView: NSView? { hasRequests ? stackView : nil }
}
