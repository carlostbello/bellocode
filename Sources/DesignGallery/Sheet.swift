import AppKit
import DesignSystem

/// A flipped canvas that stacks labelled rows of views at their intrinsic (or given) sizes.
@MainActor
final class Sheet: NSView {
    private(set) var cursorY: CGFloat = 24
    let width: CGFloat
    let labelWidth: CGFloat = 150
    var background: NSColor = DS.Color.canvas

    init(width: CGFloat) {
        self.width = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
    }

    func heading(_ text: String) {
        cursorY += 8
        let label = makeLabel(text, role: .title, color: DS.Color.text)
        label.frame = NSRect(x: 24, y: cursorY, width: width - 48, height: 20)
        addSubview(label)
        cursorY += 26
    }

    func caption(_ text: String) {
        let label = makeLabel(text, role: .label, color: DS.Color.text3)
        label.frame = NSRect(x: 24, y: cursorY, width: width - 48, height: 16)
        addSubview(label)
        cursorY += 20
    }

    /// One row: a label column then the views left to right. `sizes` overrides intrinsic sizes per view.
    func row(_ title: String, _ views: [NSView], sizes: [NSSize?] = [], gap: CGFloat = 12, height: CGFloat? = nil) {
        let resolved = views.enumerated().map { index, view -> NSSize in
            if index < sizes.count, let size = sizes[index] { return size }
            let size = view.intrinsicContentSize
            return NSSize(width: size.width > 0 ? size.width : 120, height: size.height > 0 ? size.height : 28)
        }
        let rowHeight = height ?? max(28, resolved.map(\.height).max() ?? 28)
        let label = makeLabel(title, role: .label, color: DS.Color.text3)
        label.frame = NSRect(x: 24, y: cursorY + (rowHeight - 16) / 2, width: labelWidth - 8, height: 16)
        addSubview(label)
        var x = 24 + labelWidth
        for (view, size) in zip(views, resolved) {
            view.frame = NSRect(x: x, y: cursorY + (rowHeight - size.height) / 2, width: size.width, height: size.height)
            addSubview(view)
            x += size.width + gap
        }
        cursorY += rowHeight + 10
    }

    /// Places a view full-width (minus margins) at a given height.
    func block(_ view: NSView, height: CGFloat, x: CGFloat = 24, width: CGFloat? = nil) {
        view.frame = NSRect(x: x, y: cursorY, width: width ?? (self.width - 48), height: height)
        addSubview(view)
        cursorY += height + 12
    }

    func space(_ height: CGFloat) { cursorY += height }

    func finish() {
        setFrameSize(NSSize(width: width, height: cursorY + 24))
    }
}

@MainActor
func makeLabel(_ text: String, role: DS.TextRole, color: NSColor) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = role.font
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    return label
}

/// Renders a view in an offscreen window with an appearance and writes a PNG.
@MainActor
enum Renderer {
    static func render(_ make: () -> Sheet, appearance: NSAppearance.Name, to url: URL, smoothing: Bool) throws {
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: appearance)
        defer { NSApp.appearance = previous }
        let sheet = make()
        sheet.finish()
        let window = NSWindow(contentRect: sheet.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.contentView = sheet
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        window.makeFirstResponder(nil)
        sheet.layoutSubtreeIfNeeded()
        sheet.displayIfNeeded()
        // 2x, like the mock PNGs (the offscreen window is on no screen, so its own backing scale is 1).
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(sheet.bounds.width * scale), pixelsHigh: Int(sheet.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw GalleryError.render }
        rep.size = sheet.bounds.size
        if smoothing {
            sheet.cacheDisplay(in: sheet.bounds, to: rep)
        } else {
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else { throw GalleryError.render }
            context.cgContext.setAllowsFontSmoothing(false)
            context.cgContext.setShouldSmoothFonts(false)
            sheet.displayIgnoringOpacity(sheet.bounds, in: context)
        }
        guard let data = rep.representation(using: .png, properties: [:]) else { throw GalleryError.render }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        window.orderOut(nil)
        window.close()
    }
}

enum GalleryError: Error { case render }
