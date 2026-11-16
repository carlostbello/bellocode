// G1-A spike: the transcript as ONE TextKit 2 document.
//
// The controller owns the canonical message list (server IDs), per-message UTF-16 lengths in the text storage, and
// the AppKit view stack. Rendering runs off the main actor; the main actor only splices finished attributed
// strings into the storage. Edits above the viewport are wrapped in anchor capture/restore; follow mode keeps the
// bottom pinned only while the user is at the bottom.

import AppKit
import QuartzCore

public struct SpikeAnchorResult: Sendable {
    public var case_: String
    public var driftImmediate: Double
    public var driftSettled: Double
    public var compensated: Bool
    public var editLocation: Int
    public var anchorLocation: Int
}

@MainActor
public final class SpikeTranscriptController: NSObject, NSTextViewDelegate {
    public let container: NSView
    public let scrollView: SpikeScrollView
    public let textView: SpikeTextView
    public let contentStorage: NSTextContentStorage
    public let layoutManager: NSTextLayoutManager
    private let layoutDelegate = SpikeLayoutDelegate()
    private let jumpButton: NSButton
    private let materializer = SpikeMaterializer()

    // Canonical model (display order) and storage geometry.
    public private(set) var messages: [SpikeMessage] = []
    private var lengths: [Int] = []
    private var indexByID: [String: Int] = [:]
    private var cardMessage: [String: String] = [:]
    private var cardContent: [String: SpikePart] = [:]
    private var imageMessage: [String: String] = [:]
    public private(set) var expanded: Set<String> = []
    private var imageTasks: [String: Task<Void, Never>] = [:]
    public private(set) var deliveredImages: Set<String> = []
    private var loadTask: Task<Void, Never>?

    // Follow state.
    public private(set) var isFollowing = true
    public var compensateAnchors = true
    public var autoDeliverImages = true
    private var programmaticScrollDepth = 0

    // Streaming tail.
    public private(set) var streamGeneration = 0
    private var streamMessageID: String?
    private var streamLabelLength = 0
    private let streamMaterializer = SpikeMaterializer()
    /// Delta timestamps (CACurrentMediaTime) applied to storage but not yet confirmed on screen.
    public var pendingVisibleStamps: [Double] = []
    public private(set) var commitDurationsMS: [Double] = []

    // Telemetry.
    public private(set) var textKit1Fallback = false
    public private(set) var historyLoaded = false
    public private(set) var loadMarks: [String: Double] = [:]
    public var onFollowChanged: ((Bool) -> Void)?
    private var observers: [any NSObjectProtocol] = []

    public init(frame: NSRect) {
        container = NSView(frame: frame)
        layoutManager = NSTextLayoutManager()
        contentStorage = NSTextContentStorage()
        contentStorage.textStorage = SpikeChunkedStorage()
        contentStorage.addTextLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: frame.width, height: 0))
        textContainer.widthTracksTextView = true
        layoutManager.textContainer = textContainer
        layoutManager.delegate = layoutDelegate
        scrollView = SpikeScrollView(frame: container.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        textView = SpikeTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize), textContainer: textContainer)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.displaysLinkToolTips = false
        scrollView.documentView = textView
        container.addSubview(scrollView)

        jumpButton = NSButton(title: "Jump to latest ↓", target: nil, action: nil)
        jumpButton.bezelStyle = .push
        jumpButton.controlSize = .regular
        jumpButton.isHidden = true
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(jumpButton)
        NSLayoutConstraint.activate([
            jumpButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            jumpButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
        super.init()
        textView.delegate = self
        jumpButton.target = self
        jumpButton.action = #selector(jumpToLatestAction(_:))
        materializer.imageRequest = { [weak self] id in self?.imageRequested(id) }

        scrollView.onUserScroll = { [weak self] delta in self?.userScrolled(deltaY: delta) }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: textView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.textKit1Fallback = true }
        })
        // Estimated document height changes as TextKit 2 lays out more content; keep the bottom pinned while following.
        textView.postsFrameChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: textView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isFollowing, self.programmaticScrollDepth == 0, !self.isAtBottom else { return }
                self.scrollToBottom()
            }
        })
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.prefetchLayout() }
        })
        observers.append(center.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.userScrolled(deltaY: 0) }
        })
    }

    /// Tears down tasks and observers. The owner (window or session) calls this when the transcript closes.
    public func close() {
        loadTask?.cancel()
        for task in imageTasks.values { task.cancel() }
        imageTasks.removeAll()
        streamGeneration += 1
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        textView.delegate = nil
        container.removeFromSuperview()
    }

    public var storage: NSTextStorage { contentStorage.textStorage! }
    /// One chunk per message, in display order (chunk index == message index).
    public var chunked: SpikeChunkedStorage { contentStorage.textStorage as! SpikeChunkedStorage }
    public var isUsingTextKit2: Bool { !textKit1Fallback && textView.textLayoutManager != nil }

    // MARK: Message geometry

    private func registerMessages(_ new: [SpikeMessage], at index: Int, lengths newLengths: [Int]) {
        messages.insert(contentsOf: new, at: index)
        lengths.insert(contentsOf: newLengths, at: index)
        indexByID.removeAll(keepingCapacity: true)
        for (i, message) in messages.enumerated() { indexByID[message.id] = i }
        for message in new {
            for part in message.parts {
                switch part {
                case let .tool(tool): cardMessage[tool.id] = message.id; cardContent[tool.id] = part
                case let .reasoning(id, _): cardMessage[id] = message.id; cardContent[id] = part
                case let .image(image): imageMessage[image.id] = message.id
                default: break
                }
            }
        }
    }

    public func range(ofMessage index: Int) -> NSRange { chunked.chunkRange(index) }

    public func messageIndex(id: String) -> Int? { indexByID[id] }

    private func adjustLength(ofMessage index: Int, by delta: Int) {
        lengths[index] += delta
    }

    // MARK: Loading

    /// Opens the transcript at the bottom: the newest `tailWindow` messages are rendered and shown first, then
    /// older history is rendered off the main actor and prepended while the bottom stays pinned. Every prepend
    /// costs one TextKit 2 viewport relayout on the main actor (~40 ms measured), so the default is one page.
    public func load(_ all: [SpikeMessage], tailWindow: Int = 150, pageSize: Int = 100_000,
                     firstContent: @escaping @MainActor () -> Void) {
        let t0 = CACurrentMediaTime()
        let tailStart = max(0, all.count - tailWindow)
        let tail = Array(all[tailStart...])
        let request: @MainActor (String) -> Void = { [weak self] id in self?.imageRequested(id) }
        loadTask = Task { [weak self] in
            let tailRich = await Self.renderIR(tail, expanded: [])
            let tailStrings = await Self.materializeOffMain(tailRich, imageRequest: request)
            guard let self, !Task.isCancelled else { return }
            self.loadMarks["tailRenderedMS"] = (CACurrentMediaTime() - t0) * 1_000
            self.contentStorage.performEditingTransaction {
                self.chunked.insertChunks(tailStrings, at: 0)
            }
            self.registerMessages(tail, at: 0, lengths: tailRich.map(\.rich.length))
            self.scrollToBottom()
            self.loadMarks["tailInstalledMS"] = (CACurrentMediaTime() - t0) * 1_000
            firstContent()

            var end = tailStart
            while end > 0, !Task.isCancelled {
                let begin = max(0, end - pageSize)
                let page = Array(all[begin..<end])
                let rich = await Self.renderIR(page, expanded: [])
                let strings = await Self.materializeOffMain(rich, imageRequest: request)
                guard !Task.isCancelled else { return }
                let started = CACurrentMediaTime()
                self.insertAtTop(page, rich: rich.map(\.rich.length), strings: strings)
                self.loadMarks["maxPrependMS"] = max(self.loadMarks["maxPrependMS"] ?? 0, (CACurrentMediaTime() - started) * 1_000)
                end = begin
            }
            self.historyLoaded = true
            self.loadMarks["historyLoadedMS"] = (CACurrentMediaTime() - t0) * 1_000
        }
    }

    public func waitUntilLoaded() async {
        await loadTask?.value
    }

    private func insertAtTop(_ page: [SpikeMessage], rich lengths: [Int], strings: [NSAttributedString]) {
        let inserted = lengths.reduce(0, +)
        performAnchored(edit: NSRange(location: 0, length: 0), delta: inserted) {
            self.contentStorage.performEditingTransaction {
                self.chunked.insertChunks(strings, at: 0)
            }
        }
        registerMessages(page, at: 0, lengths: lengths)
    }

    /// Prepends a page of older messages (behaviour 3c). Returns the anchor drift measured after settling.
    public func prependOlder(_ page: [SpikeMessage]) async -> SpikeAnchorResult {
        let request: @MainActor (String) -> Void = { [weak self] id in self?.imageRequested(id) }
        let rich = await Self.renderIR(page, expanded: [])
        let strings = await Self.materializeOffMain(rich, imageRequest: request)
        let inserted = rich.reduce(0) { $0 + $1.rich.length }
        let before = captureTopAnchor()
        let started = CACurrentMediaTime()
        insertAtTop(page, rich: rich.map(\.rich.length), strings: strings)
        loadMarks["lastPrependMS"] = (CACurrentMediaTime() - started) * 1_000
        let immediate = drift(of: before, shiftedBy: inserted)
        let settled = await settledDrift(of: before, shiftedBy: inserted)
        return SpikeAnchorResult(case_: "prepend100", driftImmediate: immediate, driftSettled: settled,
                                 compensated: compensateAnchors, editLocation: 0, anchorLocation: before?.location ?? -1)
    }

    @concurrent
    public nonisolated static func renderIR(_ messages: [SpikeMessage], expanded: Set<String>) async -> [(id: String, rich: SpikeRich)] {
        let chunk = 250
        return await withTaskGroup(of: (Int, [(id: String, rich: SpikeRich)]).self) { group in
            for start in stride(from: 0, to: messages.count, by: chunk) {
                let slice = Array(messages[start..<min(messages.count, start + chunk)])
                group.addTask { (start, slice.map { ($0.id, SpikeRenderer.render($0, expanded: expanded)) }) }
            }
            var parts: [(Int, [(id: String, rich: SpikeRich)])] = []
            for await part in group { parts.append(part) }
            return parts.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }

    /// One attributed string per message, built off the main actor. (NSAttributedString is not Sendable, so this is
    /// one sequential task handing back a `sending` result rather than a task group.)
    @concurrent
    public nonisolated static func materializeOffMain(_ items: [(id: String, rich: SpikeRich)],
                                                      imageRequest: @escaping @MainActor (String) -> Void) async -> sending [NSAttributedString] {
        let materializer = SpikeMaterializer()
        materializer.imageRequest = imageRequest
        return items.map { materializer.materialize($0.rich, messageID: $0.id) }
    }

    // MARK: Coordinates

    private func textLocation(_ offset: Int) -> (any NSTextLocation)? {
        contentStorage.location(contentStorage.documentRange.location, offsetBy: offset)
    }

    private func offset(of location: any NSTextLocation) -> Int {
        contentStorage.offset(from: contentStorage.documentRange.location, to: location)
    }

    public func textRange(_ range: NSRange) -> NSTextRange? {
        guard let start = textLocation(range.location), let end = textLocation(range.upperBound) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// Y of the layout fragment that contains `offset`, in text view coordinates (lays it out if needed).
    public func fragmentFrame(at offset: Int) -> CGRect? {
        guard let location = textLocation(offset) else { return nil }
        layoutManager.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = layoutManager.textLayoutFragment(for: location) else { return nil }
        let origin = textView.textContainerOrigin
        return fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
    }

    public var visibleRect: CGRect { scrollView.contentView.bounds }

    /// Text-view point at the vertical middle of the line holding `offset`, at that character's x position.
    public func characterPoint(at offset: Int) -> CGPoint? {
        guard let location = textLocation(offset) else { return nil }
        layoutManager.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = layoutManager.textLayoutFragment(for: location) else { return nil }
        let inFragment = contentStorage.offset(from: fragment.rangeInElement.location, to: location)
        let origin = textView.textContainerOrigin
        for line in fragment.textLineFragments where line.characterRange.contains(inFragment) || line === fragment.textLineFragments.last {
            let x = line.locationForCharacter(at: inFragment).x
            let bounds = line.typographicBounds
            return CGPoint(x: fragment.layoutFragmentFrame.minX + origin.x + x + 1,
                           y: fragment.layoutFragmentFrame.minY + origin.y + bounds.midY)
        }
        return nil
    }

    public struct Anchor: Sendable { public var location: Int; public var screenY: CGFloat }

    /// The first layout fragment at the top of the viewport: its document offset and on-screen Y.
    public func captureTopAnchor() -> Anchor? {
        let visible = visibleRect
        let origin = textView.textContainerOrigin
        let point = CGPoint(x: 30, y: max(0, visible.minY - origin.y + 1))
        guard let fragment = layoutManager.textLayoutFragment(for: point) else { return nil }
        let location = offset(of: fragment.rangeInElement.location)
        return Anchor(location: location, screenY: fragment.layoutFragmentFrame.minY + origin.y - visible.minY)
    }

    /// Screen-Y difference for the anchored content after an edit that shifted its offset by `shift`.
    public func drift(of anchor: Anchor?, shiftedBy shift: Int) -> Double {
        guard let anchor, let frame = fragmentFrame(at: anchor.location + shift) else { return .nan }
        return Double(frame.minY - visibleRect.minY - anchor.screenY)
    }

    public func settledDrift(of anchor: Anchor?, shiftedBy shift: Int) async -> Double {
        try? await Task.sleep(for: .milliseconds(350))
        return drift(of: anchor, shiftedBy: shift)
    }

    // MARK: Scrolling

    public var isAtBottom: Bool {
        visibleRect.maxY >= textView.frame.height - 24
    }

    public func scrollProgrammatically(toY y: CGFloat) {
        programmaticScrollDepth += 1
        let maxY = max(0, textView.frame.height - visibleRect.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        programmaticScrollDepth -= 1
    }

    public func scrollToBottom() {
        programmaticScrollDepth += 1
        let end = contentStorage.documentRange.endLocation
        layoutManager.ensureLayout(for: NSTextRange(location: end))
        textView.scrollToEndOfDocument(nil)
        programmaticScrollDepth -= 1
    }

    public func scrollToTop() {
        setFollowing(false)
        scrollProgrammatically(toY: 0)
    }

    /// Scrolls so the start of message `index` is `offset` points below the top of the viewport.
    public func reveal(messageAt index: Int, offset: CGFloat = 40) {
        let range = range(ofMessage: index)
        guard let location = textLocation(range.location) else { return }
        programmaticScrollDepth += 1
        layoutManager.textViewportLayoutController.relocateViewport(to: location)
        if let frame = fragmentFrame(at: range.location) { scrollProgrammatically(toY: frame.minY - offset) }
        layoutManager.textViewportLayoutController.layoutViewport()
        if let frame = fragmentFrame(at: range.location) { scrollProgrammatically(toY: frame.minY - offset) }
        programmaticScrollDepth -= 1
        setFollowing(isAtBottom)
    }

    private func userScrolled(deltaY: CGFloat) {
        guard programmaticScrollDepth == 0 else { return }
        if deltaY > 0 { setFollowing(false) } else if isAtBottom { setFollowing(true) } else if deltaY == 0 { setFollowing(false) }
    }

    private func setFollowing(_ value: Bool) {
        guard value != isFollowing else { return }
        isFollowing = value
        jumpButton.isHidden = value
        onFollowChanged?(value)
    }

    @objc private func jumpToLatestAction(_ sender: Any?) { jumpToLatest() }

    public func jumpToLatest() {
        setFollowing(true)
        scrollToBottom()
    }

    public var jumpButtonVisible: Bool { !jumpButton.isHidden }
    public var jumpButtonFrame: NSRect { jumpButton.frame }

    // MARK: Layout prefetch

    /// Lays out `prefetchScreens` screens above and below the viewport whenever it moves, so estimated positions
    /// are replaced by measured ones off-screen instead of under the user's eyes.
    public var prefetchScreens: CGFloat = 0
    private var lastPrefetchY: CGFloat = -.greatestFiniteMagnitude

    private func prefetchLayout() {
        guard prefetchScreens > 0, programmaticScrollDepth == 0 else { return }
        let visible = visibleRect
        guard abs(visible.minY - lastPrefetchY) > visible.height / 4 else { return }
        lastPrefetchY = visible.minY
        let origin = textView.textContainerOrigin
        let span = visible.height * prefetchScreens
        let rect = CGRect(x: 0, y: visible.minY - origin.y - span, width: visible.width, height: visible.height + 2 * span)
        layoutManager.ensureLayout(for: rect)
    }

    // MARK: Viewport stabiliser (removed)
    //
    // An experiment captured the top fragment before NSTextView.layout() and restored its screen position after.
    // It did not catch the large geometry jumps and added 1,171 small ones while scrolling up, so it was removed.
    public let stabiliseViewport = false
    public let stabiliserCorrections = 0
    public let stabiliserMaxCorrectionPT: CGFloat = 0

    // MARK: Anchored edits

    /// Runs `edit`, then keeps the viewport stable: pinned to the bottom when following, otherwise the top visible
    /// fragment (or `pin`) returns to the same screen Y.
    @discardableResult
    public func performAnchored(edit: NSRange, delta: Int, pin: Int? = nil, _ body: () -> Void) -> Anchor? {
        if isFollowing {
            body()
            scrollToBottom()
            return nil
        }
        let anchor: Anchor? = pin.flatMap { anchor(at: $0) } ?? captureTopAnchor()
        body()
        guard compensateAnchors, var anchor else { return anchor }
        if edit.location < anchor.location || (edit.location == anchor.location && edit.length == 0 && pin == nil) {
            anchor.location = max(edit.location, anchor.location + delta)
        }
        restore(anchor)
        return anchor
    }

    private func anchor(at offset: Int) -> Anchor? {
        guard let frame = fragmentFrame(at: offset) else { return nil }
        return Anchor(location: offset, screenY: frame.minY - visibleRect.minY)
    }

    private func restore(_ anchor: Anchor) {
        programmaticScrollDepth += 1
        for _ in 0..<3 {
            guard let frame = fragmentFrame(at: anchor.location) else { break }
            let target = frame.minY - anchor.screenY
            if abs(visibleRect.minY - target) < 0.5 { break }
            scrollProgrammatically(toY: target)
            layoutManager.textViewportLayoutController.layoutViewport()
        }
        programmaticScrollDepth -= 1
    }

    // MARK: Cards

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, url.scheme == SpikeToggleURL.scheme, let id = url.host else { return false }
        toggleCard(id, pinned: true)
        return true
    }

    public func cardIDs() -> [String] { Array(cardMessage.keys) }
    public func isTool(_ id: String) -> Bool { if case .tool = cardContent[id] { return true } else { return false } }

    public func headerRange(ofCard id: String) -> NSRange? {
        guard let messageID = cardMessage[id], let index = indexByID[messageID] else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.spikeCard, in: range(ofMessage: index)) { value, range, stop in
            if value as? String == id { found = range; stop.pointee = true }
        }
        return found
    }

    /// Expands or collapses a card by replacing its range. `pinned` keeps the card header still (click case);
    /// otherwise the top visible fragment is the anchor (content changing above the viewport).
    @discardableResult
    public func toggleCard(_ id: String, pinned: Bool) -> Anchor? {
        guard let messageID = cardMessage[id], let index = indexByID[messageID], let part = cardContent[id],
              let header = headerRange(ofCard: id) else { return nil }
        var replace = header
        storage.enumerateAttribute(.spikeCardBody, in: range(ofMessage: index)) { value, range, stop in
            if value as? String == id { replace = NSUnionRange(replace, range); stop.pointee = true }
        }
        let expand = !expanded.contains(id)
        if expand { expanded.insert(id) } else { expanded.remove(id) }
        let rich: SpikeRich
        switch part {
        case let .tool(tool): rich = SpikeRenderer.renderTool(tool, expanded: expand)
        case let .reasoning(rid, text): rich = SpikeRenderer.renderReasoning(id: rid, text: text, expanded: expand)
        default: return nil
        }
        let replacement = materializer.materialize(rich, messageID: messageID)
        let delta = replacement.length - replace.length
        let anchor = performAnchored(edit: replace, delta: delta, pin: pinned ? header.location : nil) {
            contentStorage.performEditingTransaction {
                storage.replaceCharacters(in: replace, with: replacement)
            }
        }
        adjustLength(ofMessage: index, by: delta)
        return anchor
    }

    // MARK: Images

    private func imageRequested(_ id: String) {
        guard autoDeliverImages, imageTasks[id] == nil, !deliveredImages.contains(id),
              let attachment = attachment(forImage: id) else { return }
        let delay = attachment.spec.delayMS
        imageTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            self?.deliverImage(id)
        }
    }

    public func attachment(forImage id: String) -> SpikeImageAttachment? {
        guard let location = imageLocation(id) else { return nil }
        return storage.attribute(.attachment, at: location, effectiveRange: nil) as? SpikeImageAttachment
    }

    public func imageLocation(_ id: String) -> Int? {
        guard let messageID = imageMessage[id], let index = indexByID[messageID] else { return nil }
        var found: Int?
        storage.enumerateAttribute(.spikeImage, in: range(ofMessage: index)) { value, range, stop in
            if value as? String == id { found = range.location; stop.pointee = true }
        }
        return found
    }

    public func imageIDs() -> [String] { Array(imageMessage.keys) }

    /// Delivers an image: its attachment grows from placeholder to full size and the paragraph is re-laid out.
    @discardableResult
    public func deliverImage(_ id: String) -> Anchor? {
        imageTasks[id] = nil
        guard !deliveredImages.contains(id), let location = imageLocation(id),
              let attachment = storage.attribute(.attachment, at: location, effectiveRange: nil) as? SpikeImageAttachment
        else { return nil }
        deliveredImages.insert(id)
        return performAnchored(edit: NSRange(location: location, length: 1), delta: 0) {
            attachment.deliver()
            // Re-set the attribute so TextKit 2 re-queries the attachment bounds for this paragraph.
            contentStorage.performEditingTransaction {
                storage.addAttribute(.attachment, value: attachment, range: NSRange(location: location, length: 1))
            }
        }
    }

    // MARK: Streaming tail

    /// Appends an empty assistant message that will receive streamed text; returns the stream generation.
    public func beginStreamingMessage(id: String) -> Int {
        streamGeneration += 1
        var rich = SpikeRich()
        rich.append("Assistant", .roleLabel)
        rich.endParagraph(SpikeParaStyle(block: .roleLabel))
        let label = streamMaterializer.materialize(rich, messageID: id)
        streamLabelLength = label.length
        streamMessageID = id
        let location = storage.length
        performAnchored(edit: NSRange(location: location, length: 0), delta: label.length) {
            contentStorage.performEditingTransaction { chunked.insertChunks([label], at: chunked.chunkCount) }
        }
        registerMessages([SpikeMessage(id: id, role: .assistant, parts: [])], at: messages.count, lengths: [label.length])
        return streamGeneration
    }

    /// Applies one coalesced tail update: replaces only the open (uncommitted) tail range of the message.
    public func applyTail(_ update: SpikeTailUpdate) {
        guard update.generation == streamGeneration, let id = streamMessageID, let index = indexByID[id] else { return }
        let started = CACurrentMediaTime()
        let messageRange = range(ofMessage: index)
        let from = messageRange.location + streamLabelLength + update.replaceFrom
        let replace = NSRange(location: from, length: messageRange.upperBound - from)
        let replacement = streamMaterializer.materialize(update.rich, messageID: id)
        let delta = replacement.length - replace.length
        performAnchored(edit: replace, delta: delta) {
            contentStorage.performEditingTransaction {
                storage.replaceCharacters(in: replace, with: replacement)
            }
        }
        adjustLength(ofMessage: index, by: delta)
        pendingVisibleStamps += update.deltaStamps
        commitDurationsMS.append((CACurrentMediaTime() - started) * 1_000)
    }

    // MARK: Find

    public struct FindResult: Sendable {
        public var messageIndex: Int
        public var cardID: String?
        public var range: NSRange
        public var visible: Bool
    }

    /// Finds `needle` in the canonical model (including collapsed card content), expands the card if needed,
    /// then selects and reveals the match.
    public func findAndReveal(_ needle: String) async -> FindResult? {
        let snapshot = messages
        let hit = await Self.searchModel(snapshot, needle: needle)
        guard let hit else { return nil }
        let messageID = snapshot[hit.index].id
        guard let index = indexByID[messageID] else { return nil }
        if let card = hit.cardID, !expanded.contains(card) {
            setFollowing(false)
            toggleCard(card, pinned: false)
        }
        let messageRange = range(ofMessage: index)
        let found = (storage.string as NSString).range(of: needle, options: [], range: messageRange)
        guard found.location != NSNotFound else { return nil }
        setFollowing(false)
        programmaticScrollDepth += 1
        if let location = textLocation(found.location) {
            layoutManager.textViewportLayoutController.relocateViewport(to: location)
        }
        if let frame = fragmentFrame(at: found.location) {
            scrollProgrammatically(toY: frame.minY - visibleRect.height / 3)
            layoutManager.textViewportLayoutController.layoutViewport()
        }
        textView.scrollRangeToVisible(found)
        programmaticScrollDepth -= 1
        textView.setSelectedRange(found)
        textView.showFindIndicator(for: found)
        let frame = fragmentFrame(at: found.location)
        let visible = frame.map { visibleRect.intersects($0) } ?? false
        return FindResult(messageIndex: index, cardID: hit.cardID, range: found, visible: visible)
    }

    @concurrent
    nonisolated static func searchModel(_ messages: [SpikeMessage], needle: String) async -> (index: Int, cardID: String?)? {
        for (index, message) in messages.enumerated() {
            for part in message.parts {
                switch part {
                case let .markdown(text): if text.contains(needle) { return (index, nil) }
                case let .tool(tool):
                    if tool.title.contains(needle) { return (index, nil) }
                    if tool.output.contains(where: { $0.contains(needle) }) { return (index, tool.id) }
                case let .reasoning(id, text): if text.contains(needle) { return (index, id) }
                case let .diff(diff): if diff.lines.contains(where: { $0.contains(needle) }) { return (index, nil) }
                case .image: break
                }
            }
        }
        return nil
    }
}

/// One coalesced streaming commit: replace the message body from `replaceFrom` (UTF-16, after the role label).
public struct SpikeTailUpdate: Sendable {
    public var generation: Int
    public var replaceFrom: Int
    public var rich: SpikeRich
    public var deltaStamps: [Double]
}
