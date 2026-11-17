import AppKit
import Engine
import Foundation
import Observation
import SwiftTerm
import Synchronization
import os

/// Re-runs `body` whenever an `@Observable` value it read changes, on the main actor, until cancelled.
@MainActor
final class TerminalObservation {
    private var active = true
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
        track()
    }

    func cancel() { active = false }

    private func track() {
        guard active else { return }
        withObservationTracking { body() } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }
}

/// Feeds a SwiftTerm view from the stream's feed task (off the main actor) through its thread-safe feed sender.
struct TerminalFeedSink: TerminalOutputSink {
    let sender: TerminalFeedSender

    func reset(trimmed: Bool) {
        // RIS, then clear scrollback (xterm `CSI 3 J`); the replay that follows rebuilds the screen.
        sender.feed(text: "\u{1B}c\u{1B}[3J")
        if trimmed {
            sender.feed(text: "\u{1B}[2m[earlier output is no longer kept by opencode]\u{1B}[0m\r\n")
        }
    }

    func feed(_ data: Data) {
        data.withUnsafeBytes { buffer in
            sender.feed(byteArray: ArraySlice(buffer.bindMemory(to: UInt8.self)))
        }
    }
}

/// OSC 133 prompt state from the emulator's OSC observer (a private queue), read on the main actor.
final class SemanticPromptTracker: Sendable {
    private let state = Mutex<Bool?>(nil)

    /// True at the shell prompt (A or B since the last C/D), false while a command runs, nil if the shell never sent
    /// OSC 133.
    var atPrompt: Bool? { state.withLock { $0 } }

    func observe(_ event: TerminalOscEvent) {
        guard event.code == 133, let first = event.payload.first else { return }
        switch first {
        case UInt8(ascii: "A"), UInt8(ascii: "B"): state.withLock { $0 = true }
        case UInt8(ascii: "C"), UInt8(ascii: "D"): state.withLock { $0 = false }
        default: break
        }
    }
}

enum TerminalKitSignposts {
    static let ui = OSSignposter(subsystem: "app.bellocode.TerminalKit", category: "Terminal")
}

/// Shells whose prompt runs a pasted line at once.
let interactiveShells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "-sh", "login"]

/// A small capsule label with a glyph and text (status is never colour-only).
@MainActor
final class TerminalStatusPill: NSView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 18),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ text: String, symbol: String) {
        label.stringValue = text
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        icon.contentTintColor = .secondaryLabelColor
        setAccessibilityLabel(text)
        isHidden = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
    }
}
