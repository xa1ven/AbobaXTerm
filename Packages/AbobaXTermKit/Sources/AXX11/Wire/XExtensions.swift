import Foundation

/// Opcodes of the extensions the embedded server must provide.
struct XExtensions: Sendable {
    var composite: UInt8 = 0
    var damage: UInt8 = 0
    var xfixes: UInt8 = 0
    var xtest: UInt8 = 0
    var xkb: UInt8 = 0
    var shape: UInt8 = 0
    var events = XEventBases()

    enum MissingExtension: Error, LocalizedError {
        case missing(String)
        var errorDescription: String? {
            if case .missing(let name) = self { return "The X server lacks the \(name) extension" }
            return nil
        }
    }

    /// Looks the extensions up and negotiates versions (the server rejects
    /// Composite/Damage/XFixes requests from clients that skipped that).
    static func negotiate(_ c: XConnection) async throws -> XExtensions {
        func need(_ name: String) async throws -> XConnection.ExtensionInfo {
            guard let info = try await c.queryExtension(name) else { throw MissingExtension.missing(name) }
            return info
        }
        var ext = XExtensions()
        let composite = try await need("Composite")
        let damage = try await need("DAMAGE")
        let xfixes = try await need("XFIXES")
        let xtest = try await need("XTEST")
        ext.composite = composite.opcode
        ext.damage = damage.opcode
        ext.xfixes = xfixes.opcode
        ext.xtest = xtest.opcode
        ext.events.damage = damage.firstEvent
        ext.events.xfixes = xfixes.firstEvent
        if let shape = try await c.queryExtension("SHAPE") {
            ext.shape = shape.opcode
            ext.events.shape = shape.firstEvent
        }
        if let xkb = try await c.queryExtension("XKEYBOARD") { ext.xkb = xkb.opcode }
        if let big = try await c.queryExtension("BIG-REQUESTS") {
            _ = try await c.reply(XRequest(big.opcode, 0))
        }

        var v = XRequest(ext.composite, 0)
        v.u32(0).u32(4)
        _ = try await c.reply(v)
        v = XRequest(ext.damage, 0)
        v.u32(1).u32(1)
        _ = try await c.reply(v)
        v = XRequest(ext.xfixes, 0)
        v.u32(5).u32(0)
        _ = try await c.reply(v)
        if ext.xkb != 0 {
            v = XRequest(ext.xkb, 0)
            v.u16(1).u16(0)
            _ = try? await c.reply(v)
        }
        return ext
    }
}

extension XConnection {
    // MARK: Composite

    /// Gives every child of `window` its own off-screen pixmap (manual update:
    /// the server never paints them to the screen, the app does).
    func compositeRedirectSubwindows(_ ext: XExtensions, _ window: UInt32) {
        let r = XRequest(ext.composite, 2)
        r.u32(window).u8(1).zeros(3)
        send(r)
    }

    /// A new pixmap id referring to the window's current off-screen contents.
    func compositeNameWindowPixmap(_ ext: XExtensions, _ window: UInt32) -> UInt32 {
        let pixmap = newID()
        let r = XRequest(ext.composite, 6)
        r.u32(window).u32(pixmap)
        send(r)
        return pixmap
    }

    // MARK: Damage

    /// Reports changed rectangles of `drawable` (delta level: only areas not already reported).
    func damageCreate(_ ext: XExtensions, _ drawable: UInt32) -> UInt32 {
        let damage = newID()
        let r = XRequest(ext.damage, 1)
        r.u32(damage).u32(drawable).u8(1).zeros(3)
        send(r)
        return damage
    }

    func damageDestroy(_ ext: XExtensions, _ damage: UInt32) {
        let r = XRequest(ext.damage, 2)
        r.u32(damage)
        send(r)
    }

    /// Marks everything reported so far as repaired.
    func damageSubtractAll(_ ext: XExtensions, _ damage: UInt32) {
        let r = XRequest(ext.damage, 3)
        r.u32(damage).u32(0).u32(0)
        send(r)
    }

    // MARK: XFixes

    func xfixesSelectCursorInput(_ ext: XExtensions, _ window: UInt32) {
        let r = XRequest(ext.xfixes, 3)
        r.u32(window).u32(1)
        send(r)
    }

    /// Notifies about owner changes of `selection` (mask 1 = SetSelectionOwner).
    func xfixesSelectSelectionInput(_ ext: XExtensions, _ window: UInt32, selection: UInt32) {
        let r = XRequest(ext.xfixes, 2)
        r.u32(window).u32(selection).u32(1 | 2 | 4)
        send(r)
    }

    struct CursorImage: Sendable {
        var width: Int
        var height: Int
        var hotX: Int
        var hotY: Int
        var serial: UInt32
        var name: String
        /// Premultiplied ARGB, one little-endian 32-bit word per pixel.
        var pixels: [UInt8]
    }

    func xfixesCursorImage(_ ext: XExtensions) async throws -> CursorImage {
        let b = try await reply(XRequest(ext.xfixes, 25)) // GetCursorImageAndName
        let width = Int(b.u16(12)), height = Int(b.u16(14))
        let nameLength = Int(b.u16(28))
        let pixelBytes = width * height * 4
        return CursorImage(width: width, height: height, hotX: Int(b.u16(16)), hotY: Int(b.u16(18)), serial: b.u32(20),
                           name: String(decoding: b.slice(32 + pixelBytes, nameLength), as: UTF8.self),
                           pixels: b.slice(32, pixelBytes))
    }

    // MARK: XTEST

    enum FakeInput: UInt8 {
        case keyPress = 2, keyRelease = 3, buttonPress = 4, buttonRelease = 5, motion = 6
    }

    /// Injects an input event as if it came from a real device.
    /// For `.motion`, `x`/`y` are absolute root coordinates.
    func fakeInput(_ ext: XExtensions, _ type: FakeInput, detail: UInt8 = 0, x: Int = 0, y: Int = 0) {
        let r = XRequest(ext.xtest, 2)
        r.u8(type.rawValue).u8(detail).u16(0)
        r.u32(0) // delay
        r.u32(0) // root: None = the screen the pointer is on
        r.zeros(8)
        r.i16(Int16(clamping: x)).i16(Int16(clamping: y))
        r.zeros(8)
        send(r)
    }

    // MARK: XKB

    /// Locks the keyboard group (layout index) on the core keyboard.
    func xkbLockGroup(_ ext: XExtensions, _ group: UInt8) {
        guard ext.xkb != 0 else { return }
        let r = XRequest(ext.xkb, 5)
        r.u16(0x100) // XkbUseCoreKbd
        r.u8(0).u8(0) // affectModLocks, modLocks
        r.bool(true).u8(group) // lockGroup, groupLock
        r.u8(0).u8(0) // affectModLatches, modLatches
        r.u8(0).bool(false).u16(0) // pad, latchGroup, groupLatch
        send(r)
    }
}
