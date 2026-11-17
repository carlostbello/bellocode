import AppKit
import SwiftUI

/// The popover surface for SwiftUI pickers (AgentUI, DiffKit; visual-language.md §6 "Menus, popovers, model picker"): its own borderless
/// panel, `r.lg`, the popover glass (`raised` 80 % over the material, `borderStrong` ring, popover shadow; solid
/// `raised` under Reduce Transparency), no arrow. Replaces SwiftUI's `.popover`, whose system chrome and arrow do not
/// match. The panel becomes key (pickers have a focused search field), follows its window as a child window, and closes
/// on Escape (the content's own handler), on a click elsewhere (it resigns key) or when `isPresented` turns false.
extension View {
    /// `transformContent` re-applies environment values the host set (SwiftUI does not carry them into the panel).
    public func glassPopover<Content: View>(
        isPresented: Binding<Bool>, width: CGFloat, transformContent: @escaping (AnyView) -> AnyView = { $0 },
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        background(GlassPopoverAnchor(isPresented: isPresented, width: width, transform: transformContent, content: content))
    }
}

@MainActor
public final class GlassPopoverPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public override func cancelOperation(_ sender: Any?) { close() }
}

private struct GlassPopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let width: CGFloat
    let transform: (AnyView) -> AnyView
    let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onClose = { isPresented = false }
        let root = AnyView(transform(AnyView(content())).environment(\.colorScheme, colorScheme))
        if isPresented {
            coordinator.present(root, width: width)
        } else {
            coordinator.dismiss()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.dismiss() }

    @MainActor
    final class Coordinator {
        weak var anchor: NSView?
        var onClose: (() -> Void)?
        private var panel: GlassPopoverPanel?
        private var hosting: NSHostingView<AnyView>?
        private var observer: (any NSObjectProtocol)?

        func present(_ root: AnyView, width: CGFloat) {
            if let hosting {
                hosting.rootView = root
                resize(width: width)
                return
            }
            guard let anchor, let window = anchor.window else { return }
            let glass = DSGlassView(surface: .popover, radius: DS.Radius.lg)
            glass.showsShadow = false  // the panel's window shadow follows the glass shape
            let hosting = NSHostingView(rootView: root)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            ])
            let panel = GlassPopoverPanel(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 100), styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.animationBehavior = .none
            panel.appearance = window.effectiveAppearance
            panel.contentView = glass
            self.panel = panel
            self.hosting = hosting
            resize(width: width)
            window.addChildWindow(panel, ordered: .above)
            panel.makeKeyAndOrderFront(nil)
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeFromPanel() }
            }
        }

        /// Below the anchor when there is room, otherwise above it (pickers in the composer open upwards).
        private func resize(width: CGFloat) {
            guard let panel, let hosting, let anchor, let window = anchor.window else { return }
            let height = min(max(hosting.fittingSize.height, 40), 520)
            let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let visible = window.screen?.visibleFrame ?? .infinite
            var origin = NSPoint(x: anchorRect.minX, y: anchorRect.minY - 4 - height)
            if origin.y < visible.minY { origin.y = anchorRect.maxY + 4 }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - width - 4)
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
            panel.invalidateShadow()
        }

        private func closeFromPanel() {
            dismiss()
            onClose?()
        }

        func dismiss() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let panel else { return }
            self.panel = nil
            hosting = nil
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            anchor?.window?.makeKey()
        }
    }
}
