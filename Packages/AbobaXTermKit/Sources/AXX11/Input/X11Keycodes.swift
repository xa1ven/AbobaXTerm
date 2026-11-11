import Foundation

/// X keycodes for Mac keys.
///
/// The server keeps the Linux convention "keycode = evdev scancode + 8", so
/// programs that forward raw keys (VM consoles in virt-manager, remote
/// desktop clients) translate them correctly. Keysyms come from the Mac
/// layout separately (see `X11KeyboardLayout`).
enum X11Keycode {
    static let offset: UInt8 = 8
    static let first: UInt8 = 8
    /// Number of keycodes in the server's keymap (8...255).
    static let count = 248

    /// Linux input event codes (KEY_*) by Mac virtual key code.
    static let evdev: [UInt16: UInt8] = [
        // Letters
        0: 30, 11: 48, 8: 46, 2: 32, 14: 18, 3: 33, 5: 34, 4: 35, 34: 23, 38: 36, 40: 37, 37: 38, 46: 50,
        45: 49, 31: 24, 35: 25, 12: 16, 15: 19, 1: 31, 17: 20, 32: 22, 9: 47, 13: 17, 7: 45, 16: 21, 6: 44,
        // Digits and punctuation
        18: 2, 19: 3, 20: 4, 21: 5, 23: 6, 22: 7, 26: 8, 28: 9, 25: 10, 29: 11,
        27: 12, 24: 13, 33: 26, 30: 27, 42: 43, 41: 39, 39: 40, 50: 41, 43: 51, 47: 52, 44: 53, 10: 86,
        // Editing and navigation
        36: 28, 48: 15, 49: 57, 51: 14, 53: 1, 117: 111, 114: 110,
        115: 102, 119: 107, 116: 104, 121: 109, 123: 105, 124: 106, 125: 108, 126: 103,
        // Modifiers
        56: 42, 60: 54, 59: 29, 62: 97, 58: 56, 61: 100, 55: 125, 54: 126, 57: 58,
        // Function keys
        122: 59, 120: 60, 99: 61, 118: 62, 96: 63, 97: 64, 98: 65, 100: 66, 101: 67, 109: 68, 103: 87, 111: 88,
        105: 183, 107: 184, 113: 185, 106: 186, 64: 187, 79: 188, 80: 189, 90: 190,
        // Keypad
        82: 82, 83: 79, 84: 80, 85: 81, 86: 75, 87: 76, 88: 77, 89: 71, 91: 72, 92: 73,
        65: 83, 67: 55, 69: 78, 75: 98, 78: 74, 76: 96, 81: 117, 71: 69,
    ]

    /// X keycode for a Mac virtual key code, or nil for keys X has no place for (e.g. Fn).
    static func forMacKey(_ key: UInt16) -> UInt8? {
        evdev[key].map { $0 + offset }
    }

    // Keycodes of the modifier keys, for the modifier map.
    static let shiftL: UInt8 = 50, shiftR: UInt8 = 62
    static let controlL: UInt8 = 37, controlR: UInt8 = 105
    static let altL: UInt8 = 64, altR: UInt8 = 108
    static let superL: UInt8 = 133, superR: UInt8 = 134
    static let capsLock: UInt8 = 66
}
