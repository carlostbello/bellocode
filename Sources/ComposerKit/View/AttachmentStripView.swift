import AppKit
import DesignSystem
import ImageIO
import Quartz
import UniformTypeIdentifiers

/// Thumbnails for attachment chips, made off the main actor and cached (bounded).
actor ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private var cache: [String: CGImage] = [:]
    private var order: [String] = []
    private let capacity = 64

    func thumbnail(for attachment: ComposerAttachment, maxPixelSize: Int) -> CGImage? {
        if let cached = cache[attachment.id] { return cached }
        guard attachment.kind == .image else { return nil }
        let source: CGImageSource? = switch attachment.content {
        case .file(let url): CGImageSourceCreateWithURL(url as CFURL, nil)
        case .data(let data): CGImageSourceCreateWithData(data as CFData, nil)
        case .text: nil
        }
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        cache[attachment.id] = image
        order.append(attachment.id)
        if order.count > capacity { cache[order.removeFirst()] = nil }
        return image
    }

    /// A file Quick Look can open: the original file, or the in-memory bytes written to a preview file (owned by
    /// `PreviewFiles`; delete it with `discardPreview(for:)` when the preview ends or the attachment goes).
    func previewURL(for attachment: ComposerAttachment) -> URL? {
        switch attachment.content {
        case .file(let url):
            return url
        case .data(let data):
            return previews.write(data, name: attachment.name, id: attachment.id)
        case .text(let text):
            return previews.write(Data(text.utf8), name: attachment.name, id: attachment.id)
        }
    }

    private let previews = PreviewFiles.current

    func discardPreview(for id: String) { previews.remove(id: id) }
}

/// Quick Look needs a file, so pasted images and text are written to `<tmp>/BelloCodeComposer/<pid>/<attachment>/`
/// while previewed. The owning chip deletes its file when the preview ends, when it is removed and when it goes away;
/// `removeAll()` runs at quit and `cleanUpAbandoned()` at launch removes folders of processes that no longer run
/// (a crash), so unsent private content does not linger.
public struct PreviewFiles: Sendable {
    public let root: URL
    public let processID: Int32

    public static let current = PreviewFiles(
        root: FileManager.default.temporaryDirectory.appending(path: "BelloCodeComposer", directoryHint: .isDirectory),
        processID: ProcessInfo.processInfo.processIdentifier)

    public init(root: URL, processID: Int32) {
        self.root = root
        self.processID = processID
    }

    var directory: URL { root.appending(path: String(processID), directoryHint: .isDirectory) }

    func write(_ data: Data, name: String, id: String) -> URL? {
        let folder = directory.appending(path: AttachmentFileStore.safeComponent(id), directoryHint: .isDirectory)
        let url = folder.appending(path: AttachmentFileStore.safeComponent(name))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    func remove(id: String) {
        try? FileManager.default.removeItem(at: directory.appending(path: AttachmentFileStore.safeComponent(id), directoryHint: .isDirectory))
    }

    /// Deletes this process's preview files (quit).
    @concurrent
    public func removeAll() async {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Deletes preview folders left by processes that are no longer running (and files from before per-process
    /// folders). Returns how many entries were removed.
    @discardableResult
    @concurrent
    public func cleanUpAbandoned() async -> Int {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: root.path) else { return 0 }
        var removed = 0
        for name in entries {
            if let pid = Int32(name), pid == processID || (kill(pid, 0) == 0 || errno == EPERM) { continue }
            if (try? manager.removeItem(at: root.appending(path: name))) != nil { removed += 1 }
        }
        return removed
    }
}

/// A horizontal strip of attachment chips above the text. Hidden when empty.
@MainActor
final class AttachmentStripView: NSView {
    var style = ComposerStyle() {
        didSet { chips.forEach { $0.style = style } }
    }
    var onRemove: ((String) -> Void)?
    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private var chips: [AttachmentChipView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            document.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Attachments")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: style.chipHeight) }

    /// Reconciles chips by attachment ID: existing chips are kept (no thumbnail reload), new ones added, gone ones removed.
    func show(_ attachments: [ComposerAttachment]) {
        let existing = Dictionary(uniqueKeysWithValues: chips.map { ($0.attachment.id, $0) })
        var next: [AttachmentChipView] = []
        for attachment in attachments {
            let chip = existing[attachment.id] ?? AttachmentChipView(attachment: attachment, style: style)
            chip.onRemove = { [weak self] id in self?.onRemove?(id) }
            next.append(chip)
        }
        guard next.map(\.attachment.id) != chips.map(\.attachment.id) else { return }
        for chip in chips where !next.contains(where: { $0 === chip }) {
            chip.discardPreview()
            stack.removeArrangedSubview(chip)
            chip.removeFromSuperview()
        }
        for (index, chip) in next.enumerated() {
            if chip.superview == nil { stack.insertArrangedSubview(chip, at: index) }
        }
        chips = next
        setAccessibilityLabel(attachments.count == 1 ? "1 attachment" : "\(attachments.count) attachments")
    }

    var chipViews: [AttachmentChipView] { chips }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One attachment: thumbnail or icon, name, size, and a remove button. Focusable with Full Keyboard Access:
/// Space opens Quick Look, Delete removes.
@MainActor
final class AttachmentChipView: NSView, @preconcurrency QLPreviewPanelDataSource {
    let attachment: ComposerAttachment
    var style: ComposerStyle { didSet { needsDisplay = true } }
    var onRemove: ((String) -> Void)?
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let removeButton = DSButton(icon: "xmark", accessibilityTitle: "Remove", size: .small)
    private var previewURL: URL?
    /// `previewURL` is a file this chip wrote (pasted content), deleted when the preview ends or the chip goes.
    private var ownsPreviewFile = false
    private var thumbnailTask: Task<Void, Never>?

    init(attachment: ComposerAttachment, style: ComposerStyle) {
        self.attachment = attachment
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.image = Self.icon(for: attachment)
        icon.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.stringValue = attachment.name
        nameLabel.font = DS.TextRole.labelEmph.font
        nameLabel.textColor = style.textColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sizeLabel.stringValue = attachment.formattedSize
        sizeLabel.font = DS.TextRole.meta.font
        sizeLabel.textColor = style.secondaryTextColor
        removeButton.setAccessibilityLabel("Remove \(attachment.name)")
        removeButton.toolTip = "Remove"
        removeButton.target = self
        removeButton.action = #selector(remove)
        for view in [icon, nameLabel, sizeLabel, removeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityElement(view === removeButton)
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: style.chipHeight),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: style.chipHeight - 8),
            icon.heightAnchor.constraint(equalToConstant: style.chipHeight - 8),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 170),
            sizeLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 5),
            sizeLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            removeButton.leadingAnchor.constraint(equalTo: sizeLabel.trailingAnchor, constant: 3),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 16),
            removeButton.heightAnchor.constraint(equalToConstant: 16),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(attachment.accessibilityDescription)
        setAccessibilityHelp("Press Space to preview, Delete to remove.")
        toolTip = attachment.fileURL?.path ?? attachment.name
        loadThumbnail()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    isolated deinit {
        thumbnailTask?.cancel()
        discardPreview()
    }

    private static func icon(for attachment: ComposerAttachment) -> NSImage {
        if let url = attachment.fileURL { return NSWorkspace.shared.icon(forFile: url.path) }
        let type = UTType(mimeType: attachment.mimeType) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    private func loadThumbnail() {
        guard attachment.kind == .image else { return }
        let attachment = self.attachment
        let pixels = Int((style.chipHeight - 8) * 3)
        thumbnailTask = Task { [weak self] in
            guard let image = await ThumbnailLoader.shared.thumbnail(for: attachment, maxPixelSize: pixels) else { return }
            guard !Task.isCancelled, let self else { return }
            self.icon.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    /// Waits for the thumbnail (scripted scenarios, before a snapshot).
    func settle() async { await thumbnailTask?.value }

    @objc private func remove() { onRemove?(attachment.id) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        // `fillHover` chip with a `border` hairline inside, `r.md` (DesignSystem; text plus icon, never colour alone).
        DSDraw.fill(rect, radius: DS.Radius.md, color: DS.Color.fillHover)
        DSDraw.ring(rect, radius: DS.Radius.md, color: style.increasedContrast ? DS.Color.borderStrong : DS.Color.border)
    }

    // MARK: Keyboard and Quick Look

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { DS.Radius.path(bounds, radius: DS.Radius.md).fill() }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ": toggleQuickLook()
        case "\u{7F}", "\u{F728}": remove()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { toggleQuickLook() }
    }

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        let attachment = self.attachment
        Task { [weak self] in
            let url = await ThumbnailLoader.shared.previewURL(for: attachment)
            guard let self, let url else {
                if case .file = attachment.content {} else { await ThumbnailLoader.shared.discardPreview(for: attachment.id) }
                return
            }
            self.previewURL = url
            if case .file = attachment.content {} else { self.ownsPreviewFile = true }
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    /// Deletes the preview file this chip wrote, if any (preview ended, attachment removed, teardown).
    func discardPreview() {
        guard ownsPreviewFile else { return }
        ownsPreviewFile = false
        previewURL = nil
        let id = attachment.id
        Task { await ThumbnailLoader.shared.discardPreview(for: id) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            discardPreview()
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }
}
