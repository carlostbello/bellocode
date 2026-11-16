import AppKit
import os
import UniformTypeIdentifiers

/// The composer: attachment chips, an auto-growing `NSTextView`, an inline error line and a controls bar with host
/// slots, in a rounded card, plus a context-line slot below it.
///
/// Mounting: create one per window (or chat pane), set `style`, `configuration` and `host`, add `view` with Auto
/// Layout (it sizes its own height), and swap `host` when the selected thread changes. Menu items can target the
/// first responder with `sendPrompt:`, `queuePrompt:`, `steerPrompt:`, `stopAgent:` and `focusComposer:`.
///
/// Threading: `@MainActor`. Completion queries, thumbnails and image conversion run off the main actor.
@MainActor
public final class ComposerViewController: NSViewController, NSMenuItemValidation {
    public let controller = ComposerController()
    public var style: ComposerStyle { didSet { applyStyle() } }
    public var configuration: ComposerConfiguration { didSet { applyConfiguration() } }

    /// The thread being edited. Setting it saves the previous thread's draft and shows the new one's (with selection).
    public var host: (any ComposerHost)? {
        get { controller.host }
        set {
            loadViewIfNeeded()
            controller.attach(newValue)
        }
    }

    /// Host-provided pickers (model, permission mode, agent) at the leading and trailing ends of the controls bar.
    public let leadingControls = NSStackView()
    public let trailingControls = NSStackView()
    /// A line below the card for project, branch and worktree context. `nil` hides it.
    public var contextLineView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            installContextLine()
        }
    }

    /// Called when the composer's preferred height changes (it also updates its own constraints).
    public var onHeightChange: ((CGFloat) -> Void)?

    public private(set) var attachments: AttachmentList
    public let completion: CompletionSession
    public private(set) var textView: ComposerTextView!

    // Views
    private let contentStorage = NSTextContentStorage()
    private let scrollView = NSScrollView()
    private var card: ComposerCardView!
    private let cardStack = NSStackView()
    private let rootStack = NSStackView()
    private let strip = AttachmentStripView()
    private var errorView: ComposerErrorView!
    private let controlsBar = NSStackView()
    private let sendButton = ComposerSendButton()
    private let stopButton = NSButton()
    private let followUpMenuButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var heightConstraint: NSLayoutConstraint!
    private var completionPanel: CompletionPanel?
    private var completionList: CompletionListView?

    // State
    private let undo = UndoManager()
    private var isApplying = false
    private var isPerformingEdit = false
    /// Between `shouldChangeText` and `textDidChange`: selection changes there come from the edit itself.
    private var textEditInProgress = false
    private var alternateHeld = false
    private var heightTask: Task<Void, Never>?
    private var spellTask: Task<Void, Never>?
    private var dismissedQueryLocation: Int?
    private var lastLayoutWidth: CGFloat = 0
    private var observers: [any NSObjectProtocol] = []
    private var lastAnnouncedCompletion: String?

    public init(style: ComposerStyle = ComposerStyle(), configuration: ComposerConfiguration = ComposerConfiguration()) {
        self.style = style
        self.configuration = configuration
        attachments = AttachmentList(limits: configuration.attachmentLimits)
        completion = CompletionSession(providers: configuration.completionProviders, debounce: configuration.completionDebounce)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    isolated deinit {
        heightTask?.cancel()
        spellTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        completionPanel?.orderOut(nil)
    }

    // MARK: - View

    public override func loadView() {
        card = ComposerCardView(style: style)
        errorView = ComposerErrorView(style: style)
        textView = makeTextView()

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .automatic
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: minimumTextHeight)
        heightConstraint.isActive = true

        strip.style = style
        strip.onRemove = { [weak self] id in self?.removeAttachment(id: id) }
        strip.isHidden = true
        errorView.isHidden = true
        errorView.onDismiss = { [weak self] in self?.controller.dismissError() }

        buildControlsBar()

        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 6
        cardStack.edgeInsets = style.contentInsets
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)
        card.translatesAutoresizingMaskIntoConstraints = false
        for item in [strip, scrollView, errorView!, controlsBar] as [NSView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            cardStack.addArrangedSubview(item)
            let horizontalInset = style.contentInsets.left + style.contentInsets.right
            item.widthAnchor.constraint(equalTo: cardStack.widthAnchor, constant: -horizontalInset).isActive = true
        }
        cardStack.setCustomSpacing(2, after: scrollView)

        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 5
        rootStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            cardStack.topAnchor.constraint(equalTo: card.topAnchor),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        view = rootStack
        installContextLine()

        controller.sendKey = configuration.sendKey
        controller.draftSaveDelay = configuration.draftSaveDelay
        controller.currentDraft = { [weak self] in self?.currentDraft() ?? .empty }
        controller.applyDraft = { [weak self] draft in self?.apply(draft) }
        controller.replaceTextUndoably = { [weak self] draft in self?.replaceText(with: draft) }
        controller.onStateChange = { [weak self] in self?.refreshControls() }
        controller.announce = { [weak self] message in self?.announce(message) }
        completion.onChange = { [weak self] in self?.renderCompletion() }
        refreshControls()
        observeEnvironment()
    }

    private func makeTextView() -> ComposerTextView {
        let layoutManager = NSTextLayoutManager()
        layoutManager.delegate = self
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        // Text starts where the chips and controls start.
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 20), textContainer: container)
        textView.owner = self
        textView.delegate = self
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isContinuousSpellCheckingEnabled = configuration.spellChecking != .off
        textView.setAccessibilityLabel("Message")
        textView.setAccessibilityHelp("Return sends. Shift-Return adds a line. Type @ to mention a file or / for a command.")
        applyTextStyle(to: textView)
        return textView
    }

    private func applyTextStyle(to textView: ComposerTextView) {
        textView.font = style.font
        textView.textColor = style.textColor
        textView.insertionPointColor = style.textColor
        textView.typingAttributes = baseAttributes
        textView.placeholder = style.placeholder
        textView.placeholderColor = style.placeholderColor
    }

    private func buildControlsBar() {
        for stack in [leadingControls, trailingControls] {
            stack.orientation = .horizontal
            stack.spacing = 4
            stack.alignment = .centerY
            stack.setHuggingPriority(.defaultHigh, for: .horizontal)
        }
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = style.secondaryTextColor
        statusLabel.isHidden = true

        stopButton.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
        stopButton.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        stopButton.isBordered = false
        stopButton.contentTintColor = .secondaryLabelColor
        stopButton.setAccessibilityLabel("Stop the agent")
        stopButton.toolTip = "Stop the agent"
        stopButton.target = self
        stopButton.action = #selector(stopAgent(_:))
        stopButton.isHidden = true

        followUpMenuButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        followUpMenuButton.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        followUpMenuButton.isBordered = false
        followUpMenuButton.contentTintColor = .secondaryLabelColor
        followUpMenuButton.setAccessibilityLabel("Follow-up options")
        followUpMenuButton.toolTip = "Queue, steer or stop"
        followUpMenuButton.target = self
        followUpMenuButton.action = #selector(showFollowUpMenu(_:))
        followUpMenuButton.isHidden = true

        sendButton.style = style
        sendButton.target = self
        sendButton.action = #selector(primaryButtonPressed(_:))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        controlsBar.orientation = .horizontal
        controlsBar.alignment = .centerY
        controlsBar.spacing = 6
        for item in [leadingControls, spacer, trailingControls, statusLabel, stopButton, followUpMenuButton, sendButton] as [NSView] {
            controlsBar.addArrangedSubview(item)
        }
        controlsBar.setCustomSpacing(2, after: followUpMenuButton)
        controlsBar.heightAnchor.constraint(equalToConstant: style.controlHeight).isActive = true
    }

    private func installContextLine() {
        guard isViewLoaded, let line = contextLineView else { return }
        line.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(line)
        line.leadingAnchor.constraint(equalTo: rootStack.leadingAnchor, constant: style.contentInsets.left).isActive = true
        line.trailingAnchor.constraint(lessThanOrEqualTo: rootStack.trailingAnchor).isActive = true
    }

    private func observeEnvironment() {
        let center = NotificationCenter.default
        let refreshFocus: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFocus() }
        }
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main, using: refreshFocus))
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main, using: refreshFocus))
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyStyle() }
            })
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.bounds.width
        if abs(width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = width
            scheduleHeightUpdate()
        }
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        controller.flushDraft()
        completion.close()
    }

    private func applyStyle() {
        guard isViewLoaded else { return }
        card.style = style
        strip.style = style
        sendButton.style = style
        applyTextStyle(to: textView)
        let storage = textView.textStorage
        let whole = NSRange(location: 0, length: storage?.length ?? 0)
        storage?.addAttributes(baseAttributes, range: whole)
        for placed in TokenText.placedTokens(in: storage ?? NSAttributedString()) {
            storage?.addAttributes(tokenDecoration(placed.token), range: placed.range)
        }
        scheduleHeightUpdate()
        view.needsDisplay = true
        card.needsDisplay = true
        strip.chipViews.forEach { $0.needsDisplay = true }
    }

    private func applyConfiguration() {
        controller.sendKey = configuration.sendKey
        controller.draftSaveDelay = configuration.draftSaveDelay
        completion.providers = configuration.completionProviders
        completion.debounce = configuration.completionDebounce
        var list = attachments
        list.limits = configuration.attachmentLimits
        attachments = list
        updateSpellChecking()
        refreshControls()
    }

    // MARK: - Attributes

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: style.font, .foregroundColor: style.textColor]
    }

    private func tokenDecoration(_ token: ComposerToken) -> [NSAttributedString.Key: Any] {
        [.foregroundColor: style.tokenTextColor, .composerTokenBackground: style.tokenBackgroundColor]
    }

    private var storage: NSTextStorage { textView.textStorage ?? NSTextStorage() }

    // MARK: - Draft

    /// The composer's whole state as a value.
    public func currentDraft() -> ComposerDraft {
        guard isViewLoaded else { return .empty }
        return TokenText.draft(from: storage, attachments: attachments.items, selection: textView.selectedRange())
    }

    /// Replaces everything without an undo entry (thread switch, send, restore). Clears the undo stack: undo must not
    /// reach into another thread's text.
    private func apply(_ draft: ComposerDraft) {
        isApplying = true
        defer { isApplying = false }
        if textView.hasMarkedText() {
            textView.inputContext?.discardMarkedText()
            textView.unmarkText()
        }
        let valid = draft.validated()
        storage.setAttributedString(
            TokenText.attributedText(for: valid, base: baseAttributes, decoration: tokenDecoration)
        )
        textView.typingAttributes = baseAttributes
        textView.setSelectedRange(valid.selection)
        attachments = AttachmentList(valid.attachments, limits: configuration.attachmentLimits)
        showAttachments()
        undo.removeAllActions()
        completion.close()
        dismissedQueryLocation = nil
        scheduleHeightUpdate()
        updateSpellChecking()
        refreshControls()
        textView.needsDisplay = true
    }

    /// Replaces the text (keeping attachments) as one undoable edit: history recall.
    private func replaceText(with draft: ComposerDraft) {
        let attributed = TokenText.attributedText(for: draft, base: baseAttributes, decoration: tokenDecoration)
        perform(edit: NSRange(location: 0, length: storage.length), with: attributed, actionName: "Recall Prompt")
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// One undoable replacement that bypasses token expansion (the caller already chose the range).
    private func perform(edit range: NSRange, with replacement: NSAttributedString, actionName: String? = nil) {
        isPerformingEdit = true
        defer { isPerformingEdit = false }
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: range, replacementString: replacement.string) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        textView.typingAttributes = baseAttributes
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location + replacement.length, length: 0))
        if let actionName { undo.setActionName(actionName) }
        textView.breakUndoCoalescing()
    }

    // MARK: - Public commands

    /// Puts keyboard focus in the text.
    public func focus() {
        view.window?.makeFirstResponder(textView)
    }

    /// Inserts text at the selection (paste-to-focus, review comments).
    public func insert(text: String) {
        perform(edit: textView.selectedRange(), with: NSAttributedString(string: text, attributes: baseAttributes))
    }

    /// Inserts a token at the selection as one undoable edit, followed by a space.
    public func insert(token: ComposerToken) {
        insertToken(token, replacing: textView.selectedRange())
    }

    /// Adds attachments (undoable). Returns what was refused, which is also shown inline.
    @discardableResult
    public func add(attachments candidates: [ComposerAttachment], actionName: String = "Add Attachment") -> [AttachmentList.Rejection] {
        var list = attachments
        let rejected = list.add(candidates)
        if list != attachments { setAttachments(list, actionName: actionName) }
        if let first = rejected.first { showLocalError(first.message) }
        return rejected
    }

    public func removeAttachment(id: String) {
        var list = attachments
        guard let removed = list.remove(id: id) else { return }
        setAttachments(list, actionName: "Remove Attachment")
        announce("Removed \(removed.name)")
    }

    private func setAttachments(_ list: AttachmentList, actionName: String) {
        let old = attachments
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setAttachments(old, actionName: actionName) }
        }
        undo.setActionName(actionName)
        attachments = list
        showAttachments()
        let added = list.items.filter { item in !old.items.contains { $0.id == item.id } }
        if !added.isEmpty { announce(added.map(\.accessibilityDescription).joined(separator: ". ") + " added") }
        controller.draftDidChange()
        refreshControls()
    }

    private func showAttachments() {
        strip.show(attachments.items)
        strip.isHidden = attachments.isEmpty
    }

    private func showLocalError(_ message: String) {
        errorView.show(message)
        errorView.isHidden = false
        announce(message)
    }

    // MARK: - Menu actions (first responder)

    @objc public func sendPrompt(_ sender: Any?) { send(alternate: false) }
    @objc public func queuePrompt(_ sender: Any?) { send(delivery: .queue) }
    @objc public func steerPrompt(_ sender: Any?) { send(delivery: .steer) }
    @objc public func stopAgent(_ sender: Any?) { controller.stop() }
    @objc public func focusComposer(_ sender: Any?) { focus() }

    /// Sends with the default action, or the alternate one (the opposite follow-up while running).
    public func send(alternate: Bool) {
        guard !textView.hasMarkedText() else { return }
        guard checkLength() else { return }
        completion.close()
        controller.submit(alternate: alternate)
    }

    private func send(delivery: ComposerDelivery) {
        let alternate = controller.delivery(alternate: true) == delivery && controller.delivery(alternate: false) != delivery
        send(alternate: alternate)
    }

    private func checkLength() -> Bool {
        let length = storage.length
        guard length > configuration.maximumPromptLength else { return true }
        showLocalError(
            "This prompt has \(length.formatted()) characters; the limit is \(configuration.maximumPromptLength.formatted()). "
                + "Attach long text as a file instead.")
        return false
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let empty = currentDraftIsEmpty
        switch menuItem.action {
        case #selector(sendPrompt(_:)): return !empty && controller.host != nil
        case #selector(queuePrompt(_:)): return !empty && controller.runState != .idle
        case #selector(steerPrompt(_:)):
            return !empty && controller.runState != .idle && controller.host?.supportsSteer == true
        case #selector(stopAgent(_:)): return controller.runState == .running
        default: return true
        }
    }

    @objc private func primaryButtonPressed(_ sender: Any?) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let alternate = alternateHeld || flags.contains(.command)
        switch controller.primaryAction(alternate: alternate, draftIsEmpty: currentDraftIsEmpty) {
        case .send: send(alternate: alternate)
        case .stop: controller.stop()
        case .stopping: break
        }
        focus()
    }

    @objc private func showFollowUpMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let key = configuration.sendKey
        let primary = controller.delivery(alternate: false)
        let other = controller.delivery(alternate: true)
        let empty = currentDraftIsEmpty
        for (delivery, alternate) in [(primary, false), (other, true)] where delivery != .now {
            let title = delivery == .queue ? "Queue After This Turn" : "Steer at Next Step"
            let item = NSMenuItem(title: title, action: #selector(followUpChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = alternate
            item.isEnabled = !empty
            item.toolTip = delivery.explanation
            item.attributedTitle = nil
            item.title = "\(title)    \(SendKeyPolicy.shortcutLabel(sendKey: key, alternate: alternate))"
            menu.addItem(item)
            if alternate && primary == other { break }
        }
        if controller.host?.supportsSteer == false {
            let note = NSMenuItem(title: "Steering is not available for this agent", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())
        let stop = NSMenuItem(title: "Stop Agent", action: #selector(stopAgent(_:)), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func followUpChosen(_ sender: NSMenuItem) {
        send(alternate: (sender.representedObject as? Bool) ?? false)
    }

    // MARK: - Controls state

    private var currentDraftIsEmpty: Bool {
        guard isViewLoaded else { return true }
        return attachments.isEmpty && storage.string.allSatisfy(\.isWhitespace)
    }

    /// The primary button's current state, for tests and scripted scenarios.
    public var primaryAction: ComposerController.PrimaryAction {
        controller.primaryAction(alternate: alternateHeld, draftIsEmpty: currentDraftIsEmpty)
    }

    /// The inline error, if one is showing.
    public var visibleError: String? { errorView.isHidden ? nil : errorView.label.stringValue }

    private func refreshControls() {
        guard isViewLoaded else { return }
        let empty = currentDraftIsEmpty
        let running = controller.runState != .idle
        let key = configuration.sendKey
        let action = controller.primaryAction(alternate: alternateHeld, draftIsEmpty: empty)
        switch action {
        case .send(.now):
            sendButton.appearanceState = .send(enabled: !empty && controller.host != nil)
            sendButton.isEnabled = !empty && controller.host != nil
            sendButton.setAccessibilityLabel("Send")
            sendButton.toolTip = "Send (\(SendKeyPolicy.shortcutLabel(sendKey: key, alternate: false)))"
        case .send(let delivery):
            sendButton.appearanceState = .followUp(delivery)
            sendButton.isEnabled = true
            sendButton.setAccessibilityLabel(delivery.title)
            let alternate = delivery != controller.delivery(alternate: false)
            let otherDelivery = controller.delivery(alternate: !alternate)
            var tip = "\(delivery.explanation) (\(SendKeyPolicy.shortcutLabel(sendKey: key, alternate: alternate)))"
            if otherDelivery != delivery {
                tip += "\n\(otherDelivery.explanation) (\(SendKeyPolicy.shortcutLabel(sendKey: key, alternate: !alternate)))"
            }
            sendButton.toolTip = tip
        case .stop:
            sendButton.appearanceState = .stop
            sendButton.isEnabled = true
            sendButton.setAccessibilityLabel("Stop the agent")
            sendButton.toolTip = "Stop the agent"
        case .stopping:
            sendButton.appearanceState = .stopping
            sendButton.isEnabled = false
            sendButton.setAccessibilityLabel("Stopping")
            sendButton.toolTip = "Waiting for the agent to stop"
        }
        stopButton.isHidden = !(running && !empty && controller.runState == .running)
        followUpMenuButton.isHidden = !running
        statusLabel.stringValue = controller.pendingSends > 0 ? "Sending…" : ""
        statusLabel.isHidden = controller.pendingSends == 0
        if let message = controller.errorMessage {
            errorView.show(message)
            errorView.isHidden = false
        } else if !errorView.isHidden, errorView.label.stringValue != "" {
            errorView.isHidden = true
        }
    }

    private func refreshFocus() {
        guard isViewLoaded, let window = view.window else { return }
        card.isFocused = window.isKeyWindow && window.firstResponder === textView
    }

    // MARK: - Height

    private var lineHeight: CGFloat { ceil(style.font.ascender - style.font.descender + style.font.leading) }

    private var minimumTextHeight: CGFloat {
        CGFloat(max(1, style.minimumLines)) * lineHeight + textView.textContainerInset.height * 2
    }

    private func scheduleHeightUpdate() {
        guard heightTask == nil else { return }
        heightTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.heightTask = nil
            self.updateTextHeight()
        }
    }

    /// Measures the laid-out text and sets the scroll view height: from the minimum up to the cap, then scrolls.
    /// Never touches text or selection.
    public func updateTextHeight() {
        guard let layoutManager = textView.textLayoutManager else { return }
        let signpost = ComposerSignposts.layout.beginInterval("height")
        defer { ComposerSignposts.layout.endInterval("height", signpost) }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let used = layoutManager.usageBoundsForTextContainer.height
        let inset = textView.textContainerInset.height * 2
        let minimum = minimumTextHeight
        let available = view.window?.contentView?.bounds.height ?? 600
        let maximum = max(minimum, floor(available * style.maximumHeightFraction))
        let target = min(max(ceil(used) + inset, minimum), maximum)
        guard abs(heightConstraint.constant - target) > 0.5 else { return }
        heightConstraint.constant = target
        view.layoutSubtreeIfNeeded()
        textView.scrollRangeToVisible(textView.selectedRange())
        onHeightChange?(view.fittingSize.height)
    }

    /// Current height of the text area (tests and scenarios).
    public var textAreaHeight: CGFloat { heightConstraint.constant }
    public var textAreaMaximumHeight: CGFloat {
        max(minimumTextHeight, floor((view.window?.contentView?.bounds.height ?? 600) * style.maximumHeightFraction))
    }

    // MARK: - Spell checking

    private func updateSpellChecking() {
        spellTask?.cancel()
        spellTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            let enabled: Bool = switch self.configuration.spellChecking {
            case .on: true
            case .off: false
            case .automatic: !CodeLikeText.isCodeLike(String(self.storage.string.prefix(8192)))
            }
            if self.textView.isContinuousSpellCheckingEnabled != enabled {
                self.textView.isContinuousSpellCheckingEnabled = enabled
            }
        }
    }

    /// Whether continuous spell checking is on now (scenarios).
    public var isSpellCheckingEnabled: Bool { textView.isContinuousSpellCheckingEnabled }

    // MARK: - Completion

    private func updateCompletion() {
        guard !completion.providers.isEmpty, !textView.hasMarkedText(), !isApplying else { return }
        let selection = textView.selectedRange()
        guard selection.length == 0 else {
            completion.close()
            return
        }
        let tokens = TokenText.placedTokens(in: storage).map(\.range)
        let query = CompletionTriggerDetector.query(
            in: storage.string as NSString, caret: selection.location, triggers: completion.triggers, excluded: tokens
        )
        if let dismissed = dismissedQueryLocation {
            if query?.range.location == dismissed { return }
            dismissedQueryLocation = nil
        }
        completion.update(query)
    }

    private func acceptCompletion() -> Bool {
        guard let item = completion.selectedItem, let query = completion.query else { return false }
        var token = item.token
        token.id = UUID().uuidString
        completion.close()
        insertToken(token, replacing: query.range)
        return true
    }

    private func insertToken(_ token: ComposerToken, replacing range: NSRange) {
        let string = storage.string as NSString
        let end = NSMaxRange(range)
        let nextIsSpace = end < string.length
            && string.substring(with: string.rangeOfComposedCharacterSequence(at: end)).first?.isWhitespace == true
        let insertion = NSMutableAttributedString(
            attributedString: TokenText.attributedToken(token, base: baseAttributes, decoration: tokenDecoration(token))
        )
        if !nextIsSpace { insertion.append(NSAttributedString(string: " ", attributes: baseAttributes)) }
        perform(edit: range, with: insertion, actionName: "Insert \(token.kind == .command ? "Command" : "Mention")")
        if nextIsSpace { textView.setSelectedRange(NSRange(location: range.location + insertion.length + 1, length: 0)) }
        announce("Inserted \(token.text)")
    }

    private func renderCompletion() {
        guard isViewLoaded else { return }
        guard completion.isOpen, let query = completion.query, let window = view.window else {
            if let panel = completionPanel, panel.isVisible {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            lastAnnouncedCompletion = nil
            return
        }
        let list = completionList ?? CompletionListView(style: style)
        list.onAccept = { [weak self] index in
            guard let self else { return }
            self.completion.select(index: index)
            _ = self.acceptCompletion()
        }
        completionList = list
        let message: String? = switch completion.state {
        case .loading: "Searching…"
        case .showing where completion.items.isEmpty: "No matches"
        case .failed(_, let text): text
        default: nil
        }
        list.show(completion.items, selected: completion.selectedIndex, message: message)
        let panel = completionPanel ?? makeCompletionPanel(list)
        let caret = textView.firstRect(forCharacterRange: NSRange(location: query.range.location, length: 0), actualRange: nil)
        let size = NSSize(width: style.completionWidth, height: list.preferredHeight)
        // Above the card (never over the text being typed), aligned with the trigger character.
        let cardTop = window.convertToScreen(card.convert(card.bounds, to: nil)).maxY
        var origin = NSPoint(x: caret.minX - 10, y: max(caret.maxY, cardTop) + 4)
        if let screen = window.screen?.visibleFrame {
            if origin.y + size.height > screen.maxY { origin.y = caret.minY - 6 - size.height }
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        announceCompletion(query)
    }

    private func makeCompletionPanel(_ list: CompletionListView) -> CompletionPanel {
        let panel = CompletionPanel(
            contentRect: NSRect(x: 0, y: 0, width: style.completionWidth, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.contentView = list
        completionPanel = panel
        return panel
    }

    private func announceCompletion(_ query: CompletionQuery) {
        let text: String
        if let item = completion.selectedItem {
            text = "\(item.title), \(completion.selectedIndex + 1) of \(completion.items.count)"
        } else if case .showing = completion.state {
            text = "No suggestions"
        } else {
            return
        }
        guard text != lastAnnouncedCompletion else { return }
        lastAnnouncedCompletion = text
        announce(text, priority: .low)
    }

    /// The completion popover's content (snapshots).
    public var completionView: NSView? { completionPanel?.isVisible == true ? completionList : nil }

    /// Waits for completion queries and chip thumbnails, so a snapshot shows settled content.
    public func settle() async {
        await completion.settle()
        for chip in strip.chipViews { await chip.settle() }
        heightTask?.cancel()
        heightTask = nil
        updateTextHeight()
    }

    // MARK: - Accessibility

    private func announce(_ message: String, priority: NSAccessibilityPriorityLevel = .high) {
        guard !message.isEmpty else { return }
        NSAccessibility.post(
            element: view.window ?? textView as Any, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: priority.rawValue]
        )
    }

    // MARK: - History boundaries

    private func caretRect(at location: Int) -> NSRect {
        textView.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
    }

    private func caretIsOnFirstLine() -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        if selection.location == 0 { return true }
        return abs(caretRect(at: selection.location).minY - caretRect(at: 0).minY) < 1
    }

    private func caretIsOnLastLine() -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        if selection.location == storage.length { return true }
        return abs(caretRect(at: selection.location).minY - caretRect(at: storage.length).minY) < 1
    }
}

// MARK: - Text view delegate and owner

extension ComposerViewController: NSTextViewDelegate, ComposerTextViewOwner, NSTextLayoutManagerDelegate {
    public func undoManager(for view: NSTextView) -> UndoManager? { undo }

    public func textView(
        _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?
    ) -> Bool {
        guard !isApplying, !isPerformingEdit, !textView.hasMarkedText(), let replacement = replacementString else {
            textEditInProgress = true
            return true
        }
        let expanded = TokenText.expandedEditRange(affectedCharRange, in: storage)
        guard expanded != affectedCharRange else {
            textEditInProgress = true
            return true
        }
        // Edit the whole token instead, as one undoable step.
        perform(edit: expanded, with: NSAttributedString(string: replacement, attributes: baseAttributes), actionName: "Typing")
        return false
    }

    public func textView(
        _ textView: NSTextView, willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange,
        toCharacterRange newSelectedCharRange: NSRange
    ) -> NSRange {
        guard !isApplying, !textView.hasMarkedText() else { return newSelectedCharRange }
        return TokenText.snappedSelection(from: oldSelectedCharRange, to: newSelectedCharRange, in: storage)
    }

    public func textView(
        _ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
        toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]
    ) -> [NSAttributedString.Key: Any] {
        baseAttributes
    }

    public func textDidChange(_ notification: Notification) {
        textEditInProgress = false
        guard !isApplying else { return }
        let signpost = ComposerSignposts.edit.beginInterval("textDidChange")
        defer { ComposerSignposts.edit.endInterval("textDidChange", signpost) }
        if !textView.hasMarkedText() {
            for range in TokenText.brokenTokenRanges(in: storage) {
                storage.removeAttribute(.composerToken, range: range)
                storage.removeAttribute(.composerTokenBackground, range: range)
                storage.addAttributes(baseAttributes, range: range)
            }
        }
        if !errorView.isHidden, controller.errorMessage == nil { errorView.isHidden = true }
        controller.draftDidChange()
        scheduleHeightUpdate()
        updateSpellChecking()
        updateCompletion()
        refreshControls()
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard !isApplying, !isPerformingEdit else { return }
        // Undo grouping: a caret move or selection ends the current typing step.
        if !textEditInProgress { textView.breakUndoCoalescing() }
        updateCompletion()
    }

    public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let composing = textView.hasMarkedText()
        if completion.isOpen, !composing {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                completion.moveSelection(by: -1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                completion.moveSelection(by: 1)
                return true
            case #selector(NSResponder.insertTab(_:)):
                if !acceptCompletion() { completion.close() }
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                if acceptCompletion() { return true }
                completion.close()
            case #selector(NSResponder.cancelOperation(_:)):
                dismissedQueryLocation = completion.query?.range.location
                completion.close()
                return true
            default:
                break
            }
        }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
             #selector(NSResponder.insertLineBreak(_:)):
            let flags = self.textView.currentKeyModifiers ?? NSApp.currentEvent?.modifierFlags ?? []
            return composerTextView(self.textView, handleReturn: KeyModifiers(flags))
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape dismisses transient UI only; it never stops, clears or sends.
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard !composing, caretIsOnFirstLine(),
                  storage.length == 0 || controller.isBrowsingHistory || textView.selectedRange().location == 0
            else { return false }
            return controller.historyPrevious()
        case #selector(NSResponder.moveDown(_:)):
            guard !composing, controller.isBrowsingHistory, caretIsOnLastLine() else { return false }
            return controller.historyNext()
        default:
            return false
        }
    }

    func composerTextView(_ textView: ComposerTextView, handleReturn modifiers: KeyModifiers) -> Bool {
        if completion.isOpen, modifiers.isEmpty, acceptCompletion() { return true }
        switch SendKeyPolicy.action(sendKey: configuration.sendKey, modifiers: modifiers, hasMarkedText: textView.hasMarkedText()) {
        case .inputMethod:
            // An input method that let Return through: confirm the composition, never send.
            textView.unmarkText()
        case .newline:
            // Each line is its own undo step.
            textView.breakUndoCoalescing()
            textView.insertNewline(nil)
        case .send(let alternate):
            send(alternate: alternate)
        }
        return true
    }

    func composerTextView(_ textView: ComposerTextView, read pasteboard: NSPasteboard, inline: Bool) -> Bool {
        let signpost = ComposerSignposts.edit.beginInterval("paste")
        defer { ComposerSignposts.edit.endInterval("paste", signpost) }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty {
            add(attachments: urls.map(ComposerAttachment.file(at:)), actionName: "Paste")
            return true
        }
        let imageType = [NSPasteboard.PasteboardType.png, .tiff].first { pasteboard.data(forType: $0) != nil }
        if let imageType, let data = pasteboard.data(forType: imageType) {
            if imageType == .png {
                add(attachments: [.image(data, type: .png)], actionName: "Paste")
            } else {
                Task { [weak self] in
                    let png = await Self.pngData(fromTIFF: data)
                    self?.add(attachments: [png.map { .image($0, type: .png) } ?? .image(data, type: .tiff)], actionName: "Paste")
                }
            }
            if let text = pasteboard.string(forType: .string), !text.isEmpty { textView.insertPlainText(text) }
            return true
        }
        guard let text = pasteboard.string(forType: .string) else { return false }
        if !inline, text.utf8.count >= configuration.attachmentLimits.largePasteBytes {
            add(attachments: [.text(text)], actionName: "Paste")
            announce("Large paste added as a text attachment. Undo to remove it.")
            return true
        }
        textView.insertPlainText(text)
        return true
    }

    @concurrent
    private static func pngData(fromTIFF data: Data) async -> Data? {
        NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    func composerTextViewFocusChanged(_ textView: ComposerTextView) {
        refreshFocus()
        if view.window?.firstResponder !== textView { completion.close() }
    }

    func composerTextViewModifiersChanged(_ textView: ComposerTextView, flags: NSEvent.ModifierFlags) {
        let alternate: KeyModifiers = configuration.sendKey == .returnKey ? .command : [.command, .option]
        let held = KeyModifiers(flags).isSuperset(of: alternate)
        guard held != alternateHeld else { return }
        alternateHeld = held
        refreshControls()
    }

    public nonisolated func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        TokenLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

/// Signpost intervals for edits, layout and paste (never content).
enum ComposerSignposts {
    static let edit = OSSignposter(subsystem: "app.bellocode", category: "ComposerEdit")
    static let layout = OSSignposter(subsystem: "app.bellocode", category: "ComposerLayout")
}
