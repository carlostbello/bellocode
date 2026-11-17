import AppKit
import DesignSystem
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
    /// The last few kilobytes of output as text, for dev-server URL detection (bounded; decoded from each chunk's tail).
    var tail: OutputTail? = nil

    func reset(trimmed: Bool) {
        // RIS, then clear scrollback (xterm `CSI 3 J`); the replay that follows rebuilds the screen.
        sender.feed(text: "\u{1B}c\u{1B}[3J")
        if trimmed {
            sender.feed(text: "\u{1B}[2m[earlier output is no longer kept by opencode]\u{1B}[0m\r\n")
        }
    }

    func feed(_ data: Data) {
        tail?.append(data)
        data.withUnsafeBytes { buffer in
            sender.feed(byteArray: ArraySlice(buffer.bindMemory(to: UInt8.self)))
        }
    }
}

/// A bounded tail of terminal output as text (escape sequences included; callers match URLs only).
final class OutputTail: Sendable {
    static let limit = 4_096
    private let text = Mutex("")
    private let dirty = Mutex(false)

    func append(_ data: Data) {
        let piece = String(decoding: data.suffix(Self.limit), as: UTF8.self)
        text.withLock { value in
            value += piece
            if value.utf8.count > Self.limit { value = String(value.suffix(Self.limit)) }
        }
        dirty.withLock { $0 = true }
    }

    /// The tail if it changed since the last call.
    func takeIfChanged() -> String? {
        guard dirty.withLock({ value in defer { value = false }; return value }) else { return nil }
        return text.withLock { $0 }
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

/// A status pill (§6 "Pills"): 18 high, `r.xs`, `fillSubtle` with a `border` ring, 10 pt glyph + `meta` word in
/// `text2` (status is never colour-only). Floats over the terminal, so it carries its own fill.
@MainActor
final class TerminalStatusPill: NSView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = DS.Space.s4
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: DS.Space.s6, bottom: 0, right: DS.Space.s6)
        label.font = DS.TextRole.meta.font
        label.textColor = DS.Color.text2
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: DS.Size.pill),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ text: String, symbol: String) {
        label.stringValue = text
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: DS.Size.iconPointMeta, weight: .regular))
        icon.contentTintColor = DS.Color.icon
        setAccessibilityLabel(text)
        isHidden = false
    }

    override func draw(_ dirtyRect: NSRect) {
        DSDraw.fill(bounds, radius: DS.Radius.xs, color: DS.Color.raised)
        DSDraw.fill(bounds, radius: DS.Radius.xs, color: DS.Color.fillSubtle)
        DSDraw.ring(bounds, radius: DS.Radius.xs, color: DS.Color.border)
    }
}
