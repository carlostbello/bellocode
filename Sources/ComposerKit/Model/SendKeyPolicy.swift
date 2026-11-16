/// Which key sends. A product decision (research 03, section D), so it is a setting.
public enum SendKey: String, Hashable, Sendable, Codable, CaseIterable {
    /// Return sends; Shift-Return or Option-Return inserts a newline; Command-Return sends the alternate follow-up.
    case returnKey
    /// Command-Return sends; Return inserts a newline; Command-Option-Return sends the alternate follow-up.
    case commandReturn
}

/// How a prompt reaches the agent.
public enum ComposerDelivery: String, Hashable, Sendable, Codable {
    /// The agent is idle: start a turn.
    case now
    /// After the running turn ends, one at a time.
    case queue
    /// At the next safe step boundary of the running turn.
    case steer

    /// Button and menu label.
    public var title: String {
        switch self {
        case .now: "Send"
        case .queue: "Queue"
        case .steer: "Steer"
        }
    }

    /// Announced once the server admitted the prompt.
    public var acknowledgement: String {
        switch self {
        case .now: "Sent"
        case .queue: "Queued"
        case .steer: "Steer message accepted"
        }
    }

    /// Longer description for tooltips and VoiceOver.
    public var explanation: String {
        switch self {
        case .now: "Send now"
        case .queue: "Queue: deliver after the current turn ends"
        case .steer: "Steer: deliver at the agent's next step"
        }
    }
}

/// Modifier state of a key press, independent of AppKit so the policy is testable.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1)
    public static let option = KeyModifiers(rawValue: 2)
    public static let command = KeyModifiers(rawValue: 4)
    public static let control = KeyModifiers(rawValue: 8)
}

/// What Return (or keypad Enter) does.
public enum ReturnKeyAction: Hashable, Sendable {
    /// Leave it to the input method (composition in progress). Never send.
    case inputMethod
    case newline
    /// Send. `alternate` picks the opposite of the default follow-up while the agent runs.
    case send(alternate: Bool)
}

public enum SendKeyPolicy {
    public static func action(sendKey: SendKey, modifiers: KeyModifiers, hasMarkedText: Bool) -> ReturnKeyAction {
        if hasMarkedText { return .inputMethod }
        switch sendKey {
        case .returnKey:
            if modifiers.isEmpty { return .send(alternate: false) }
            if modifiers == .command { return .send(alternate: true) }
            return .newline
        case .commandReturn:
            if modifiers == .command { return .send(alternate: false) }
            if modifiers == [.command, .option] { return .send(alternate: true) }
            return .newline
        }
    }

    /// The delivery for a send. Idle: now. Running: the default follow-up, or the other one when `alternate`.
    /// Steer falls back to queue when the host cannot steer.
    public static func delivery(
        alternate: Bool, isRunning: Bool, defaultFollowUp: ComposerDelivery, supportsSteer: Bool
    ) -> ComposerDelivery {
        guard isRunning else { return .now }
        let preferred: ComposerDelivery = defaultFollowUp == .steer ? .steer : .queue
        let chosen: ComposerDelivery = alternate ? (preferred == .queue ? .steer : .queue) : preferred
        return chosen == .steer && !supportsSteer ? .queue : chosen
    }

    /// Key equivalent text for menus and tooltips: "⏎", "⌘⏎", "⌥⌘⏎".
    public static func shortcutLabel(sendKey: SendKey, alternate: Bool) -> String {
        switch (sendKey, alternate) {
        case (.returnKey, false): "⏎"
        case (.returnKey, true): "⌘⏎"
        case (.commandReturn, false): "⌘⏎"
        case (.commandReturn, true): "⌥⌘⏎"
        }
    }
}

/// Decides whether text looks like code, to turn spell checking off for it (red underlines on identifiers are noise).
public enum CodeLikeText {
    public static func isCodeLike(_ text: String) -> Bool {
        if text.contains("```") { return true }
        var symbols = 0
        var visible = 0
        var indentedLines = 0
        var lines = 0
        var atLineStart = true
        var leadingSpaces = 0
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                lines += 1
                atLineStart = true
                leadingSpaces = 0
                continue
            }
            if atLineStart {
                if scalar == " " {
                    leadingSpaces += 1
                    if leadingSpaces == 4 { indentedLines += 1 }
                    continue
                }
                if scalar == "\t" {
                    indentedLines += 1
                    atLineStart = false
                    continue
                }
                atLineStart = false
            }
            if scalar.properties.isWhitespace { continue }
            visible += 1
            if "{}[]();=<>|&$`\\".unicodeScalars.contains(scalar) { symbols += 1 }
        }
        lines += 1
        if lines >= 3, indentedLines * 2 >= lines { return true }
        guard visible >= 12 else { return false }
        return Double(symbols) / Double(visible) >= 0.08
    }
}
