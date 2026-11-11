@testable import AXX11
import Foundation
import Testing

@Suite struct X11WireTests {
    @Test func requestGetsLengthAndPadding() {
        // InternAtom("ABC"): 8 header bytes + 3 name bytes, padded to 12.
        let r = XRequest(16, 0)
        r.u16(3).u16(0).raw(Array("ABC".utf8))
        #expect(r.finish() == [16, 0, 3, 0, 3, 0, 0, 0, 0x41, 0x42, 0x43, 0])
    }

    @Test func oversizedRequestUsesBigRequestsEncoding() {
        let r = XRequest(18, 0)
        r.raw([UInt8](repeating: 7, count: 300_000))
        let bytes = r.finish()
        #expect(bytes.u16(2) == 0)
        #expect(Int(bytes.u32(4)) * 4 == bytes.count)
        #expect(bytes.count == 300_008)
    }

    @Test func readsOutOfRangeAsZero() {
        let bytes: [UInt8] = [1, 2, 3]
        #expect(bytes.u16(0) == 0x0201)
        #expect(bytes.u32(0) == 0)
        #expect(bytes.u8(9) == 0)
        #expect(bytes.slice(1, 10) == [2, 3])
    }

    @Test func decodesConfigureNotify() {
        var w = ByteWriter()
        w.u8(22); w.u8(0); w.u16(7)
        w.u32(0x100); w.u32(0x400004); w.u32(0x400001)
        w.i16(-5); w.i16(40); w.u16(640); w.u16(480); w.u16(1); w.u8(1); w.u8(0); w.zeros(4)
        guard case .configureNotify(let window, let above, let g, let overrideRedirect) = XEvent.decode(w.bytes, bases: XEventBases()) else {
            Issue.record("wrong event")
            return
        }
        #expect(window == 0x400004)
        #expect(above == 0x400001)
        #expect(g == XGeometry(x: -5, y: 40, width: 640, height: 480, border: 1))
        #expect(overrideRedirect)
    }

    @Test func decodesExtensionAndSyntheticEvents() {
        var bases = XEventBases()
        bases.damage = 91
        var w = ByteWriter()
        w.u8(91); w.u8(1); w.u16(0); w.u32(0x400004); w.u32(0x200010); w.u32(1234)
        w.i16(10); w.i16(20); w.u16(30); w.u16(40); w.zeros(8)
        guard case .damageNotify(let drawable, _, let area) = XEvent.decode(w.bytes, bases: bases) else {
            Issue.record("wrong event")
            return
        }
        #expect(drawable == 0x400004)
        #expect(area == XRect(x: 10, y: 20, width: 30, height: 40))

        // Events relayed with SendEvent have the top bit set.
        var unmap = [UInt8](repeating: 0, count: 32)
        unmap[0] = 18 | 0x80
        unmap[8] = 0x2A
        guard case .unmapNotify(let window, let synthetic) = XEvent.decode(unmap, bases: bases) else {
            Issue.record("wrong event")
            return
        }
        #expect(window == 0x2A)
        #expect(synthetic)
    }

    @Test func rectUnionAndIntersection() {
        let a = XRect(x: 0, y: 0, width: 10, height: 10), b = XRect(x: 5, y: 8, width: 10, height: 10)
        #expect(a.union(b) == XRect(x: 0, y: 0, width: 15, height: 18))
        #expect(a.intersection(b) == XRect(x: 5, y: 8, width: 5, height: 2))
        #expect(a.intersection(XRect(x: 20, y: 20, width: 5, height: 5)).isEmpty)
    }

    @Test func authorityFilesCarryTheCookie() throws {
        let authority = try #require(X11Authority(hex: "000102030405060708090a0b0c0d0e0f"))
        #expect(authority.cookie == Array(0...15))
        #expect(authority.hex == "000102030405060708090a0b0c0d0e0f")
        #expect(X11Authority(hex: "xyz") == nil)

        // family, two empty fields, protocol name, 16 cookie bytes.
        let file = [UInt8](authority.xauthorityFile)
        #expect(Array(file.prefix(6)) == [0xFF, 0xFF, 0, 0, 0, 0])
        #expect(String(decoding: file[8..<26], as: UTF8.self) == "MIT-MAGIC-COOKIE-1")
        #expect(Array(file.suffix(18)) == [0, 16] + Array(0...15))

        // ssh parses the first line as "<name> <protocol> <hex>".
        let line = try #require(authority.xauthShim(display: 41).split(separator: "\n").last { $0.hasPrefix("echo ") })
        let fields = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: "\"")).split(separator: " ")
        #expect(fields.map(String.init) == ["abobaxterm/unix:41", "MIT-MAGIC-COOKIE-1", authority.hex])
    }
}
