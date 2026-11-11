@testable import AXSFTP
import Foundation
import Testing

@Suite struct SFTPWireTests {
    @Test func writerReaderRoundTrip() throws {
        var w = SFTPWriter()
        w.u8(7)
        w.u32(0xDEAD_BEEF)
        w.u64(0x0102_0304_0506_0708)
        w.string("héllo")
        var r = SFTPReader(w.data)
        #expect(try r.u8() == 7)
        #expect(try r.u32() == 0xDEAD_BEEF)
        #expect(try r.u64() == 0x0102_0304_0506_0708)
        #expect(try r.string() == "héllo")
        #expect(r.remaining == 0)
    }

    @Test func truncatedInputThrows() {
        var r = SFTPReader(Data([0, 0, 0, 9, 1, 2]))
        #expect(throws: SFTPError.self) { try r.string() }
    }

    @Test func readerWorksOnSlicedData() throws {
        // Data slices keep their parent's indices; the reader must cope.
        var w = SFTPWriter()
        w.u32(1)
        w.u32(42)
        let slice = w.data.subdata(in: 4..<8)[...]
        var r = SFTPReader(Data(slice))
        #expect(try r.u32() == 42)
    }

    @Test func attributesRoundTrip() throws {
        let attrs = SFTPAttributes(size: 1234, uid: 0, gid: 20, permissions: 0o100644,
                                   accessTime: 1, modificationTime: 1_700_000_000)
        var w = SFTPWriter()
        attrs.encode(into: &w)
        var r = SFTPReader(w.data)
        let decoded = try SFTPAttributes.decode(from: &r)
        #expect(decoded == attrs)
        #expect(decoded.isRegularFile)
        #expect(!decoded.isDirectory)
        #expect(decoded.permissionString == "rw-r--r--")
    }

    @Test func extendedAttributesAreSkipped() throws {
        var w = SFTPWriter()
        w.u32(SFTPAttributes.flagPermissions | SFTPAttributes.flagExtended)
        w.u32(0o040755)
        w.u32(1)
        w.string("key")
        w.string("value")
        w.u32(99) // trailing data after the attributes
        var r = SFTPReader(w.data)
        let attrs = try SFTPAttributes.decode(from: &r)
        #expect(attrs.isDirectory)
        #expect(try r.u32() == 99)
    }

    @Test func pathHelpers() {
        #expect(SFTPClient.join("/", "etc") == "/etc")
        #expect(SFTPClient.join("/etc", "hosts") == "/etc/hosts")
        #expect(SFTPClient.parent(of: "/etc/hosts") == "/etc")
        #expect(SFTPClient.parent(of: "/etc") == "/")
        #expect(SFTPClient.parent(of: "/") == "/")
        #expect(SFTPClient.parent(of: "/var/log/") == "/var")
        #expect(SFTPClient.name(of: "/var/log/syslog") == "syslog")
    }

    @Test func errorDescriptions() {
        let e = SFTPError(status: .permissionDenied, message: "", path: "/root")
        #expect(e.errorDescription == "Permission denied: /root")
    }
}
