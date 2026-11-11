import AppKit
import SwiftTerm

/// Terminal colors for light and dark appearance (original palettes).
struct TerminalTheme {
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let ansi: [SwiftTerm.Color]

    static func current(for appearance: NSAppearance) -> TerminalTheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    static let dark = TerminalTheme(
        background: NSColor(hex: 0x1C1C1E),
        foreground: NSColor(hex: 0xE5E5EA),
        cursor: NSColor(hex: 0x64B5FF),
        ansi: [
            0x2E2E30, 0xFF6B6B, 0x5FD38D, 0xF5C451, 0x5AA9FF, 0xD68CFF, 0x4FD1D9, 0xD0D0D5,
            0x6E6E73, 0xFF8A8A, 0x7EE2A8, 0xFFD873, 0x85C1FF, 0xE3A9FF, 0x7BE3EA, 0xF5F5F7,
        ].map(SwiftTerm.Color.init(hex:))
    )

    static let light = TerminalTheme(
        background: NSColor(hex: 0xFFFFFF),
        foreground: NSColor(hex: 0x1D1D1F),
        cursor: NSColor(hex: 0x0A6CFF),
        ansi: [
            0x1D1D1F, 0xC8282B, 0x1F8A3D, 0x9A6A00, 0x1F5FD1, 0x9B2FAE, 0x0F7C8C, 0x6E6E73,
            0x636366, 0xE0393C, 0x2BA24F, 0xB88400, 0x2F74F0, 0xB34BC7, 0x1497AA, 0x3A3A3C,
        ].map(SwiftTerm.Color.init(hex:))
    )
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

extension SwiftTerm.Color {
    convenience init(hex: UInt32) {
        self.init(red: UInt16((hex >> 16) & 0xFF) * 257,
                  green: UInt16((hex >> 8) & 0xFF) * 257,
                  blue: UInt16(hex & 0xFF) * 257)
    }
}
