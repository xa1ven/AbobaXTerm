import Foundation

/// Little-endian writer for X11 requests (the client picks the byte order).
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 32) { bytes.reserveCapacity(capacity) }

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func bool(_ v: Bool) { bytes.append(v ? 1 : 0) }
    mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v >> 16))
        bytes.append(UInt8(truncatingIfNeeded: v >> 24))
    }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func raw<S: Sequence>(_ s: S) where S.Element == UInt8 { bytes.append(contentsOf: s) }
    mutating func zeros(_ count: Int) { bytes.append(contentsOf: repeatElement(0, count: count)) }
    /// Pads to a multiple of four bytes.
    mutating func pad() { while bytes.count % 4 != 0 { bytes.append(0) } }

    mutating func setU16(_ v: UInt16, at index: Int) {
        bytes[index] = UInt8(truncatingIfNeeded: v)
        bytes[index + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }
}

/// Bounds-checked little-endian accessors; out-of-range reads return 0 so a
/// short or malformed packet cannot crash the app.
extension Array where Element == UInt8 {
    func u8(_ at: Int) -> UInt8 { at >= 0 && at < count ? self[at] : 0 }
    func u16(_ at: Int) -> UInt16 {
        guard at >= 0, at + 2 <= count else { return 0 }
        return UInt16(self[at]) | UInt16(self[at + 1]) << 8
    }
    func i16(_ at: Int) -> Int16 { Int16(bitPattern: u16(at)) }
    func u32(_ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= count else { return 0 }
        return UInt32(self[at]) | UInt32(self[at + 1]) << 8 | UInt32(self[at + 2]) << 16 | UInt32(self[at + 3]) << 24
    }
    func i32(_ at: Int) -> Int32 { Int32(bitPattern: u32(at)) }
    func slice(_ at: Int, _ length: Int) -> [UInt8] {
        guard at >= 0, length > 0, at < count else { return [] }
        return Array(self[at..<Swift.min(count, at + length)])
    }
}

/// One X11 request under construction. The length field is filled in by `finish()`.
/// A class so that field writes can be chained.
final class XRequest {
    private var w: ByteWriter

    /// `data` is the second header byte: request-specific for core requests,
    /// the minor opcode for extensions.
    init(_ opcode: UInt8, _ data: UInt8 = 0) {
        w = ByteWriter()
        w.u8(opcode); w.u8(data); w.u16(0)
    }

    @discardableResult func u8(_ v: UInt8) -> XRequest { w.u8(v); return self }
    @discardableResult func bool(_ v: Bool) -> XRequest { w.bool(v); return self }
    @discardableResult func u16(_ v: UInt16) -> XRequest { w.u16(v); return self }
    @discardableResult func i16(_ v: Int16) -> XRequest { w.i16(v); return self }
    @discardableResult func u32(_ v: UInt32) -> XRequest { w.u32(v); return self }
    @discardableResult func i32(_ v: Int32) -> XRequest { w.i32(v); return self }
    @discardableResult func raw<S: Sequence>(_ s: S) -> XRequest where S.Element == UInt8 { w.raw(s); return self }
    @discardableResult func zeros(_ n: Int) -> XRequest { w.zeros(n); return self }
    @discardableResult func pad() -> XRequest { w.pad(); return self }

    /// Final bytes. Requests longer than 262140 bytes use the BIG-REQUESTS
    /// encoding (the connection enables that extension at startup).
    func finish() -> [UInt8] {
        var out = w
        out.pad()
        let units = out.bytes.count / 4
        if units <= 0xFFFF {
            out.setU16(UInt16(units), at: 2)
            return out.bytes
        }
        var big = ByteWriter(capacity: out.bytes.count + 4)
        big.raw(out.bytes[0..<2]); big.u16(0); big.u32(UInt32(units + 1)); big.raw(out.bytes[4...])
        return big.bytes
    }
}
