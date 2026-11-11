import AppKit
import Carbon.HIToolbox

/// Keysyms of one macOS keyboard layout, per virtual key code.
struct X11KeyboardLayout: Equatable, Sendable {
    static let keyCount = 128

    /// Unshifted and shifted keysym for each of the 128 virtual key codes.
    var plain: [UInt32]
    var shifted: [UInt32]

    /// True when the letter keys produce something other than basic Latin.
    var isNonLatin: Bool {
        // kVK_ANSI_A, S, D, F: the home row is enough to tell.
        [0, 1, 2, 3].contains { plain[$0] > 0xFF }
    }

    /// Reads a layout through UCKeyTranslate; nil if the input source has no key layout (e.g. an IME).
    static func read(_ source: TISInputSource) -> X11KeyboardLayout? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> X11KeyboardLayout? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            let keyboardType = UInt32(LMGetKbdType())
            func translate(_ key: UInt16, shift: Bool) -> UInt32 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let modifiers = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
                let status = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown), modifiers, keyboardType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, chars.count, &length, &chars)
                guard status == noErr, length > 0,
                      let scalar = String(utf16CodeUnits: chars, count: length).unicodeScalars.first else { return X11Keysym.noSymbol }
                return X11Keysym.from(scalar)
            }
            var plain = [UInt32](repeating: 0, count: keyCount), shifted = plain
            for key in 0..<UInt16(keyCount) {
                if let special = X11Keysym.special[key] {
                    plain[Int(key)] = special
                    shifted[Int(key)] = X11Keysym.specialShifted[key] ?? special
                } else {
                    plain[Int(key)] = translate(key, shift: false)
                    shifted[Int(key)] = translate(key, shift: true)
                }
            }
            return X11KeyboardLayout(plain: plain, shifted: shifted)
        }
    }

    /// Core-protocol keymap rows: [group 1 plain, group 1 shifted, group 2 plain, group 2 shifted].
    /// Group 2 is only filled where the secondary layout differs.
    static func keymap(primary: X11KeyboardLayout, secondary: X11KeyboardLayout?) -> [UInt32] {
        var rows: [UInt32] = []
        rows.reserveCapacity(keyCount * 4)
        for key in 0..<keyCount {
            rows.append(primary.plain[key])
            rows.append(primary.shifted[key])
            if let secondary, secondary.plain[key] != primary.plain[key] || secondary.shifted[key] != primary.shifted[key] {
                rows.append(secondary.plain[key])
                rows.append(secondary.shifted[key])
            } else {
                rows.append(X11Keysym.noSymbol)
                rows.append(X11Keysym.noSymbol)
            }
        }
        return rows
    }
}

/// Keeps the X keymap in step with the Mac keyboard layout and turns key
/// events into fake X key presses.
///
/// X keycode = Mac virtual key code + 8. The keymap has two groups: the
/// Latin layout and, if the user types in a non-Latin one (e.g. Russian),
/// that layout as group 2. Switching the input source on the Mac locks the
/// matching group, so shortcuts keep working in both.
@MainActor
final class X11Keyboard {
    private let connection: XConnection
    private let ext: XExtensions
    private var pressed: Set<UInt8> = []
    private var uploaded: [UInt32] = []
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    static let keycodeOffset: UInt8 = 8

    init(connection: XConnection, ext: XExtensions) {
        self.connection = connection
        self.ext = ext
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    /// Uploads the keymap and starts following input-source changes.
    func install() async {
        // Drop the server's default PC keymap above the Mac key range (multimedia keys, stray modifiers).
        let first = Self.keycodeOffset &+ UInt8(X11KeyboardLayout.keyCount)
        connection.changeKeyboardMapping(first: first, perKeycode: 1, keysyms: [UInt32](repeating: 0, count: 256 - Int(first)))
        uploadLayout()

        // Rows: Shift, Lock, Control, Mod1 (Alt), Mod2, Mod3, Mod4 (Super), Mod5.
        func code(_ key: UInt8) -> UInt8 { key + Self.keycodeOffset }
        let modifiers: [UInt8] = [
            code(56), code(60), code(57), 0, code(59), code(62), code(58), code(61),
            0, 0, 0, 0, code(55), code(54), 0, 0,
        ]
        _ = try? await connection.setModifierMapping(perModifier: 2, keycodes: modifiers)

        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.uploadLayout() }
        }
    }

    /// Re-reads the Mac layouts; uploads the keymap if it changed and selects the active group.
    private func uploadLayout() {
        guard let latinSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let primary = X11KeyboardLayout.read(latinSource) else { return }
        var secondary: X11KeyboardLayout?
        if let currentSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let current = X11KeyboardLayout.read(currentSource), current != primary, current.isNonLatin {
            secondary = current
        }
        // Keep the last non-Latin layout loaded while the user is on the Latin one:
        // switching back and forth then needs no keymap upload (which clients notice).
        var keymap = X11KeyboardLayout.keymap(primary: primary, secondary: secondary)
        if secondary == nil, uploaded.count == keymap.count, stride(from: 0, to: keymap.count, by: 4).allSatisfy({
            uploaded[$0] == keymap[$0] && uploaded[$0 + 1] == keymap[$0 + 1]
        }) {
            keymap = uploaded
        }
        if keymap != uploaded {
            connection.changeKeyboardMapping(first: Self.keycodeOffset, perKeycode: 4, keysyms: keymap)
            uploaded = keymap
        }
        connection.xkbLockGroup(ext, secondary == nil ? 0 : 1)
    }

    // MARK: Events

    func key(_ event: NSEvent, pressed down: Bool) {
        guard event.keyCode < UInt16(X11KeyboardLayout.keyCount) else { return }
        let code = UInt8(event.keyCode) + Self.keycodeOffset
        if down {
            // The server auto-repeats held keys itself.
            guard !event.isARepeat else { return }
            press(code)
            // AppKit never delivers key-up while Command is held.
            if event.modifierFlags.contains(.command) { release(code) }
        } else {
            release(code)
        }
    }

    /// Device-specific flag bits tell the left and right modifier keys apart.
    private static let modifierMasks: [UInt16: UInt] = [
        56: 0x02, 60: 0x04, // shift
        59: 0x01, 62: 0x2000, // control
        58: 0x20, 61: 0x40, // option
        55: 0x08, 54: 0x10, // command
    ]

    func modifiersChanged(_ event: NSEvent) {
        let code = UInt8(truncatingIfNeeded: event.keyCode) &+ Self.keycodeOffset
        if event.keyCode == 57 {
            // Caps Lock reports each toggle as one event; X toggles on each press.
            connection.fakeInput(ext, .keyPress, detail: code)
            connection.fakeInput(ext, .keyRelease, detail: code)
        } else if let mask = Self.modifierMasks[event.keyCode] {
            if event.modifierFlags.rawValue & mask != 0 { press(code) } else { release(code) }
        }
    }

    /// Brings modifier state back in line after the window was not key for a while.
    func syncModifiers(_ flags: NSEvent.ModifierFlags) {
        let groups: [(NSEvent.ModifierFlags, [UInt8])] = [
            (.shift, [56, 60]), (.control, [59, 62]), (.option, [58, 61]), (.command, [55, 54]),
        ]
        for (flag, keys) in groups {
            let codes = keys.map { $0 + Self.keycodeOffset }
            if flags.contains(flag) {
                if !codes.contains(where: pressed.contains) { press(codes[0]) }
            } else {
                codes.forEach(release)
            }
        }
    }

    /// Releases every key still held on the X side (focus is going away).
    func releaseAll() {
        for code in pressed { connection.fakeInput(ext, .keyRelease, detail: code) }
        pressed.removeAll()
    }

    private func press(_ code: UInt8) {
        guard pressed.insert(code).inserted else { return }
        connection.fakeInput(ext, .keyPress, detail: code)
    }

    private func release(_ code: UInt8) {
        guard pressed.remove(code) != nil else { return }
        connection.fakeInput(ext, .keyRelease, detail: code)
    }

    // MARK: Scripted input (tests and the development harness)

    /// Taps a key by Mac virtual key code, optionally with Shift held.
    func tap(keyCode: UInt8, shift: Bool = false) {
        let shiftCode = 56 + Self.keycodeOffset
        if shift { connection.fakeInput(ext, .keyPress, detail: shiftCode) }
        connection.fakeInput(ext, .keyPress, detail: keyCode + Self.keycodeOffset)
        connection.fakeInput(ext, .keyRelease, detail: keyCode + Self.keycodeOffset)
        if shift { connection.fakeInput(ext, .keyRelease, detail: shiftCode) }
    }

    /// Presses or releases a key by Mac virtual key code, bypassing the pressed-key bookkeeping.
    func set(keyCode: UInt8, down: Bool) {
        connection.fakeInput(ext, down ? .keyPress : .keyRelease, detail: keyCode + Self.keycodeOffset)
    }

    /// Types text that the current layout can produce (used by tests).
    func type(_ text: String) {
        for scalar in text.unicodeScalars {
            let keysym = X11Keysym.from(scalar)
            guard keysym != 0 else { continue }
            for key in 0..<X11KeyboardLayout.keyCount {
                let base = key * 4
                guard base + 3 < uploaded.count else { break }
                if uploaded[base] == keysym { tap(keyCode: UInt8(key)); break }
                if uploaded[base + 1] == keysym { tap(keyCode: UInt8(key), shift: true); break }
            }
        }
    }
}
