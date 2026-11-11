import Foundation

/// A directory entry.
public struct SFTPFileInfo: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let attributes: SFTPAttributes
    /// For symlinks: whether the target is a directory (resolved with stat).
    public var linkTargetIsDirectory = false

    public init(name: String, path: String, attributes: SFTPAttributes, linkTargetIsDirectory: Bool = false) {
        self.name = name
        self.path = path
        self.attributes = attributes
        self.linkTargetIsDirectory = linkTargetIsDirectory
    }

    public var isDirectory: Bool { attributes.isDirectory || (attributes.isSymlink && linkTargetIsDirectory) }
    public var isSymlink: Bool { attributes.isSymlink }
    public var size: UInt64 { attributes.size ?? 0 }

    public static func == (a: SFTPFileInfo, b: SFTPFileInfo) -> Bool {
        a.path == b.path && a.attributes == b.attributes && a.linkTargetIsDirectory == b.linkTargetIsDirectory
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(path) }
}

/// Progress callback: bytes transferred so far for the current file.
public typealias SFTPProgress = @Sendable (_ bytes: UInt64) -> Void

/// High-level SFTP operations. Safe to use from many tasks at once.
public final class SFTPClient: Sendable {
    let connection: SFTPConnection

    /// Bytes per READ/WRITE request and how many may be in flight.
    let chunkSize: Int
    let window = 16

    /// Opens the `sftp` subsystem through `executable` (ssh) with `arguments`.
    public static func connect(executable: String, arguments: [String], environment: [String: String]? = nil) async throws -> SFTPClient {
        let connection = try await SFTPConnection.open(executable: executable, arguments: arguments, environment: environment)
        return SFTPClient(connection: connection)
    }

    init(connection: SFTPConnection) {
        self.connection = connection
        // OpenSSH accepts up to 256 KiB per request; stay well below.
        chunkSize = 64 * 1024
    }

    public func close() { connection.close() }
    public var isClosed: Bool { connection.isClosed }

    // MARK: Paths & metadata

    public func realPath(_ path: String) async throws -> String {
        let response = try await connection.request(.realpath) { $0.string(path) }
        let names = try Self.parseNames(response, path: path)
        guard let first = names.first else { throw SFTPError.protocolError("empty REALPATH reply") }
        return first.name
    }

    public func attributes(_ path: String, followLinks: Bool = true) async throws -> SFTPAttributes {
        let response = try await connection.request(followLinks ? .stat : .lstat) { $0.string(path) }
        return try Self.parseAttrs(response, path: path)
    }

    public func exists(_ path: String) async throws -> Bool {
        do {
            _ = try await attributes(path, followLinks: false)
            return true
        } catch let error as SFTPError where error.status == .noSuchFile {
            return false
        }
    }

    /// Lists a directory (without "." and ".."), directories first, then by name.
    public func list(_ path: String) async throws -> [SFTPFileInfo] {
        let handle = try await openDirectory(path)
        defer { Task { [connection] in _ = try? await Self.closeHandle(handle, connection) } }

        var entries: [SFTPFileInfo] = []
        while true {
            let response = try await connection.request(.readdir) { $0.bytes(handle) }
            if response.type == .status {
                let (code, message) = try Self.parseStatus(response.payload)
                if code == .eof { break }
                throw SFTPError(status: code, message: message, path: path)
            }
            for entry in try Self.parseNames(response, path: path) where entry.name != "." && entry.name != ".." {
                entries.append(SFTPFileInfo(name: entry.name, path: Self.join(path, entry.name), attributes: entry.attrs))
            }
        }

        // Resolve symlinks so links to directories can be browsed.
        for i in entries.indices where entries[i].isSymlink {
            if let target = try? await attributes(entries[i].path, followLinks: true) {
                entries[i].linkTargetIsDirectory = target.isDirectory
            }
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: Changes

    public func makeDirectory(_ path: String, permissions: UInt32 = 0o755) async throws {
        try await expectOK(connection.request(.mkdir) { w in
            w.string(path)
            SFTPAttributes(permissions: permissions).encode(into: &w)
        }, path: path)
    }

    public func removeFile(_ path: String) async throws {
        try await expectOK(connection.request(.remove) { $0.string(path) }, path: path)
    }

    public func removeDirectory(_ path: String) async throws {
        try await expectOK(connection.request(.rmdir) { $0.string(path) }, path: path)
    }

    /// Deletes a file, symlink or directory tree.
    public func removeRecursively(_ path: String) async throws {
        let attrs = try await attributes(path, followLinks: false)
        guard attrs.isDirectory else {
            try await removeFile(path)
            return
        }
        for entry in try await list(path) {
            try Task.checkCancellation()
            if entry.attributes.isDirectory {
                try await removeRecursively(entry.path)
            } else {
                try await removeFile(entry.path)
            }
        }
        try await removeDirectory(path)
    }

    /// Renames; uses posix-rename@openssh.com (atomic, overwrites) when available.
    public func rename(_ from: String, to: String) async throws {
        if connection.extensions["posix-rename@openssh.com"] != nil {
            try await expectOK(connection.request(.extended) { w in
                w.string("posix-rename@openssh.com")
                w.string(from)
                w.string(to)
            }, path: from)
        } else {
            try await expectOK(connection.request(.rename) { w in
                w.string(from)
                w.string(to)
            }, path: from)
        }
    }

    /// Creates an empty file (fails if it exists).
    public func createFile(_ path: String, permissions: UInt32 = 0o644) async throws {
        let handle = try await openFile(path, flags: [.write, .create, .exclusive], permissions: permissions)
        try await Self.closeHandle(handle, connection)
    }

    // MARK: Whole-file helpers (editor)

    /// Reads a whole file (refuses files over `limit` bytes).
    public func readFile(_ path: String, limit: UInt64 = 16 * 1024 * 1024) async throws -> (Data, SFTPAttributes) {
        let handle = try await openFile(path, flags: [.read])
        defer { Task { [connection] in _ = try? await Self.closeHandle(handle, connection) } }
        let attrs = try await fstat(handle, path: path)
        if let size = attrs.size, size > limit {
            throw SFTPError(status: .failure, message: "File is too large (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))", path: path)
        }
        var data = Data()
        try await readPipelined(handle: handle, size: attrs.size ?? 0, path: path) { _, chunk in
            data.append(chunk)
        } progress: { _ in }
        return (data, attrs)
    }

    /// Overwrites a file in place (keeps its owner and permissions).
    public func writeFile(_ path: String, data: Data) async throws {
        let handle = try await openFile(path, flags: [.write, .create, .truncate], permissions: 0o644)
        do {
            try await writePipelined(handle: handle, size: UInt64(data.count), path: path) { offset, length in
                data.subdata(in: Int(offset)..<Int(offset) + length)
            } progress: { _ in }
            try await Self.closeHandle(handle, connection)
        } catch {
            _ = try? await Self.closeHandle(handle, connection)
            throw error
        }
    }

    // MARK: Transfers

    /// Downloads a regular file to `localURL` (overwritten). Cancellable; the
    /// partial file is removed on failure.
    public func download(_ remotePath: String, to localURL: URL, progress: SFTPProgress) async throws {
        let handle = try await openFile(remotePath, flags: [.read])
        defer { Task { [connection] in _ = try? await Self.closeHandle(handle, connection) } }
        let attrs = try await fstat(handle, path: remotePath)

        let fm = FileManager.default
        try? fm.removeItem(at: localURL)
        guard fm.createFile(atPath: localURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: localURL.path])
        }
        let file = try FileHandle(forWritingTo: localURL)
        do {
            try await readPipelined(handle: handle, size: attrs.size ?? 0, path: remotePath) { offset, chunk in
                try file.seek(toOffset: offset)
                try file.write(contentsOf: chunk)
            } progress: { progress($0) }
            try file.close()
            if let mtime = attrs.modificationDate {
                try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: localURL.path)
            }
        } catch {
            try? file.close()
            try? fm.removeItem(at: localURL)
            throw error
        }
    }

    /// Uploads a local regular file to `remotePath` (overwritten).
    public func upload(_ localURL: URL, to remotePath: String, progress: SFTPProgress) async throws {
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey])
        let size = UInt64(values.fileSize ?? 0)
        let posix = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.posixPermissions] as? NSNumber)?.uint32Value
        let file = try FileHandle(forReadingFrom: localURL)
        defer { try? file.close() }

        let handle = try await openFile(remotePath, flags: [.write, .create, .truncate], permissions: (posix ?? 0o644) & 0o777)
        do {
            try await writePipelined(handle: handle, size: size, path: remotePath) { offset, length in
                try file.seek(toOffset: offset)
                return try file.read(upToCount: length) ?? Data()
            } progress: { progress($0) }
            try await Self.closeHandle(handle, connection)
        } catch {
            _ = try? await Self.closeHandle(handle, connection)
            throw error
        }
    }

    // MARK: Pipelining

    private func readPipelined(handle: Data, size: UInt64, path: String,
                               sink: (UInt64, Data) throws -> Void,
                               progress: (UInt64) -> Void) async throws {
        var nextOffset: UInt64 = 0
        var done: UInt64 = 0
        var inflight: [(offset: UInt64, length: Int, task: Task<Data?, Error>)] = []
        var reachedEOF = false
        defer { for item in inflight { item.task.cancel() } }

        func issue(_ offset: UInt64, _ length: Int) -> Task<Data?, Error> {
            Task { [connection] in
                let response = try await connection.request(.read) { w in
                    w.bytes(handle)
                    w.u64(offset)
                    w.u32(UInt32(length))
                }
                switch response.type {
                case .data:
                    var r = SFTPReader(response.payload)
                    return try r.bytes()
                case .status:
                    let (code, message) = try Self.parseStatus(response.payload)
                    if code == .eof { return nil }
                    throw SFTPError(status: code, message: message, path: path)
                default:
                    throw SFTPError.protocolError("unexpected reply to READ")
                }
            }
        }

        // Unknown size (e.g. /proc files): read sequentially until EOF.
        let sequential = size == 0
        while true {
            try Task.checkCancellation()
            while !reachedEOF && inflight.count < (sequential ? 1 : window) && (sequential || nextOffset < size) {
                let length = sequential ? chunkSize : Int(min(UInt64(chunkSize), size - nextOffset))
                inflight.append((nextOffset, length, issue(nextOffset, length)))
                nextOffset += UInt64(length)
            }
            guard !inflight.isEmpty else { break }
            let item = inflight.removeFirst()
            guard let chunk = try await item.task.value else {
                reachedEOF = true
                for rest in inflight { rest.task.cancel() }
                inflight.removeAll()
                break
            }
            try sink(item.offset, chunk)
            done += UInt64(chunk.count)
            progress(done)
            if chunk.count < item.length {
                // Short read: fetch the rest of this range before continuing.
                var offset = item.offset + UInt64(chunk.count)
                let end = item.offset + UInt64(item.length)
                while offset < end {
                    guard let more = try await issue(offset, Int(end - offset)).value, !more.isEmpty else {
                        reachedEOF = true
                        break
                    }
                    try sink(offset, more)
                    offset += UInt64(more.count)
                    done += UInt64(more.count)
                    progress(done)
                }
                if reachedEOF {
                    for rest in inflight { rest.task.cancel() }
                    inflight.removeAll()
                    break
                }
            }
        }
    }

    private func writePipelined(handle: Data, size: UInt64, path: String,
                                source: (UInt64, Int) throws -> Data,
                                progress: (UInt64) -> Void) async throws {
        var nextOffset: UInt64 = 0
        var done: UInt64 = 0
        var inflight: [(length: Int, task: Task<Void, Error>)] = []
        defer { for item in inflight { item.task.cancel() } }

        while nextOffset < size || !inflight.isEmpty {
            try Task.checkCancellation()
            while inflight.count < window && nextOffset < size {
                let length = Int(min(UInt64(chunkSize), size - nextOffset))
                let chunk = try source(nextOffset, length)
                guard !chunk.isEmpty else { break }
                let offset = nextOffset
                let task = Task { [connection] in
                    let response = try await connection.request(.write) { w in
                        w.bytes(handle)
                        w.u64(offset)
                        w.bytes(chunk)
                    }
                    try Self.checkStatus(response, path: path)
                }
                inflight.append((chunk.count, task))
                nextOffset += UInt64(chunk.count)
            }
            guard !inflight.isEmpty else { break }
            let item = inflight.removeFirst()
            try await item.task.value
            done += UInt64(item.length)
            progress(done)
        }
    }

    // MARK: Handles

    private func openFile(_ path: String, flags: SFTPOpenFlags, permissions: UInt32? = nil) async throws -> Data {
        let response = try await connection.request(.open) { w in
            w.string(path)
            w.u32(flags.rawValue)
            SFTPAttributes(permissions: permissions).encode(into: &w)
        }
        return try Self.parseHandle(response, path: path)
    }

    private func openDirectory(_ path: String) async throws -> Data {
        let response = try await connection.request(.opendir) { $0.string(path) }
        return try Self.parseHandle(response, path: path)
    }

    private func fstat(_ handle: Data, path: String) async throws -> SFTPAttributes {
        let response = try await connection.request(.fstat) { $0.bytes(handle) }
        return try Self.parseAttrs(response, path: path)
    }

    private static func closeHandle(_ handle: Data, _ connection: SFTPConnection) async throws {
        let response = try await connection.request(.close) { $0.bytes(handle) }
        try checkStatus(response, path: nil)
    }

    // MARK: Parsing

    private func expectOK(_ response: SFTPResponse, path: String) throws {
        try Self.checkStatus(response, path: path)
    }

    static func checkStatus(_ response: SFTPResponse, path: String?) throws {
        guard response.type == .status else { throw SFTPError.protocolError("expected STATUS") }
        let (code, message) = try parseStatus(response.payload)
        guard code == .ok else { throw SFTPError(status: code, message: message, path: path) }
    }

    static func parseStatus(_ payload: Data) throws -> (SFTPStatus, String) {
        var r = SFTPReader(payload)
        let raw = try r.u32()
        let message = r.remaining >= 4 ? (try? r.string()) ?? "" : ""
        return (SFTPStatus(rawValue: raw) ?? .failure, message)
    }

    static func parseHandle(_ response: SFTPResponse, path: String) throws -> Data {
        if response.type == .status {
            let (code, message) = try parseStatus(response.payload)
            throw SFTPError(status: code, message: message, path: path)
        }
        guard response.type == .handle else { throw SFTPError.protocolError("expected HANDLE") }
        var r = SFTPReader(response.payload)
        return try r.bytes()
    }

    static func parseAttrs(_ response: SFTPResponse, path: String) throws -> SFTPAttributes {
        if response.type == .status {
            let (code, message) = try parseStatus(response.payload)
            throw SFTPError(status: code, message: message, path: path)
        }
        guard response.type == .attrs else { throw SFTPError.protocolError("expected ATTRS") }
        var r = SFTPReader(response.payload)
        return try SFTPAttributes.decode(from: &r)
    }

    static func parseNames(_ response: SFTPResponse, path: String) throws -> [(name: String, attrs: SFTPAttributes)] {
        if response.type == .status {
            let (code, message) = try parseStatus(response.payload)
            throw SFTPError(status: code, message: message, path: path)
        }
        guard response.type == .name else { throw SFTPError.protocolError("expected NAME") }
        var r = SFTPReader(response.payload)
        let count = try r.u32()
        var result: [(String, SFTPAttributes)] = []
        for _ in 0..<count {
            let name = try r.string()
            _ = try r.string() // longname
            result.append((name, try SFTPAttributes.decode(from: &r)))
        }
        return result
    }

    // MARK: Path helpers

    public static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    public static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return "." }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    public static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
