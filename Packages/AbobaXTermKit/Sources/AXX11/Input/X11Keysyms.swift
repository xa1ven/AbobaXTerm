import Foundation

/// X keysym values and the mapping from Mac virtual key codes / Unicode.
enum X11Keysym {
    static let noSymbol: UInt32 = 0

    static let shiftL: UInt32 = 0xFFE1, shiftR: UInt32 = 0xFFE2
    static let controlL: UInt32 = 0xFFE3, controlR: UInt32 = 0xFFE4
    static let capsLock: UInt32 = 0xFFE5
    static let altL: UInt32 = 0xFFE9, altR: UInt32 = 0xFFEA
    static let superL: UInt32 = 0xFFEB, superR: UInt32 = 0xFFEC

    /// Keys that mean the same on every layout, by Mac virtual key code.
    static let special: [UInt16: UInt32] = [
        36: 0xFF0D, // Return
        48: 0xFF09, // Tab
        49: 0x0020, // space
        51: 0xFF08, // BackSpace
        53: 0xFF1B, // Escape
        76: 0xFF8D, // KP_Enter
        117: 0xFFFF, // Delete (forward)
        114: 0xFF63, // Help -> Insert
        115: 0xFF50, 119: 0xFF57, // Home, End
        116: 0xFF55, 121: 0xFF56, // Page_Up, Page_Down
        123: 0xFF51, 124: 0xFF53, 125: 0xFF54, 126: 0xFF52, // Left, Right, Down, Up
        122: 0xFFBE, 120: 0xFFBF, 99: 0xFFC0, 118: 0xFFC1, 96: 0xFFC2, 97: 0xFFC3, // F1-F6
        98: 0xFFC4, 100: 0xFFC5, 101: 0xFFC6, 109: 0xFFC7, 103: 0xFFC8, 111: 0xFFC9, // F7-F12
        105: 0xFFCA, 107: 0xFFCB, 113: 0xFFCC, 106: 0xFFCD, 64: 0xFFCE, 79: 0xFFCF, 80: 0xFFD0, // F13-F19
        56: shiftL, 60: shiftR, 59: controlL, 62: controlR, 57: capsLock,
        58: altL, 61: altR, 55: superL, 54: superR,
        82: 0xFFB0, 83: 0xFFB1, 84: 0xFFB2, 85: 0xFFB3, 86: 0xFFB4, // KP_0-KP_4
        87: 0xFFB5, 88: 0xFFB6, 89: 0xFFB7, 91: 0xFFB8, 92: 0xFFB9, // KP_5-KP_9
        65: 0xFFAE, 67: 0xFFAA, 69: 0xFFAB, 75: 0xFFAF, 78: 0xFFAD, 81: 0xFFBD, // KP . * + / - =
        71: 0xFF7F, // Clear -> Num_Lock
    ]

    /// Shift level of special keys, where it differs.
    static let specialShifted: [UInt16: UInt32] = [
        48: 0xFE20, // ISO_Left_Tab
    ]

    private static let koi8Lower = Array("юабцдефгхийклмнопярстужвьызшэщчъ".unicodeScalars)
    private static let koi8Upper = Array("ЮАБЦДЕФГХИЙКЛМНОПЯРСТУЖВЬЫЗШЭЩЧЪ".unicodeScalars)
    private static let cyrillicExtra: [UInt32: UInt32] = [
        0x0451: 0x6A3, 0x0401: 0x6B3, // ё Ё
        0x0454: 0x6A4, 0x0404: 0x6B4, // є Є
        0x0456: 0x6A6, 0x0406: 0x6B6, // і І
        0x0457: 0x6A7, 0x0407: 0x6B7, // ї Ї
        0x0491: 0x6AD, 0x0490: 0x6BD, // ґ Ґ
        0x045E: 0x6AE, 0x040E: 0x6BE, // ў Ў
        0x2116: 0x6B0, // №
    ]
    private static let cyrillic: [UInt32: UInt32] = {
        var table = cyrillicExtra
        for (index, scalar) in koi8Lower.enumerated() { table[scalar.value] = 0x6C0 + UInt32(index) }
        for (index, scalar) in koi8Upper.enumerated() { table[scalar.value] = 0x6E0 + UInt32(index) }
        return table
    }()

    /// Keysym for a character. Latin-1 maps to itself, Cyrillic to the
    /// classic keysyms every toolkit knows, the rest to Unicode keysyms.
    static func from(_ scalar: Unicode.Scalar) -> UInt32 {
        let v = scalar.value
        switch v {
        case 0x20...0x7E, 0xA0...0xFF: return v
        case 0x08: return 0xFF08
        case 0x09: return 0xFF09
        case 0x0D, 0x0A: return 0xFF0D
        case 0x1B: return 0xFF1B
        case 0x7F: return 0xFFFF
        case 0..<0x20: return noSymbol
        default:
            if let legacy = cyrillic[v] { return legacy }
            // Private-use characters are how AppKit encodes function keys; they are mapped by key code.
            if (0xE000...0xF8FF).contains(v) { return noSymbol }
            return 0x0100_0000 | v
        }
    }
}
