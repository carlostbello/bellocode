import BelloCore
import Foundation
import Observation

/// Input state and validation for a structured question (opencode form) or a login method's form.
///
/// Every field type in the contract is supported: `string` (free text, or a single choice when it has options, with
/// "Other" when `custom`), `number`, `integer`, `boolean`, `multiselect` (with `custom`), and `external` (a link to
/// open; nothing to submit). `when` conditions hide fields and drop their answers; `hidden` fields submit their default.
/// Typed text is kept as typed, so invalid input is never lost.
///
/// Secrets: the contract has no secret field type. A text field whose key or title names a password, token, secret or
/// key is treated as secret (`isSecret`): rendered as a secure field and excluded from `description`.
@MainActor
@Observable
public final class QuestionFormModel {
    public let fields: [QuestionField]
    public var text: [String: String] = [:]
    /// The chosen option per single-choice field (`QuestionFormModel.other` for the custom answer).
    public var choice: [String: String] = [:]
    public var selections: [String: Set<String>] = [:]
    public var flags: [String: Bool] = [:]
    /// Errors show after the first submit attempt, then update live.
    public private(set) var showsErrors = false

    public static let other = "\u{0}other"

    public init(fields: [QuestionField]) {
        self.fields = fields
        for field in fields {
            switch (field.kind, field.defaultValue) {
            case (.boolean, .bool(let value)?): flags[field.key] = value
            case (.boolean, _): flags[field.key] = false
            case (.multiselect, .choices(let values)?): selections[field.key] = Set(values)
            case (.text, .text(let value)?) where !field.options.isEmpty:
                if field.options.contains(where: { $0.value == value }) {
                    choice[field.key] = value
                } else {
                    choice[field.key] = Self.other
                    text[field.key] = value
                }
            case (_, .text(let value)?): text[field.key] = value
            case (_, .number(let value)?): text[field.key] = Self.format(value, integer: field.kind == .integer)
            default: break
            }
        }
    }

    // MARK: Visibility

    /// Fields the user sees, in order.
    public var visibleFields: [QuestionField] { fields.filter(isVisible) }

    public func isVisible(_ field: QuestionField) -> Bool {
        !field.hidden && field.conditions.allSatisfy { condition in
            let current = answer(for: condition.key)
            let equal = current.map { Self.same($0, condition.value) } ?? false
            return condition.equals ? equal : !equal
        }
    }

    public static func isSecret(_ field: QuestionField) -> Bool {
        guard field.kind == .text, field.options.isEmpty else { return false }
        let words = "\(field.key) \(field.title ?? "")".lowercased()
        return ["password", "passphrase", "token", "secret", "api key", "apikey", "api_key", "private key"].contains {
            words.contains($0)
        }
    }

    // MARK: Answers

    /// The answer for one field from the current input, or nil when empty.
    public func answer(for key: String) -> QuestionAnswer? {
        guard let field = fields.first(where: { $0.key == key }) else { return nil }
        if field.hidden { return field.defaultValue }
        switch field.kind {
        case .boolean:
            return .bool(flags[key] ?? false)
        case .multiselect:
            var values = Array(selections[key] ?? []).filter { $0 != Self.other }
            values.sort { lhs, rhs in
                (field.options.firstIndex { $0.value == lhs } ?? Int.max) < (field.options.firstIndex { $0.value == rhs } ?? Int.max)
            }
            if selections[key]?.contains(Self.other) == true, let custom = trimmed(key) { values.append(custom) }
            return values.isEmpty ? nil : .choices(values)
        case .number, .integer:
            guard let raw = trimmed(key), let value = Double(raw) else { return nil }
            return .number(value)
        case .external:
            return nil
        case .text where !field.options.isEmpty:
            guard let selected = choice[key] else { return nil }
            if selected == Self.other { return trimmed(key).map(QuestionAnswer.text) }
            return .text(selected)
        default:
            return trimmed(key).map(QuestionAnswer.text)
        }
    }

    /// Answers to submit: visible fields with a value, plus hidden fields' defaults.
    public func answers() -> [String: QuestionAnswer] {
        var result: [String: QuestionAnswer] = [:]
        for field in fields where field.hidden || isVisible(field) {
            if let value = answer(for: field.key) { result[field.key] = value }
        }
        return result
    }

    // MARK: Validation

    public func error(for field: QuestionField) -> String? {
        guard isVisible(field) else { return nil }
        let key = field.key
        let rules = field.validation
        switch field.kind {
        case .external, .boolean:
            return nil
        case .multiselect:
            let count = answer(for: key).flatMap { if case .choices(let values) = $0 { values.count } else { nil } } ?? 0
            if selections[key]?.contains(Self.other) == true, trimmed(key) == nil { return "Type your answer, or clear “Other”." }
            if field.required, count == 0 { return "Choose at least one." }
            if let minimum = rules.minItems, count > 0 || field.required, count < minimum { return "Choose at least \(minimum)." }
            if let maximum = rules.maxItems, count > maximum { return "Choose at most \(maximum)." }
            return nil
        case .number, .integer:
            guard let raw = trimmed(key) else { return field.required ? "Required." : nil }
            guard let value = Double(raw), value.isFinite else { return "Enter a number." }
            if field.kind == .integer, value.rounded() != value { return "Enter a whole number." }
            if let minimum = rules.minimum, value < minimum { return "At least \(Self.format(minimum, integer: false))." }
            if let maximum = rules.maximum, value > maximum { return "At most \(Self.format(maximum, integer: false))." }
            return nil
        default:
            if !field.options.isEmpty {
                guard let selected = choice[key] else { return field.required ? "Choose one." : nil }
                if selected != Self.other { return nil }
                guard trimmed(key) != nil else { return "Type your answer." }
            }
            guard let value = trimmed(key) else { return field.required ? "Required." : nil }
            if let minimum = rules.minLength, value.count < minimum { return "At least \(minimum) characters." }
            if let maximum = rules.maxLength, value.count > maximum { return "At most \(maximum) characters." }
            if let pattern = rules.pattern, value.range(of: pattern, options: .regularExpression) == nil {
                return field.placeholder.map { "Doesn’t look right. Example: \($0)" } ?? "Doesn’t match the expected format."
            }
            switch rules.format {
            case "email" where !value.contains("@") || value.hasPrefix("@") || value.hasSuffix("@"):
                return "Enter an email address."
            case "uri" where URL(string: value)?.scheme == nil:
                return "Enter a full URL, including https://."
            default:
                return nil
            }
        }
    }

    /// Errors only after the first submit attempt.
    public func visibleError(for field: QuestionField) -> String? { showsErrors ? error(for: field) : nil }

    public var isValid: Bool { fields.allSatisfy { error(for: $0) == nil } }

    /// Marks a submit attempt; returns whether the form can be submitted.
    @discardableResult
    public func validateForSubmit() -> Bool {
        showsErrors = true
        return isValid
    }

    // MARK: Helpers

    private func trimmed(_ key: String) -> String? {
        let value = (text[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func same(_ lhs: QuestionAnswer, _ rhs: QuestionAnswer) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.bool(let a), .bool(let b)): a == b
        case (.choices(let a), .choices(let b)): Set(a) == Set(b)
        case (.text(let a), .number(let b)), (.number(let b), .text(let a)): Double(a) == b
        default: false
        }
    }

    static func format(_ value: Double, integer: Bool) -> String {
        if integer || value.rounded() == value, abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }
}

extension QuestionFormModel: CustomStringConvertible {
    /// Field keys and whether each has a value; never the values (they may be secret).
    nonisolated public var description: String { "QuestionFormModel(<redacted>)" }
}
