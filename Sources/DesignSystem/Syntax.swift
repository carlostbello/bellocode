import AppKit

extension DS {
    /// Syntax-highlighting colours for code in the transcript and diffs. Dynamic: light, dark and their Increase
    /// Contrast variants (based on Xcode's default themes, tuned to read on `contentBackground` and code fills).
    public enum Syntax {
        public static let keyword = color("Keyword", light: 0x9B2393, dark: 0xFC5FA3, lightHC: 0x7A0F72, darkHC: 0xFF8AC0)
        public static let type = color("Type", light: 0x0B4F79, dark: 0x5DD8FF, lightHC: 0x053A5C, darkHC: 0x8FE6FF)
        public static let string = color("String", light: 0xC41A16, dark: 0xFC6A5D, lightHC: 0x9A0F0C, darkHC: 0xFF9488)
        public static let comment = color("Comment", light: 0x5D6C79, dark: 0x7F8C98, lightHC: 0x3E4A55, darkHC: 0xA9B4BE)
        public static let number = color("Number", light: 0x1C00CF, dark: 0xD0BF69, lightHC: 0x1400A0, darkHC: 0xE6D78A)
        public static let function = color("Function", light: 0x326D74, dark: 0x67B7A4, lightHC: 0x1F5157, darkHC: 0x8ED6C4)
        public static let property = color("Property", light: 0x6C36A9, dark: 0xA167E6, lightHC: 0x52248A, darkHC: 0xC197F2)
        public static let meta = color("Meta", light: 0x643820, dark: 0xFD8F3F, lightHC: 0x4A2612, darkHC: 0xFFAE70)
        public static let variable = color("Variable", light: 0x3900A0, dark: 0xD0A8FF, lightHC: 0x2A0078, darkHC: 0xE0C6FF)
        public static let tag = type
        public static let attribute = property

        /// Diff lines: text colours (always paired with a +/- glyph, never colour alone).
        public static let diffAdded = color("DiffAdded", light: 0x1A7F37, dark: 0x56D364, lightHC: 0x0F5C25, darkHC: 0x7EE787)
        public static let diffRemoved = color("DiffRemoved", light: 0xCF222E, dark: 0xF47067, lightHC: 0xA0111B, darkHC: 0xFF938A)
        public static let diffHunk = color("DiffHunk", light: 0x8250DF, dark: 0xB083F0, lightHC: 0x6334B8, darkHC: 0xCBA6F7)
        public static let diffHeader = NSColor.secondaryLabelColor

        /// Background of code blocks and tool output in the transcript.
        public static let codeBackground = NSColor(name: "BelloCodeCodeBackground") { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua: NSColor(white: 1, alpha: 0.055)
            case .accessibilityHighContrastDarkAqua: NSColor(white: 1, alpha: 0.10)
            case .accessibilityHighContrastAqua: NSColor(white: 0, alpha: 0.07)
            default: NSColor(white: 0, alpha: 0.035)
            }
        }

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
