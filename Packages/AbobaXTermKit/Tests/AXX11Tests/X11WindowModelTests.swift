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

        let single = X11KeyboardLayout.keymap(primary: latin, secondary: nil)
        #expect(single.count == 128 * 4)
        #expect(Array(single[0..<4]) == [0x61, 0x41, 0, 0])

        let dual = X11KeyboardLayout.keymap(primary: latin, secondary: russian)
        #expect(Array(dual[0..<4]) == [0x61, 0x41, 0x6C6, 0x6E6])
        #expect(Array(dual[36 * 4..<36 * 4 + 4]) == [0xFF0D, 0xFF0D, 0, 0])
    }
}
