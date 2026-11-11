import AppKit

/// Editor colors; every color adapts to light/dark appearance.
public enum CodeTheme {
    public static func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .comment: dynamic(light: 0x6E7781, dark: 0x7F8C98)
        case .string: dynamic(light: 0xC41A16, dark: 0xFC6A5D)
        case .keyword: dynamic(light: 0x9B2393, dark: 0xFC5FA3)
        case .builtin: dynamic(light: 0x3E8087, dark: 0x67B7A4)
        case .constant: dynamic(light: 0x9B2393, dark: 0xFC5FA3)
        case .number: dynamic(light: 0x1C00CF, dark: 0xD0BF69)
        case .variable: dynamic(light: 0x6C36A9, dark: 0xA167E6)
        case .key: dynamic(light: 0x0B4F79, dark: 0x5DD8FF)
        case .type: dynamic(light: 0x0B4F79, dark: 0x5DD8FF)
        case .function: dynamic(light: 0x326D74, dark: 0x67B7A4)
        case .section: dynamic(light: 0x643820, dark: 0xFD8F3F)
        case .tag: dynamic(light: 0x0B4F79, dark: 0x5DD8FF)
        case .attribute: dynamic(light: 0x815F03, dark: 0xBF8555)
        }
    }

    public static let text = NSColor.textColor
    public static let background = dynamic(light: 0xFFFFFF, dark: 0x1F1F24)
    public static let gutterText = NSColor.tertiaryLabelColor
    public static let currentLine = dynamic(light: 0xECF5FF, dark: 0x23252B)

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}
