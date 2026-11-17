import AppKit

extension DS {
    /// Syntax-highlighting colours for code in the transcript and diffs. The seven spec roles alias `DS.Color.syntax*`
    /// (Xcode's default themes, visual-language.md §1); `meta` and `variable` are BelloCode extras.
    public enum Syntax {
        public static let keyword = DS.Color.syntaxKeyword
        public static let type = DS.Color.syntaxType
        public static let string = DS.Color.syntaxString
        public static let comment = DS.Color.syntaxComment
        public static let number = DS.Color.syntaxNumber
        public static let function = DS.Color.syntaxFunction
        public static let property = DS.Color.syntaxProperty
        public static let meta = color("Meta", light: 0x643820, dark: 0xFD8F3F, lightHC: 0x4A2612, darkHC: 0xFFAE70)
        public static let variable = color("Variable", light: 0x3900A0, dark: 0xD0A8FF, lightHC: 0x2A0078, darkHC: 0xE0C6FF)
        public static let tag = type
        public static let attribute = property

        /// Diff lines: text colours (always paired with a +/- glyph, never colour alone).
        public static let diffAdded = DS.Color.successText
        public static let diffRemoved = DS.Color.dangerText
        public static let diffHunk = DS.Color.text3
        public static let diffHeader = DS.Color.text2

        /// Background of code blocks and tool output in the transcript.
        public static let codeBackground = DS.Color.codeFill

        private static func color(_ name: String, light: UInt32, dark: UInt32, lightHC: UInt32, darkHC: UInt32) -> NSColor {
            NSColor(name: "BelloCodeSyntax\(name)") { appearance in
                let hex: UInt32 =
                    switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
                    case .darkAqua: dark
                    case .accessibilityHighContrastAqua: lightHC
                    case .accessibilityHighContrastDarkAqua: darkHC
                    default: light
                    }
                return NSColor(
                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            }
        }
    }
}
