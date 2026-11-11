import Darwin
import Foundation

/// Minimal blocking helpers for AF_UNIX stream sockets.
public enum UnixSocket {
    public struct SocketError: Error, CustomStringConvertible {
        public let operation: String
        public let code: Int32
        public var description: String { "\(operation): \(String(cString: strerror(code)))" }

        public init(operation: String, code: Int32) {
            self.operation = operation
            self.code = code
        }
    }

    /// Fills a sockaddr_un; fails if the path does not fit (104 bytes on Darwin).
    public static func address(for path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SocketError(operation: "path too long", code: ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    public static func connect(path: String) throws -> Int32 {
        var addr = try address(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(operation: "socket", code: errno) }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw SocketError(operation: "connect", code: code)
        }
        return fd
    }

    public static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(fd, pointer, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SocketError(operation: "write", code: errno)
                }
                remaining -= n
                pointer += n
            }
        }
    }

    /// Reads until a newline, EOF or `limit` bytes.
    public static func readLine(fd: Int32, limit: Int = 64 * 1024) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while result.count < limit {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketError(operation: "read", code: errno)
            }
            if n == 0 { break }
            result.append(contentsOf: buffer[0..<n])
            if buffer[0..<n].contains(0x0A) { break }
        }
        return result
    }
}
