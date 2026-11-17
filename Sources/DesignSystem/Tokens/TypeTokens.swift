import AppKit
import SwiftUI

// visual-language.md §2. SF Pro and SF Mono from the system (no bundled fonts). Every role is `base + delta`, where
// base is `DS.Typography.current.baseSize` (13 by default, the app's text-size setting), so one setting scales all.

extension DS {
    /// A type role: size and line height as deltas from the base size, weight, tracking and family.
    public enum TextRole: String, Sendable, CaseIterable, Hashable {
        case prose, proseH1, proseH2, proseH3, composer
        case body, bodyEmph, title
        case label, labelEmph
        case meta, metaEmph
        case code, codeSmall, terminal

        /// The spec's value at the default base (13): size, line height, weight, tracking (pt), monospaced.
        public var spec: (size: CGFloat, lineHeight: CGFloat, weight: NSFont.Weight, tracking: CGFloat, mono: Bool) {
            switch self {
            case .prose: (14, 22, .regular, 0, false)
            case .proseH1: (18, 23, .semibold, 0, false)
            case .proseH2: (16, 21, .semibold, 0, false)
            case .proseH3: (14, 18, .semibold, 0, false)
            case .composer: (14, 21, .regular, 0, false)
            case .body: (13, 18, .regular, -0.08, false)
            case .bodyEmph: (13, 18, .medium, -0.08, false)
            case .title: (13, 18, .semibold, -0.08, false)
            case .label: (12, 16, .regular, 0, false)
            case .labelEmph: (12, 16, .medium, 0, false)
            case .meta: (11, 14, .regular, 0.06, false)
            case .metaEmph: (11, 14, .medium, 0.06, false)
            case .code: (12.5, 19, .regular, 0, true)
            case .codeSmall: (11.5, 19, .regular, 0, true)
            case .terminal: (12, 14.4, .regular, 0, true)
            }
        }

        public static let defaultBase: CGFloat = 13

        public func size(base: CGFloat) -> CGFloat { spec.size + (base - Self.defaultBase) }
        public func lineHeight(base: CGFloat) -> CGFloat { spec.lineHeight + (base - Self.defaultBase) }

        /// The font at `base`. System fonts are cached by AppKit; this is cheap enough for row configuration.
        public func font(base: CGFloat, monospacedDigits: Bool = false) -> NSFont {
            let s = spec
            if s.mono { return .monospacedSystemFont(ofSize: size(base: base), weight: s.weight) }
            if monospacedDigits { return .monospacedDigitSystemFont(ofSize: size(base: base), weight: s.weight) }
            return .systemFont(ofSize: size(base: base), weight: s.weight)
        }

        /// At the app's current base size.
        @MainActor public var font: NSFont { font(base: DS.Typography.current.baseSize) }
        @MainActor public var lineHeight: CGFloat { lineHeight(base: DS.Typography.current.baseSize) }

        /// Text attributes with the role's line height and tracking (for `NSAttributedString` / text views).
        public func attributes(
            base: CGFloat, color: NSColor, alignment: NSTextAlignment = .natural, lineBreak: NSLineBreakMode = .byTruncatingTail
        ) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineHeight(base: base)
            paragraph.maximumLineHeight = lineHeight(base: base)
            paragraph.alignment = alignment
            paragraph.lineBreakMode = lineBreak
            let font = font(base: base)
            return [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph, .kern: spec.tracking,
                // Centre glyphs in the fixed line height.
                .baselineOffset: (lineHeight(base: base) - (font.ascender - font.descender)) / 4,
            ]
        }

        @MainActor public func attributes(color: NSColor, alignment: NSTextAlignment = .natural) -> [NSAttributedString.Key: Any] {
            attributes(base: DS.Typography.current.baseSize, color: color, alignment: alignment)
        }

        /// SwiftUI font at `base`.
        public func swiftUIFont(base: CGFloat) -> SwiftUI.Font {
            let s = spec
            let weight: SwiftUI.Font.Weight =
                switch s.weight {
                case .medium: .medium
                case .semibold: .semibold
                case .bold: .bold
                default: .regular
                }
            return .system(size: size(base: base), weight: weight, design: s.mono ? .monospaced : .default)
        }
    }
}

extension SwiftUI.Font {
    /// `Font.ds(.body)`: a DesignSystem role at the app's current base size.
    @MainActor public static func ds(_ role: DS.TextRole) -> SwiftUI.Font { role.swiftUIFont(base: DS.Typography.current.baseSize) }
}

extension NSFont {
    /// `NSFont.ds(.body)`: a DesignSystem role at the app's current base size.
    @MainActor public static func ds(_ role: DS.TextRole) -> NSFont { role.font }
}
