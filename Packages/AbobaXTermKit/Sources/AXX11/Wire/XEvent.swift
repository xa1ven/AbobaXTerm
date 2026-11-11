import Foundation

/// Window geometry in X pixels, relative to the root window.
struct XGeometry: Equatable, Sendable {
    var x: Int = 0
    var y: Int = 0
    var width: Int = 1
    var height: Int = 1
    var border: Int = 0
}

struct XRect: Equatable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var isEmpty: Bool { width <= 0 || height <= 0 }
    var maxX: Int { x + width }
    var maxY: Int { y + height }

    func union(_ other: XRect) -> XRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let x0 = Swift.min(x, other.x), y0 = Swift.min(y, other.y)
        return XRect(x: x0, y: y0, width: Swift.max(maxX, other.maxX) - x0, height: Swift.max(maxY, other.maxY) - y0)
    }

    func intersection(_ other: XRect) -> XRect {
        let x0 = Swift.max(x, other.x), y0 = Swift.max(y, other.y)
        return XRect(x: x0, y: y0, width: Swift.min(maxX, other.maxX) - x0, height: Swift.min(maxY, other.maxY) - y0)
    }
}

/// First event codes of the extensions the window manager listens to.
struct XEventBases: Sendable {
    var damage: UInt8 = 0
    var xfixes: UInt8 = 0
    var shape: UInt8 = 0
}

/// The events the window manager cares about, decoded from the wire.
enum XEvent: Sendable {
    case createNotify(window: UInt32, parent: UInt32, geometry: XGeometry, overrideRedirect: Bool)
    case destroyNotify(window: UInt32)
    case unmapNotify(window: UInt32, synthetic: Bool)
    case mapNotify(window: UInt32, overrideRedirect: Bool)
    case mapRequest(window: UInt32, parent: UInt32)
    case reparentNotify(window: UInt32, parent: UInt32)
    case configureNotify(window: UInt32, aboveSibling: UInt32, geometry: XGeometry, overrideRedirect: Bool)
    case configureRequest(window: UInt32, sibling: UInt32, stackMode: UInt8, geometry: XGeometry, mask: UInt16)
    case propertyNotify(window: UInt32, atom: UInt32, time: UInt32, deleted: Bool)
    case selectionClear(time: UInt32, owner: UInt32, selection: UInt32)
    case selectionRequest(time: UInt32, owner: UInt32, requestor: UInt32, selection: UInt32, target: UInt32, property: UInt32)
    case selectionNotify(time: UInt32, requestor: UInt32, selection: UInt32, target: UInt32, property: UInt32)
    case clientMessage(window: UInt32, type: UInt32, format: UInt8, data: [UInt32])
    case focusIn(window: UInt32, mode: UInt8, detail: UInt8)
    case focusOut(window: UInt32, mode: UInt8, detail: UInt8)
    case mappingNotify
    case damageNotify(drawable: UInt32, damage: UInt32, area: XRect)
    case xfixesSelectionNotify(owner: UInt32, selection: UInt32, time: UInt32)
    case xfixesCursorNotify(serial: UInt32, name: UInt32)
    case shapeNotify(window: UInt32, kind: UInt8, shaped: Bool)
    case other(code: UInt8)

    static func decode(_ b: [UInt8], bases: XEventBases) -> XEvent {
        let code = b.u8(0) & 0x7F
        switch code {
        case 9: return .focusIn(window: b.u32(4), mode: b.u8(8), detail: b.u8(1))
        case 10: return .focusOut(window: b.u32(4), mode: b.u8(8), detail: b.u8(1))
        case 16:
            let g = XGeometry(x: Int(b.i16(12)), y: Int(b.i16(14)), width: Int(b.u16(16)), height: Int(b.u16(18)), border: Int(b.u16(20)))
            return .createNotify(window: b.u32(8), parent: b.u32(4), geometry: g, overrideRedirect: b.u8(22) != 0)
        case 17: return .destroyNotify(window: b.u32(8))
        case 18: return .unmapNotify(window: b.u32(8), synthetic: b.u8(0) & 0x80 != 0)
        case 19: return .mapNotify(window: b.u32(8), overrideRedirect: b.u8(12) != 0)
        case 20: return .mapRequest(window: b.u32(8), parent: b.u32(4))
        case 21: return .reparentNotify(window: b.u32(8), parent: b.u32(12))
        case 22:
            let g = XGeometry(x: Int(b.i16(16)), y: Int(b.i16(18)), width: Int(b.u16(20)), height: Int(b.u16(22)), border: Int(b.u16(24)))
            return .configureNotify(window: b.u32(8), aboveSibling: b.u32(12), geometry: g, overrideRedirect: b.u8(26) != 0)
        case 23:
            let g = XGeometry(x: Int(b.i16(16)), y: Int(b.i16(18)), width: Int(b.u16(20)), height: Int(b.u16(22)), border: Int(b.u16(24)))
            return .configureRequest(window: b.u32(8), sibling: b.u32(12), stackMode: b.u8(1), geometry: g, mask: b.u16(26))
        case 28: return .propertyNotify(window: b.u32(4), atom: b.u32(8), time: b.u32(12), deleted: b.u8(16) == 1)
        case 29: return .selectionClear(time: b.u32(4), owner: b.u32(8), selection: b.u32(12))
        case 30:
            return .selectionRequest(time: b.u32(4), owner: b.u32(8), requestor: b.u32(12),
                                     selection: b.u32(16), target: b.u32(20), property: b.u32(24))
        case 31:
            return .selectionNotify(time: b.u32(4), requestor: b.u32(8), selection: b.u32(12), target: b.u32(16), property: b.u32(20))
        case 33:
            // Only the 32-bit view of the payload is needed by ICCCM/EWMH messages.
            return .clientMessage(window: b.u32(4), type: b.u32(8), format: b.u8(1), data: (0..<5).map { b.u32(12 + $0 * 4) })
        case 34: return .mappingNotify
        default: break
        }
        if bases.damage != 0, code == bases.damage {
            let area = XRect(x: Int(b.i16(16)), y: Int(b.i16(18)), width: Int(b.u16(20)), height: Int(b.u16(22)))
            return .damageNotify(drawable: b.u32(4), damage: b.u32(8), area: area)
        }
        if bases.xfixes != 0, code == bases.xfixes {
            return .xfixesSelectionNotify(owner: b.u32(8), selection: b.u32(12), time: b.u32(16))
        }
        if bases.xfixes != 0, code == bases.xfixes + 1 {
            return .xfixesCursorNotify(serial: b.u32(8), name: b.u32(16))
        }
        if bases.shape != 0, code == bases.shape {
            return .shapeNotify(window: b.u32(4), kind: b.u8(1), shaped: b.u8(20) != 0)
        }
        return .other(code: code)
    }
}
