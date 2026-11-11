import Foundation

/// SFTP protocol version 3 (draft-ietf-secsh-filexfer-02), as spoken by OpenSSH.
enum SFTPPacketType: UInt8 {
    case initialize = 1, version = 2, open = 3, close = 4, read = 5, write = 6
    case lstat = 7, fstat = 8, setstat = 9, fsetstat = 10, opendir = 11, readdir = 12
    case remove = 13, mkdir = 14, rmdir = 15, realpath = 16, stat = 17, rename = 18
    case readlink = 19, symlink = 20
    case status = 101, handle = 102, data = 103, name = 104, attrs = 105
    case extended = 200, extendedReply = 201
}

/// SSH_FXF_* open flags.
struct SFTPOpenFlags: OptionSet {
    let rawValue: UInt32
    static let read = SFTPOpenFlags(rawValue: 0x01)
    static let write = SFTPOpenFlags(rawValue: 0x02)
    static let append = SFTPOpenFlags(rawValue: 0x04)
    static let create = SFTPOpenFlags(rawValue: 0x08)
    static let truncate = SFTPOpenFlags(rawValue: 0x10)
    static let exclusive = SFTPOpenFlags(rawValue: 0x20)
}

/// SSH_FX_* status codes.
public enum SFTPStatus: UInt32, Sendable {
    case ok = 0, eof = 1, noSuchFile = 2, permissionDenied = 3, failure = 4
    case badMessage = 5, noConnection = 6, connectionLost = 7, unsupported = 8
}

public struct SFTPError: Error, LocalizedError, Equatable, Sendable {
    public var status: SFTPStatus?
    public var message: String
    public var path: String?

    public init(status: SFTPStatus?, message: String, path: String? = nil) {
        self.status = status
        self.message = message
        self.path = path
    }

    public var errorDescription: String? {
        var text: String
        switch status {
        case .noSuchFile: text = "No such file or directory"
        case .permissionDenied: text = "Permission denied"
        case .unsupported: text = "Operation not supported by the server"
        case .connectionLost, .noConnection: text = "Connection lost"
        default: text = message.isEmpty ? "SFTP error" : message
        }
        if let path { text += ": \(path)" }
        return text
    }

    static func protocolError(_ message: String) -> SFTPError {
        SFTPError(status: .badMessage, message: message)
    }
}

/// File attributes (SSH_FILEXFER_ATTR_*).
public struct SFTPAttributes: Sendable, Equatable {
    public var size: UInt64?
    public var uid: UInt32?
    public var gid: UInt32?
    public var permissions: UInt32?
    public var accessTime: UInt32?
    public var modificationTime: UInt32?

    public init(size: UInt64? = nil, uid: UInt32? = nil, gid: UInt32? = nil, permissions: UInt32? = nil,
                accessTime: UInt32? = nil, modificationTime: UInt32? = nil) {
        self.size = size
        self.uid = uid
        self.gid = gid
        self.permissions = permissions
        self.accessTime = accessTime
        self.modificationTime = modificationTime
    }

    static let flagSize: UInt32 = 0x1
    static let flagUIDGID: UInt32 = 0x2
    static let flagPermissions: UInt32 = 0x4
    static let flagTimes: UInt32 = 0x8
    static let flagExtended: UInt32 = 0x8000_0000

    private var fileType: UInt32? { permissions.map { $0 & 0o170000 } }
    public var isDirectory: Bool { fileType == 0o040000 }
    public var isSymlink: Bool { fileType == 0o120000 }
    public var isRegularFile: Bool { fileType == 0o100000 }

    public var modificationDate: Date? {
        modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// "rwxr-xr-x" style string (without the type character).
    public var permissionString: String {
        guard let p = permissions else { return "" }
        let chars: [(UInt32, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"),
            (0o010, "x"), (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        return String(chars.map { p & $0.0 != 0 ? $0.1 : "-" })
    }

    func encode(into w: inout SFTPWriter) {
        var flags: UInt32 = 0
        if size != nil { flags |= Self.flagSize }
        if uid != nil, gid != nil { flags |= Self.flagUIDGID }
        if permissions != nil { flags |= Self.flagPermissions }
        if accessTime != nil, modificationTime != nil { flags |= Self.flagTimes }
        w.u32(flags)
        if let size { w.u64(size) }
        if let uid, let gid { w.u32(uid); w.u32(gid) }
        if let permissions { w.u32(permissions) }
        if let accessTime, let modificationTime { w.u32(accessTime); w.u32(modificationTime) }
    }

    static func decode(from r: inout SFTPReader) throws -> SFTPAttributes {
        let flags = try r.u32()
        var a = SFTPAttributes()
        if flags & flagSize != 0 { a.size = try r.u64() }
        if flags & flagUIDGID != 0 { a.uid = try r.u32(); a.gid = try r.u32() }
        if flags & flagPermissions != 0 { a.permissions = try r.u32() }
        if flags & flagTimes != 0 { a.accessTime = try r.u32(); a.modificationTime = try r.u32() }
        if flags & flagExtended != 0 {
            let count = try r.u32()
            for _ in 0..<count { _ = try r.bytes(); _ = try r.bytes() }
        }
        return a
    }
}

/// Big-endian SSH wire encoding.
struct SFTPWriter {
    var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func bytes(_ v: some Collection<UInt8>) { u32(UInt32(v.count)); data.append(contentsOf: v) }
    mutating func string(_ v: String) { bytes(Array(v.utf8)) }
}

struct SFTPReader {
    let data: Data
    private(set) var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw SFTPError.protocolError("truncated packet") }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw SFTPError.protocolError("truncated packet") }
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(data[offset + i]) }
        offset += 4
        return v
    }

    mutating func u64() throws -> UInt64 {
        let hi = try u32()
        let lo = try u32()
        return UInt64(hi) << 32 | UInt64(lo)
    }

    mutating func bytes() throws -> Data {
        let n = Int(try u32())
        guard remaining >= n else { throw SFTPError.protocolError("truncated string") }
        defer { offset += n }
        return data.subdata(in: offset..<offset + n)
    }

    mutating func string() throws -> String {
        let raw = try bytes()
        // Non-UTF-8 file names are shown with replacement characters.
        return String(decoding: raw, as: UTF8.self)
    }
}
