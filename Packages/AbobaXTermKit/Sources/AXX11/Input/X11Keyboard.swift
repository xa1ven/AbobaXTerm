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

    /// Core-protocol keymap for keycodes 8...255, four keysyms per keycode:
    /// [group 1 plain, group 1 shifted, group 2 plain, group 2 shifted].
    /// Group 2 is only filled where the secondary layout differs.
    static func keymap(primary: X11KeyboardLayout, secondary: X11KeyboardLayout?) -> [UInt32] {
        var rows = [UInt32](repeating: X11Keysym.noSymbol, count: X11Keycode.count * 4)
        for key in 0..<keyCount {
            guard let code = X11Keycode.forMacKey(UInt16(key)) else { continue }
            let row = Int(code - X11Keycode.first) * 4
            rows[row] = primary.plain[key]
            rows[row + 1] = primary.shifted[key]
            if let secondary, secondary.plain[key] != primary.plain[key] || secondary.shifted[key] != primary.shifted[key] {
                rows[row + 2] = secondary.plain[key]
                rows[row + 3] = secondary.shifted[key]
            }
        }
        return rows
    }
}

/// Keeps the X keymap in step with the Mac keyboard layout and turns key
/// events into fake X key presses.
///
/// Keycodes follow the Linux convention (see `X11Keycode`). The keymap has
/// two groups: the Latin layout and, if the user types in a non-Latin one
/// (e.g. Russian), that layout as group 2. Switching the input source on the
/// Mac locks the matching group, so shortcuts keep working in both.
///
/// Modifiers: Control is Control, Option is Alt, Command is Super. With
/// `translatesCommandShortcuts`, Command+C/V/X/A/Z are delivered as the
/// program's own copy/paste keys instead (see `X11Shortcut`). For that the
/// Super press is held back until it is known what Command is used for, so
/// the program never sees a stray Super tap around a translated shortcut.
@MainActor
final class X11Keyboard {
    private let connection: XConnection
    private let ext: XExtensions
    private var pressed: Set<UInt8> = []
    private var uploaded: [UInt32] = []
    /// Command shortcuts act as copy, paste and so on; off: Command is always Super.
    var translatesCommandShortcuts = true { didSet { if !translatesCommandShortcuts { commitModifiers() } } }
    /// A Command key that is down on the Mac but not yet pressed as Super on the X side.
    private var pendingSuper: UInt8?
    /// Command was used for something since it went down: releasing it is not a Super tap.
    private var commandUsed = false
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(connection: XConnection, ext: XExtensions) {
        self.connection = connection
        self.ext = ext
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    /// Uploads the keymap and starts following input-source changes.
    func install() async {
        uploadLayout()

        // Rows: Shift, Lock, Control, Mod1 (Alt), Mod2, Mod3, Mod4 (Super), Mod5.
        let modifiers: [UInt8] = [
            X11Keycode.shiftL, X11Keycode.shiftR, X11Keycode.capsLock, 0,
            X11Keycode.controlL, X11Keycode.controlR, X11Keycode.altL, X11Keycode.altR,
            0, 0, 0, 0, X11Keycode.superL, X11Keycode.superR, 0, 0,
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
            connection.changeKeyboardMapping(first: X11Keycode.first, perKeycode: 4, keysyms: keymap)
            uploaded = keymap
        }
        connection.xkbLockGroup(ext, secondary == nil ? 0 : 1)
    }

    // MARK: Events

    func key(_ event: NSEvent, pressed down: Bool) {
        guard let code = X11Keycode.forMacKey(event.keyCode) else { return }
        if down {
            // The server auto-repeats held keys itself.
            guard !event.isARepeat else { return }
            commitModifiers()
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
        guard let code = X11Keycode.forMacKey(event.keyCode) else { return }
        if event.keyCode == 57 {
            // Caps Lock reports each toggle as one event; X toggles on each press.
            connection.fakeInput(ext, .keyPress, detail: code)
            connection.fakeInput(ext, .keyRelease, detail: code)
        } else if let mask = Self.modifierMasks[event.keyCode] {
            let down = event.modifierFlags.rawValue & mask != 0
            if code == X11Keycode.superL || code == X11Keycode.superR {
                command(code, down: down)
            } else if down {
                press(code)
            } else {
                release(code)
            }
        }
    }

    private func command(_ code: UInt8, down: Bool) {
        if down {
            guard translatesCommandShortcuts else { return press(code) }
            guard !pressed.contains(code) else { return }
            if pendingSuper == nil { commandUsed = false }
            pendingSuper = code
        } else if pendingSuper == code {
            pendingSuper = nil
            // Command alone: a Super tap (opens the launcher in a VM's desktop).
            if !commandUsed {
                connection.fakeInput(ext, .keyPress, detail: code)
                connection.fakeInput(ext, .keyRelease, detail: code)
            }
        } else {
            release(code)
        }
    }

    /// Presses a held-back Super: Command is being used as a plain modifier (key or mouse button).
    func commitModifiers() {
        guard let code = pendingSuper else { return }
        pendingSuper = nil
        press(code)
    }

    /// Something else consumed a Command combination (a menu of the app).
    func commandKeyUsed() {
        commandUsed = true
    }

    // MARK: Command shortcuts

    /// Keysym the key types in the Latin layout, if Command shortcuts are being translated.
    func shortcutKeysym(forMacKey key: UInt16) -> UInt32? {
        guard translatesCommandShortcuts, let code = X11Keycode.forMacKey(key) else { return nil }
        let row = Int(code - X11Keycode.first) * 4
        return row < uploaded.count ? uploaded[row] : nil
    }

    /// Mac key that types `keysym` in the Latin layout (for menu commands, which carry no key).
    func macKey(typingLatin keysym: UInt32) -> UInt16? {
        X11Keycode.evdev.keys.sorted().first { key in
            guard let code = X11Keycode.forMacKey(key) else { return false }
            let row = Int(code - X11Keycode.first) * 4
            return row < uploaded.count && uploaded[row] == keysym
        }
    }

    /// Taps a key with Control and/or Shift held and Super out of the way.
    func sendChord(macKey: UInt16, control: Bool, shift: Bool) {
        guard let code = X11Keycode.forMacKey(macKey) else { return }
        commandUsed = true
        let supers = [X11Keycode.superL, X11Keycode.superR].filter(pressed.contains)
        supers.forEach(release)
        var added: [UInt8] = []
        if control, !pressed.contains(X11Keycode.controlL), !pressed.contains(X11Keycode.controlR) { added.append(X11Keycode.controlL) }
        if shift, !pressed.contains(X11Keycode.shiftL), !pressed.contains(X11Keycode.shiftR) { added.append(X11Keycode.shiftL) }
        for modifier in added { connection.fakeInput(ext, .keyPress, detail: modifier) }
        connection.fakeInput(ext, .keyPress, detail: code)
        connection.fakeInput(ext, .keyRelease, detail: code)
        for modifier in added.reversed() { connection.fakeInput(ext, .keyRelease, detail: modifier) }
        supers.forEach(press)
    }

    /// Brings modifier state back in line after the window was not key for a while.
    func syncModifiers(_ flags: NSEvent.ModifierFlags) {
        let groups: [(NSEvent.ModifierFlags, [UInt8])] = [
            (.shift, [X11Keycode.shiftL, X11Keycode.shiftR]), (.control, [X11Keycode.controlL, X11Keycode.controlR]),
            (.option, [X11Keycode.altL, X11Keycode.altR]), (.command, [X11Keycode.superL, X11Keycode.superR]),
        ]
        for (flag, codes) in groups {
            let isCommand = flag == .command
            if flags.contains(flag) {
                guard !codes.contains(where: pressed.contains) else { continue }
                if isCommand, translatesCommandShortcuts {
                    // Held since before the window became key: whatever it was for, it is not a tap.
                    if pendingSuper == nil { pendingSuper = codes[0]; commandUsed = true }
                } else {
                    press(codes[0])
                }
            } else {
                if isCommand { pendingSuper = nil }
                codes.forEach(release)
            }
        }
    }

    /// Releases every key still held on the X side (focus is going away).
    func releaseAll() {
        for code in pressed { connection.fakeInput(ext, .keyRelease, detail: code) }
        pressed.removeAll()
        pendingSuper = nil
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

    /// Presses or releases a key by Mac virtual key code, bypassing the pressed-key bookkeeping.
    func set(keyCode: UInt8, down: Bool) {
        guard let code = X11Keycode.forMacKey(UInt16(keyCode)) else { return }
        connection.fakeInput(ext, down ? .keyPress : .keyRelease, detail: code)
    }

    /// Taps a key by Mac virtual key code, optionally with Shift held.
    func tap(keyCode: UInt8, shift: Bool = false) {
        if shift { connection.fakeInput(ext, .keyPress, detail: X11Keycode.shiftL) }
        set(keyCode: keyCode, down: true)
        set(keyCode: keyCode, down: false)
        if shift { connection.fakeInput(ext, .keyRelease, detail: X11Keycode.shiftL) }
    }

    /// Types text that the Latin layout can produce (used by tests).
    func type(_ text: String) {
        for scalar in text.unicodeScalars {
            let keysym = X11Keysym.from(scalar)
            guard keysym != 0 else { continue }
            for key in 0..<UInt16(X11KeyboardLayout.keyCount) {
                guard let code = X11Keycode.forMacKey(key) else { continue }
                let row = Int(code - X11Keycode.first) * 4
                guard row + 1 < uploaded.count else { continue }
                if uploaded[row] == keysym { tap(keyCode: UInt8(key)); break }
                if uploaded[row + 1] == keysym { tap(keyCode: UInt8(key), shift: true); break }
            }
        }
    }
}
