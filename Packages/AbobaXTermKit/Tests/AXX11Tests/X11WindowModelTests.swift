@testable import AXX11
import CoreGraphics
import Foundation
import Testing

@Suite struct X11WindowModelTests {
    let atoms = XAtomTable.synthetic()

    private func longs(_ values: [UInt32], type: UInt32 = 0) -> XProperty {
        var w = ByteWriter()
        for v in values { w.u32(v) }
        return XProperty(type: type, format: 32, data: w.bytes)
    }

    @Test func sizeHintsFollowTheirFlags() {
        // flags: PPosition | PMinSize | PMaxSize | PResizeInc | PBaseSize
        var raw = [UInt32](repeating: 0, count: 18)
        raw[0] = 4 | 16 | 32 | 64 | 256
        raw[5] = 100; raw[6] = 50
        raw[7] = 800; raw[8] = 600
        raw[9] = 7; raw[10] = 13
        raw[15] = 4; raw[16] = 4
        let hints = X11SizeHints(longs: raw)
        #expect(hints.programPosition && !hints.userPosition && hints.hasPosition)
        #expect(hints.minSize?.width == 100 && hints.minSize?.height == 50)
        #expect(hints.maxSize?.width == 800 && hints.maxSize?.height == 600)
        #expect(hints.increment?.width == 7 && hints.increment?.height == 13)
        #expect(hints.baseSize?.width == 4)
        #expect(!hints.isFixedSize)

        raw[0] = 16 | 32
        raw[7] = 100; raw[8] = 50
        #expect(X11SizeHints(longs: raw).isFixedSize)
        // Fields without their flag are ignored, as are truncated properties.
        #expect(X11SizeHints(longs: [0, 1, 2, 3, 4, 100, 50]).minSize == nil)
        #expect(X11SizeHints(longs: [16, 0, 0]).minSize == nil)
    }

    @Test func titlePrefersUTF8Name() {
        var p = X11WindowProperties()
        #expect(p.title == "X11")
        p.apply(.wmClass, XProperty(type: 0, format: 8, data: Array("xterm\0XTerm\0".utf8)), atoms: atoms)
        #expect(p.instanceName == "xterm" && p.className == "XTerm")
        #expect(p.title == "XTerm")
        p.apply(.wmName, XProperty(type: 0, format: 8, data: [0x63, 0x61, 0x66, 0xE9]), atoms: atoms) // Latin-1 "café"
        #expect(p.title == "café")
        p.apply(.netWMName, XProperty(type: 0, format: 8, data: Array("Менеджер ВМ".utf8)), atoms: atoms)
        #expect(p.title == "Менеджер ВМ")
        p.apply(.netWMName, nil, atoms: atoms)
        #expect(p.title == "café")
    }

    @Test func protocolsHintsAndTypes() {
        var p = X11WindowProperties()
        p.apply(.wmProtocols, longs([atoms[.wmTakeFocus], atoms[.wmDeleteWindow]]), atoms: atoms)
        #expect(p.supportsDelete && p.supportsTakeFocus)
        p.apply(.wmProtocols, nil, atoms: atoms)
        #expect(!p.supportsDelete)

        // WM_HINTS with the input flag and input = False: the client focuses itself.
        p.apply(.wmHints, longs([1, 0]), atoms: atoms)
        #expect(!p.acceptsInput)
        p.apply(.wmHints, longs([2, 0, 1]), atoms: atoms)
        #expect(p.acceptsInput)

        p.apply(.netWMWindowType, longs([atoms[.gtkFrameExtents], atoms[.netWMWindowTypeDialog], atoms[.netWMWindowTypeNormal]]), atoms: atoms)
        #expect(p.kind == .dialog)
        p.apply(.netWMWindowType, longs([atoms[.netWMWindowTypePopupMenu]]), atoms: atoms)
        #expect(p.kind == .menu)

        p.apply(.motifWMHints, longs([2, 0, 0, 0, 0]), atoms: atoms)
        #expect(!p.wantsDecorations)
        p.apply(.motifWMHints, longs([2, 0, 1, 0, 0]), atoms: atoms)
        #expect(p.wantsDecorations)

        p.apply(.wmTransientFor, longs([0x400004]), atoms: atoms)
        #expect(p.transientFor == 0x400004)
        let tracked = p.apply(.netWMDesktop, nil, atoms: atoms)
        #expect(!tracked)
    }

    @Test func desktopFlipsBetweenCocoaAndXCoordinates() {
        // Two screens: primary 1440x900 at the origin, a second one to the left and higher up.
        let desktop = X11Desktop(frame: CGRect(x: -1920, y: 0, width: 3360, height: 1080))
        #expect(desktop.pixelWidth == 3360 && desktop.pixelHeight == 1080)

        let g = XGeometry(x: 1920, y: 180, width: 400, height: 300)
        let rect = desktop.contentRect(for: g)
        // X y = 180 from the top of the union -> Cocoa top edge at 1080 - 180 = 900.
        #expect(rect == CGRect(x: 0, y: 600, width: 400, height: 300))
        #expect(desktop.geometry(forContentRect: rect) == g)

        let retina = X11Desktop(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
        #expect(retina.pixelWidth == 2880)
        #expect(retina.contentRect(for: XGeometry(x: 200, y: 100, width: 800, height: 600)) == CGRect(x: 100, y: 550, width: 400, height: 300))
    }

    @Test func rootMovesOverWindowsOnOtherScreens() {
        // Root as large as a laptop screen; a monitor to its right was connected later.
        let desktop = X11Desktop(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
        #expect(desktop.reaches(CGRect(x: 100, y: 100, width: 800, height: 600)))
        let far = CGRect(x: 2000, y: 300, width: 800, height: 600)
        #expect(!desktop.reaches(far))

        let moved = desktop.recentered(on: far)
        #expect(moved.frame.size == desktop.frame.size)
        #expect(moved.pixelWidth == desktop.pixelWidth)
        #expect(moved.reaches(far))
        #expect(moved.frame.midX == far.midX && moved.frame.midY == far.midY)
        let g = moved.geometry(forContentRect: far)
        #expect(g.x == 640 && g.y == 300 && g.width == 1600 && g.height == 1200)

        // A window larger than the root: its top-left corner is what gets covered.
        let huge = CGRect(x: 2000, y: -200, width: 2560, height: 1400)
        let over = desktop.recentered(on: huge)
        #expect(over.reaches(huge))
        #expect(over.geometry(forContentRect: huge).x == 0 && over.geometry(forContentRect: huge).y == 0)
    }

    @Test @MainActor func coreCursorsAreNotShrunkByTheScale() {
        // The 10x16 arrow of the core cursor font, as the server reports it.
        #expect(X11CursorMapper.pixelsPerPoint(name: "", width: 10, height: 16, scale: 2) == 1)
        // Theme cursors are drawn at Xcursor.size = 24 * scale; custom toolkit cursors too.
        #expect(X11CursorMapper.pixelsPerPoint(name: "wait", width: 48, height: 48, scale: 2) == 2)
        #expect(X11CursorMapper.pixelsPerPoint(name: "", width: 48, height: 48, scale: 2) == 2)
        #expect(X11CursorMapper.pixelsPerPoint(name: "", width: 10, height: 16, scale: 1) == 1)
    }

    @Test func keysymsForCommonCharacters() {
        #expect(X11Keysym.from("a") == 0x61)
        #expect(X11Keysym.from("é") == 0xE9)
        #expect(X11Keysym.from("ф") == 0x6C6) // Cyrillic_ef
        #expect(X11Keysym.from("Я") == 0x6F1) // Cyrillic_YA
        #expect(X11Keysym.from("ё") == 0x6A3)
        #expect(X11Keysym.from("€") == 0x0100_20AC)
        #expect(X11Keysym.from("\r") == 0xFF0D)
        #expect(X11Keysym.from("\u{F700}") == X11Keysym.noSymbol) // AppKit's "up arrow" function key
    }

    @Test func keymapAddsSecondGroupOnlyWhereLayoutsDiffer() {
        var latin = X11KeyboardLayout(plain: [UInt32](repeating: 0, count: 128), shifted: [UInt32](repeating: 0, count: 128))
        latin.plain[0] = 0x61; latin.shifted[0] = 0x41 // a A
        latin.plain[36] = 0xFF0D; latin.shifted[36] = 0xFF0D // Return
        var russian = latin
        russian.plain[0] = 0x6C6; russian.shifted[0] = 0x6E6 // ф Ф
        #expect(!latin.isNonLatin && russian.isNonLatin)

        // Rows are indexed by X keycode - 8: "A" is evdev 30 (keycode 38), Return evdev 28 (keycode 36).
        let single = X11KeyboardLayout.keymap(primary: latin, secondary: nil)
        #expect(single.count == 248 * 4)
        #expect(Array(single[30 * 4..<30 * 4 + 4]) == [0x61, 0x41, 0, 0])

        let dual = X11KeyboardLayout.keymap(primary: latin, secondary: russian)
        #expect(Array(dual[30 * 4..<30 * 4 + 4]) == [0x61, 0x41, 0x6C6, 0x6E6])
        #expect(Array(dual[28 * 4..<28 * 4 + 4]) == [0xFF0D, 0xFF0D, 0, 0])
    }

    @Test func keycodesFollowTheLinuxConvention() {
        // The same numbers `xev` shows on a Linux desktop.
        #expect(X11Keycode.forMacKey(0) == 38) // A
        #expect(X11Keycode.forMacKey(36) == 36) // Return
        #expect(X11Keycode.forMacKey(49) == 65) // space
        #expect(X11Keycode.forMacKey(53) == 9) // Escape
        #expect(X11Keycode.forMacKey(123) == 113) // Left
        #expect(X11Keycode.forMacKey(56) == X11Keycode.shiftL)
        #expect(X11Keycode.forMacKey(55) == X11Keycode.superL)
        #expect(X11Keycode.forMacKey(63) == nil) // Fn
        // No two Mac keys share a keycode.
        #expect(Set(X11Keycode.evdev.values).count == X11Keycode.evdev.count)
    }

    @Test func settingsEncodeForXSETTINGS() {
        let settings = X11Settings(values: ["Gdk/WindowScalingFactor": .int(2), "Xft/RGBA": .string("none")])
        let bytes = settings.encoded(serial: 7)
        #expect(bytes.u8(0) == 0 && bytes.u32(4) == 7 && bytes.u32(8) == 2)
        // First entry (sorted by name): integer, 23-byte name padded to 24, serial, value.
        #expect(bytes.u8(12) == 0 && bytes.u16(14) == 23)
        #expect(String(decoding: bytes.slice(16, 23), as: UTF8.self) == "Gdk/WindowScalingFactor")
        #expect(bytes.u32(40) == 7 && bytes.i32(44) == 2)
        // Second entry: string with a length prefix.
        #expect(bytes.u8(48) == 1 && bytes.u16(50) == 8)
        #expect(bytes.u32(64) == 4 && String(decoding: bytes.slice(68, 4), as: UTF8.self) == "none")
        #expect(bytes.count == 72)
        #expect(X11Settings.resources(scale: 2).contains("Xft.dpi:\t192\n"))
    }

    @Test func commandShortcutsFollowTheProgram() {
        let c: UInt32 = 0x63, v: UInt32 = 0x76, z: UInt32 = 0x7A, k: UInt32 = 0x6B
        // Regular programs: Control+key.
        let gtk = X11ShortcutStyle(instanceName: "virt-manager", className: "Virt-manager")
        #expect(gtk == .standard)
        #expect(X11Shortcut.action(forKeysym: c, style: gtk) == .control(shift: false))
        #expect(X11Shortcut.action(forKeysym: z, style: gtk) == .control(shift: false))
        #expect(X11Shortcut.action(forKeysym: k, style: gtk) == nil)
        // Cyrillic or special keysyms are never shortcuts.
        #expect(X11Shortcut.action(forKeysym: 0x6D3, style: gtk) == nil)
        #expect(X11Shortcut.action(forKeysym: 0xFF0D, style: gtk) == nil)

        // Classic terminals: PRIMARY and Shift+Insert, never Control+C.
        let xterm = X11ShortcutStyle(instanceName: "xterm", className: "XTerm")
        #expect(xterm == .selectionTerminal)
        #expect(X11Shortcut.action(forKeysym: c, style: xterm) == .copySelection)
        #expect(X11Shortcut.action(forKeysym: v, style: xterm) == .pasteSelection)
        #expect(X11Shortcut.action(forKeysym: z, style: xterm) == .ignore)
        #expect(X11ShortcutStyle(instanceName: "urxvt", className: "URxvt") == .selectionTerminal)

        // Modern terminals: Control+Shift+C / V.
        let gnome = X11ShortcutStyle(instanceName: "gnome-terminal-server", className: "Gnome-terminal")
        #expect(gnome == .terminal)
        #expect(X11Shortcut.action(forKeysym: c, style: gnome) == .control(shift: true))
        #expect(X11Shortcut.action(forKeysym: z, style: gnome) == .ignore)
        #expect(X11ShortcutStyle(instanceName: nil, className: nil) == .standard)
    }

    @Test func editMenuFollowsTheProgram() {
        // Every item works in a regular program.
        for command in X11EditCommand.allCases {
            #expect(X11Shortcut.action(for: command, style: .standard) == .control(shift: false))
        }
        // Terminals: only Copy and Paste; the rest would send a control character to the shell.
        #expect(X11Shortcut.action(for: .copy, style: .terminal) == .control(shift: true))
        #expect(X11Shortcut.action(for: .paste, style: .selectionTerminal) == .pasteSelection)
        #expect(X11Shortcut.action(for: .copy, style: .selectionTerminal) == .copySelection)
        for command in [X11EditCommand.undo, .cut, .selectAll] {
            #expect(X11Shortcut.action(for: command, style: .terminal) == nil)
            #expect(X11Shortcut.action(for: command, style: .selectionTerminal) == nil)
        }
    }

    @Test func iconIsTheLargestCompleteImage() {
        func image(_ side: UInt32, _ pixel: UInt32) -> [UInt32] { [side, side] + [UInt32](repeating: pixel, count: Int(side * side)) }
        // 16, 48 and 32 pixels, in the order programs happen to list them.
        let icon = X11Icon.best(in: image(16, 1) + image(48, 2) + image(32, 3))
        #expect(icon?.width == 48 && icon?.height == 48 && icon?.pixels.first == 2)
        // A last image cut off by the read limit is skipped, not half-used.
        let cut = Array((image(16, 1) + image(64, 2)).dropLast(10))
        #expect(X11Icon.best(in: cut)?.width == 16)
        // Nonsense sizes do not crash or allocate.
        #expect(X11Icon.best(in: [0xFFFF_FFFF, 0xFFFF_FFFF, 1]) == nil)
        #expect(X11Icon.best(in: [0, 0]) == nil && X11Icon.best(in: []) == nil)

        // Half-transparent red comes out premultiplied, in BGRA byte order.
        let red = X11Icon(width: 1, height: 1, pixels: [0x80FF_0000]).makeImage()
        let bytes = red?.dataProvider?.data.map { [UInt8]($0 as Data) }
        #expect(bytes == [0, 0, 0x80, 0x80])
    }
}
