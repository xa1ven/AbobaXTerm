import Foundation

/// X event-mask bits used by the window manager.
enum XEventMask {
    static let structureNotify: UInt32 = 1 << 17
    static let substructureNotify: UInt32 = 1 << 19
    static let substructureRedirect: UInt32 = 1 << 20
    static let focusChange: UInt32 = 1 << 21
    static let propertyChange: UInt32 = 1 << 22
}

/// ConfigureWindow value-mask bits.
struct XConfigureMask: OptionSet, Sendable {
    let rawValue: UInt16
    static let x = XConfigureMask(rawValue: 1)
    static let y = XConfigureMask(rawValue: 2)
    static let width = XConfigureMask(rawValue: 4)
    static let height = XConfigureMask(rawValue: 8)
    static let border = XConfigureMask(rawValue: 16)
    static let sibling = XConfigureMask(rawValue: 32)
    static let stackMode = XConfigureMask(rawValue: 64)
}

/// A property value as returned by GetProperty.
struct XProperty: Sendable {
    var type: UInt32
    var format: UInt8
    var data: [UInt8]

    var longs: [UInt32] { format == 32 ? stride(from: 0, to: data.count - 3, by: 4).map { data.u32($0) } : [] }
    var isEmpty: Bool { data.isEmpty }
}

/// Core protocol requests (only the ones the app needs).
extension XConnection {
    // MARK: Windows

    /// Creates an invisible 1x1 helper window (selection owner, WM check window).
    func createHelperWindow(parent: UInt32, eventMask: UInt32 = 0) -> UInt32 {
        let id = newID()
        let r = XRequest(1, 0)
        r.u32(id).u32(parent).i16(-10).i16(-10).u16(1).u16(1).u16(0)
        r.u16(2) // InputOnly
        r.u32(0) // visual: CopyFromParent
        r.u32(0x200 | 0x800).u32(1).u32(eventMask) // override-redirect, event mask
        send(r)
        return id
    }

    func selectInput(_ window: UInt32, _ mask: UInt32) {
        let r = XRequest(2)
        r.u32(window).u32(0x800).u32(mask)
        send(r)
    }

    func setWindowCursor(_ window: UInt32, cursor: UInt32) {
        let r = XRequest(2)
        r.u32(window).u32(0x4000).u32(cursor)
        send(r)
    }

    func mapWindow(_ window: UInt32) {
        let r = XRequest(8)
        r.u32(window)
        send(r)
    }

    func unmapWindow(_ window: UInt32) {
        let r = XRequest(10)
        r.u32(window)
        send(r)
    }

    func destroyWindow(_ window: UInt32) {
        let r = XRequest(4)
        r.u32(window)
        send(r)
    }

    /// Values are taken from `geometry` / `sibling` / `stackMode` as selected by `mask`.
    func configureWindow(_ window: UInt32, mask: XConfigureMask, geometry: XGeometry = XGeometry(),
                         sibling: UInt32 = 0, stackMode: UInt8 = 0) {
        guard !mask.isEmpty else { return }
        let r = XRequest(12)
        r.u32(window).u16(mask.rawValue).u16(0)
        if mask.contains(.x) { r.i32(Int32(clamping: geometry.x)) }
        if mask.contains(.y) { r.i32(Int32(clamping: geometry.y)) }
        if mask.contains(.width) { r.u32(UInt32(max(1, geometry.width))) }
        if mask.contains(.height) { r.u32(UInt32(max(1, geometry.height))) }
        if mask.contains(.border) { r.u32(UInt32(max(0, geometry.border))) }
        if mask.contains(.sibling) { r.u32(sibling) }
        if mask.contains(.stackMode) { r.u32(UInt32(stackMode)) }
        send(r)
    }

    /// Raises `window` to the top of the stack, or just above `sibling`.
    func raiseWindow(_ window: UInt32, above sibling: UInt32? = nil) {
        if let sibling {
            configureWindow(window, mask: [.sibling, .stackMode], sibling: sibling, stackMode: 0)
        } else {
            configureWindow(window, mask: .stackMode, stackMode: 0)
        }
    }

    struct WindowAttributes: Sendable {
        var visual: UInt32
        var isInputOnly: Bool
        var isViewable: Bool
        var overrideRedirect: Bool
    }

    func windowAttributes(_ window: UInt32) async throws -> WindowAttributes {
        let r = XRequest(3)
        r.u32(window)
        let b = try await reply(r)
        return WindowAttributes(visual: b.u32(8), isInputOnly: b.u16(12) == 2, isViewable: b.u8(26) == 2, overrideRedirect: b.u8(27) != 0)
    }

    func geometry(_ drawable: UInt32) async throws -> (depth: UInt8, geometry: XGeometry) {
        let r = XRequest(14)
        r.u32(drawable)
        let b = try await reply(r)
        let g = XGeometry(x: Int(b.i16(12)), y: Int(b.i16(14)), width: Int(b.u16(16)), height: Int(b.u16(18)), border: Int(b.u16(20)))
        return (b.u8(1), g)
    }

    /// Children of `window`, bottom-most first.
    func queryTree(_ window: UInt32) async throws -> [UInt32] {
        let r = XRequest(15)
        r.u32(window)
        let b = try await reply(r)
        return (0..<Int(b.u16(16))).map { b.u32(32 + $0 * 4) }
    }

    func killClient(_ resource: UInt32) {
        let r = XRequest(113)
        r.u32(resource)
        send(r)
    }

    // MARK: Atoms and properties

    func internAtom(_ name: String) async throws -> UInt32 {
        let bytes = Array(name.utf8)
        let r = XRequest(16, 0)
        r.u16(UInt16(bytes.count)).u16(0).raw(bytes)
        return try await reply(r).u32(8)
    }

    func atomName(_ atom: UInt32) async throws -> String {
        let r = XRequest(17)
        r.u32(atom)
        let b = try await reply(r)
        return String(decoding: b.slice(32, Int(b.u16(8))), as: UTF8.self)
    }

    /// Reads a whole property (up to `maxBytes`); nil when it is not set.
    func property(_ window: UInt32, _ property: UInt32, delete: Bool = false, maxBytes: Int = 1 << 20) async throws -> XProperty? {
        let r = XRequest(20, delete ? 1 : 0)
        r.u32(window).u32(property).u32(0).u32(0).u32(UInt32(maxBytes / 4))
        let b = try await reply(r)
        let format = b.u8(1)
        guard format != 0 else { return nil }
        let count = Int(b.u32(16)) * Int(format) / 8
        return XProperty(type: b.u32(8), format: format, data: b.slice(32, count))
    }

    /// Replaces a property. `format` is 8 or 32 (`data` then holds little-endian 32-bit items).
    func changeProperty(_ window: UInt32, _ property: UInt32, type: UInt32, format: UInt8, data: [UInt8], append: Bool = false) {
        let r = XRequest(18, append ? 2 : 0)
        r.u32(window).u32(property).u32(type).u8(format).zeros(3)
        r.u32(UInt32(data.count / Int(format / 8))).raw(data)
        send(r)
    }

    func changeProperty(_ window: UInt32, _ property: UInt32, type: UInt32, longs: [UInt32]) {
        var w = ByteWriter(capacity: longs.count * 4)
        for v in longs { w.u32(v) }
        changeProperty(window, property, type: type, format: 32, data: w.bytes)
    }

    func deleteProperty(_ window: UInt32, _ property: UInt32) {
        let r = XRequest(19)
        r.u32(window).u32(property)
        send(r)
    }

    // MARK: Events, focus, selections

    /// Sends a ClientMessage with 32-bit data to `destination`.
    func sendClientMessage(to destination: UInt32, window: UInt32, type: UInt32, data: [UInt32], eventMask: UInt32 = 0) {
        let r = XRequest(25, 0)
        r.u32(destination).u32(eventMask)
        r.u8(33).u8(32).u16(0).u32(window).u32(type)
        for i in 0..<5 { r.u32(i < data.count ? data[i] : 0) }
        send(r)
    }

    /// Sends a raw 32-byte event (used for SelectionNotify).
    func sendEvent(to destination: UInt32, eventMask: UInt32 = 0, event: [UInt8]) {
        let r = XRequest(25, 0)
        r.u32(destination).u32(eventMask).raw(event.prefix(32)).zeros(max(0, 32 - event.count))
        send(r)
    }

    /// `revertTo`: 0 None, 1 PointerRoot, 2 Parent.
    func setInputFocus(_ window: UInt32, revertTo: UInt8 = 1, time: UInt32 = 0) {
        let r = XRequest(42, revertTo)
        r.u32(window).u32(time)
        send(r)
    }

    func setSelectionOwner(_ selection: UInt32, owner: UInt32, time: UInt32 = 0) {
        let r = XRequest(22)
        r.u32(owner).u32(selection).u32(time)
        send(r)
    }

    func selectionOwner(_ selection: UInt32) async throws -> UInt32 {
        let r = XRequest(23)
        r.u32(selection)
        return try await reply(r).u32(8)
    }

    func convertSelection(_ selection: UInt32, target: UInt32, property: UInt32, requestor: UInt32, time: UInt32 = 0) {
        let r = XRequest(24)
        r.u32(requestor).u32(selection).u32(target).u32(property).u32(time)
        send(r)
    }

    // MARK: Pixels

    func freePixmap(_ pixmap: UInt32) {
        let r = XRequest(54)
        r.u32(pixmap)
        send(r)
    }

    /// ZPixmap contents of a rectangle; 4 bytes per pixel (BGRX / BGRA) for depth 24 and 32.
    func image(_ drawable: UInt32, _ rect: XRect) async throws -> [UInt8] {
        let r = XRequest(73, 2)
        r.u32(drawable).i16(Int16(clamping: rect.x)).i16(Int16(clamping: rect.y))
        r.u16(UInt16(clamping: rect.width)).u16(UInt16(clamping: rect.height)).u32(0xFFFF_FFFF)
        let b = try await reply(r)
        return Array(b.dropFirst(32))
    }

    // MARK: Keyboard and cursor

    /// Replaces the keysyms of `count` keycodes starting at `first`;
    /// `keysyms` holds `perKeycode` entries per keycode.
    func changeKeyboardMapping(first: UInt8, perKeycode: UInt8, keysyms: [UInt32]) {
        let count = keysyms.count / Int(perKeycode)
        let r = XRequest(100, UInt8(count))
        r.u8(first).u8(perKeycode).u16(0)
        for k in keysyms.prefix(count * Int(perKeycode)) { r.u32(k) }
        send(r)
    }

    /// `keycodes` holds 8 rows (Shift, Lock, Control, Mod1...Mod5) of `perModifier` entries.
    func setModifierMapping(perModifier: UInt8, keycodes: [UInt8]) async throws -> Bool {
        let r = XRequest(118, perModifier)
        r.raw(keycodes)
        return try await reply(r).u8(1) == 0
    }

    /// A cursor made from a glyph of the standard "cursor" font (e.g. 68 = left_ptr).
    func createFontCursor(glyph: UInt16) -> UInt32 {
        let font = newID()
        let name = Array("cursor".utf8)
        let open = XRequest(45)
        open.u32(font).u16(UInt16(name.count)).u16(0).raw(name)
        send(open)
        let cursor = newID()
        let create = XRequest(94)
        create.u32(cursor).u32(font).u32(font).u16(glyph).u16(glyph + 1)
        create.u16(0).u16(0).u16(0).u16(0xFFFF).u16(0xFFFF).u16(0xFFFF)
        send(create)
        let close = XRequest(46)
        close.u32(font)
        send(close)
        return cursor
    }

    // MARK: Extensions

    struct ExtensionInfo: Sendable {
        var opcode: UInt8
        var firstEvent: UInt8
        var firstError: UInt8
    }

    func queryExtension(_ name: String) async throws -> ExtensionInfo? {
        let bytes = Array(name.utf8)
        let r = XRequest(98)
        r.u16(UInt16(bytes.count)).u16(0).raw(bytes)
        let b = try await reply(r)
        guard b.u8(8) != 0 else { return nil }
        return ExtensionInfo(opcode: b.u8(9), firstEvent: b.u8(10), firstError: b.u8(11))
    }

    /// A cheap round trip: everything sent before it has been processed when it returns.
    func sync() async throws {
        _ = try await reply(XRequest(43)) // GetInputFocus
    }
}
