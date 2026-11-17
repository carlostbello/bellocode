import AppKit
import BelloCore
import Engine
import TranscriptKit

/// Mounts TranscriptKit's transcript for one displayed thread: binds the thread model, restores and saves the scroll
/// anchor through `ThreadModel.updateUIState`, follows the text-size setting, opens sub-agent threads through the
/// shell, and runs the transcript's menu commands when the transcript is not the first responder.
@MainActor
final class TranscriptSurfaceController: NSViewController, FocusableSurface, TranscriptControllerDelegate {
    let context: ThreadSurfaceContext
    let transcript = TranscriptViewController()
    private let settings: AppSettings?
    private var settingsLoop: ObservationLoop?
    private var revealTask: Task<Void, Never>?

    init(context: ThreadSurfaceContext, settings: AppSettings?) {
        self.context = context
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var controller: TranscriptController { transcript.controller }
    var preferredFocusView: NSView? { transcript.focusView }

    override func loadView() {
        let container = NSView()
        container.setAccessibilityLabel("Transcript")
        addChild(transcript)
        transcript.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(transcript.view)
        NSLayoutConstraint.activate([
            transcript.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            transcript.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            transcript.view.topAnchor.constraint(equalTo: container.topAnchor),
            transcript.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        controller.delegate = self
        if let settings {
            settingsLoop = ObservationLoop { [weak self] in
                guard let self else { return }
                let size = CGFloat(settings.baseFontSize)
                if self.controller.baseFontSize != size { self.controller.baseFontSize = size }
            }
        }
        if let thread = context.thread {
            let state = thread.uiState
            let anchor = state.scrollAnchor.map { TranscriptAnchor(messageID: $0, offset: state.scrollOffset) }
            transcript.bind(thread, anchor: anchor)
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        saveAnchor()
    }

    isolated deinit {
        revealTask?.cancel()
        settingsLoop?.cancel()
        transcript.close()
    }

    /// Persists where the reader is (nil anchor = the bottom).
    func saveAnchor() {
        guard let thread = context.thread else { return }
        let anchor = controller.scrollAnchor
        let id = anchor?.messageID
        let offset = anchor?.offset ?? 0
        guard thread.uiState.scrollAnchor != id || abs(thread.uiState.scrollOffset - offset) > 0.5 else { return }
        thread.updateUIState { state in
            state.scrollAnchor = id
            state.scrollOffset = offset
        }
    }

    /// Reveals a message (a search hit): scrolls it to the top (paging in older history if needed), then finds the
    /// query in the transcript so the match is highlighted and centred. Uses TranscriptKit's `restore(anchor:)` and find.
    func reveal(messageID: MessageID, query: String) {
        controller.restore(anchor: TranscriptAnchor(messageID: messageID, offset: 0))
        revealTask?.cancel()
        let words = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard let term = words.max(by: { $0.count < $1.count }), !term.isEmpty else { return }
        revealTask = Task { @MainActor [weak self] in
            // Wait (bounded) until the message is in view, so find starts from it.
            for _ in 0..<40 {
                guard let self, !Task.isCancelled else { return }
                if self.controller.scrollAnchor?.messageID == messageID || self.controller.scrollAnchor == nil { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self, !Task.isCancelled else { return }
            self.controller.findBarField.stringValue = term
            self.controller.showFind()
        }
    }

    // MARK: TranscriptControllerDelegate

    func transcript(_ controller: TranscriptController, openChildThread id: SessionID) {
        context.onOpenThread?(id)
    }

    func transcriptAnchorDidChange(_ controller: TranscriptController) { saveAnchor() }

    // MARK: Commands (when the transcript is not first responder)

    static let commands: [ShellCommand: Selector] = [
        .findInThread: #selector(TranscriptTableView.findInTranscript(_:)),
        .findNext: #selector(TranscriptTableView.findNextInTranscript(_:)),
        .findPrevious: #selector(TranscriptTableView.findPreviousInTranscript(_:)),
        .useSelectionForFind: #selector(TranscriptTableView.useSelectionForTranscriptFind(_:)),
        .copyMessage: #selector(TranscriptTableView.copyTranscriptMessage(_:)),
        .copyAsMarkdown: #selector(TranscriptTableView.copyTranscriptMarkdown(_:)),
        .copyCode: #selector(TranscriptTableView.copyTranscriptCode(_:)),
        .jumpToLatest: #selector(TranscriptTableView.jumpToLatestOutput(_:)),
        .previousTurn: #selector(TranscriptTableView.showPreviousTurn(_:)),
        .nextTurn: #selector(TranscriptTableView.showNextTurn(_:)),
        .lastFailure: #selector(TranscriptTableView.showLastFailure(_:)),
    ]

    var availableCommands: Set<ShellCommand> {
        Set(Self.commands.filter { transcript.canPerform($0.value) }.keys)
    }

    func perform(_ command: ShellCommand) {
        switch command {
        case .findInThread: controller.showFind()
        case .findNext: controller.findNext()
        case .findPrevious: controller.findPrevious()
        case .useSelectionForFind: controller.useSelectionForFind()
        case .copyMessage: controller.copyMessage()
        case .copyAsMarkdown: controller.copyAsMarkdown()
        case .copyCode: controller.copyCode()
        case .jumpToLatest: controller.jumpToLatest()
        case .previousTurn: controller.goToTurn(previous: true)
        case .nextTurn: controller.goToTurn(previous: false)
        case .lastFailure: controller.goToLastFailure()
        default: break
        }
    }
}
