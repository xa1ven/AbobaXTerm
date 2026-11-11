import Darwin
import Foundation

/// Error packet from the X server.
public struct XProtocolError: Error, CustomStringConvertible, Sendable {
    public let code: UInt8
    public let majorOpcode: UInt8
    public let minorOpcode: UInt16
    public let resource: UInt32

    public var description: String {
        "X error \(code) (request \(majorOpcode).\(minorOpcode), resource 0x\(String(resource, radix: 16)))"
    }
}

public enum XConnectionError: Error, LocalizedError {
    case connectFailed(String)
    case setupRefused(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .connectFailed(let why): "Cannot connect to the X server: \(why)"
        case .setupRefused(let why): "The X server refused the connection: \(why)"
        case .closed: "The X server connection was closed"
        }
    }
}

/// What the server reports at connection setup (first screen only).
struct XSetup: Sendable {
    var resourceIDBase: UInt32 = 0
    var resourceIDMask: UInt32 = 0
    var minKeycode: UInt8 = 8
    var maxKeycode: UInt8 = 255
    var root: UInt32 = 0
    var rootVisual: UInt32 = 0
    var rootDepth: UInt8 = 24
    var width: Int = 0
    var height: Int = 0
    /// Visual ids that carry an alpha channel (depth 32).
    var argbVisuals: Set<UInt32> = []
}

/// Client connection to the embedded X server over its Unix socket.
///
/// Requests can be sent from any thread; they are written in call order.
/// A dedicated thread reads the socket: replies resume the waiting caller,
/// events go to `events` in arrival order.
final class XConnection: @unchecked Sendable {
    let setup: XSetup
    /// Events and connection end, in order. Finishes when the server goes away.
    let events: AsyncStream<[UInt8]>

    private let fd: Int32
    private let lock = NSLock()
    private var sequence: UInt16 = 0
    private var waiting: [UInt16: CheckedContinuation<[UInt8], Error>] = [:]
    private var outbox: [UInt8] = []
    private var flushScheduled = false
    private var closed = false
    private var nextResource: UInt32 = 0
    private let writeQueue = DispatchQueue(label: "com.mikhail.AbobaXTerm.x11.write")
    private let eventSink: AsyncStream<[UInt8]>.Continuation
    /// Errors for requests nobody waits on (debugging aid).
    var onAsyncError: (@Sendable (XProtocolError) -> Void)?

    /// Connects and authenticates with an MIT-MAGIC-COOKIE-1 cookie.
    init(socketPath: String, cookie: [UInt8]) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XConnectionError.connectFailed(String(cString: strerror(errno))) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw XConnectionError.connectFailed("socket path is too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            let why = String(cString: strerror(errno))
            close(fd)
            throw XConnectionError.connectFailed(why)
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        do {
            self.setup = try Self.handshake(fd: fd, cookie: cookie)
        } catch {
            close(fd)
            throw error
        }
        self.fd = fd
        (events, eventSink) = AsyncStream.makeStream(of: [UInt8].self, bufferingPolicy: .unbounded)

        let thread = Thread { [weak self] in self?.readLoop(fd: fd) }
        thread.name = "AbobaXTerm X11 reader"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    deinit { shutdown() }

    /// Closes the socket; pending replies fail and `events` finishes.
    func shutdown() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        if !wasClosed { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    /// A fresh resource id (window, pixmap, damage, region...).
    func newID() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        nextResource += 1
        return setup.resourceIDBase | (nextResource & setup.resourceIDMask)
    }

    // MARK: Sending

    /// Sends a request that has no reply.
    func send(_ request: XRequest) {
        lock.lock()
        enqueue(request.finish())
        lock.unlock()
    }

    /// Sends a request and waits for its reply (the full packet, header included).
    func reply(_ request: XRequest) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: XConnectionError.closed)
                return
            }
            enqueue(request.finish())
            waiting[sequence] = continuation
            lock.unlock()
        }
    }

    /// Must be called with `lock` held.
    private func enqueue(_ bytes: [UInt8]) {
        guard !closed else { return }
        sequence &+= 1
        outbox.append(contentsOf: bytes)
        guard !flushScheduled else { return }
        flushScheduled = true
        writeQueue.async { [weak self] in self?.flush() }
    }

    private func flush() {
        lock.lock()
        let bytes = outbox
        outbox.removeAll(keepingCapacity: true)
        flushScheduled = false
        lock.unlock()
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n > 0 {
                offset += n
            } else if errno != EINTR {
                shutdown()
                return
            }
        }
    }

    // MARK: Receiving

    private func readLoop(fd: Int32) {
        while let header = Self.readExactly(fd, 32) {
            switch header[0] {
            case 0:
                let error = XProtocolError(code: header[1], majorOpcode: header[10],
                                           minorOpcode: header.u16(8), resource: header.u32(4))
                if let continuation = takeWaiter(header.u16(2)) {
                    continuation.resume(throwing: error)
                } else {
                    onAsyncError?(error)
                }
            case 1:
                var packet = header
                let extra = Int(header.u32(4)) * 4
                if extra > 0 {
                    guard let rest = Self.readExactly(fd, extra) else { break }
                    packet.append(contentsOf: rest)
                }
                takeWaiter(header.u16(2))?.resume(returning: packet)
            case 35:
                // GenericEvent: the only event kind longer than 32 bytes.
                var packet = header
                let extra = Int(header.u32(4)) * 4
                if extra > 0 {
                    guard let rest = Self.readExactly(fd, extra) else { break }
                    packet.append(contentsOf: rest)
                }
                eventSink.yield(packet)
            default:
                eventSink.yield(header)
            }
        }
        lock.lock()
        closed = true
        let orphans = waiting
        waiting.removeAll()
        lock.unlock()
        for continuation in orphans.values { continuation.resume(throwing: XConnectionError.closed) }
        eventSink.finish()
        close(fd)
    }

    private func takeWaiter(_ seq: UInt16) -> CheckedContinuation<[UInt8], Error>? {
        lock.lock()
        defer { lock.unlock() }
        return waiting.removeValue(forKey: seq)
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, count - offset) }
            if n > 0 {
                offset += n
            } else if n == 0 || errno != EINTR {
                return nil
            }
        }
        return buffer
    }

    // MARK: Setup

    private static func handshake(fd: Int32, cookie: [UInt8]) throws -> XSetup {
        let name = Array("MIT-MAGIC-COOKIE-1".utf8)
        var w = ByteWriter()
        w.u8(0x6C); w.u8(0) // little-endian
        w.u16(11); w.u16(0)
        w.u16(UInt16(name.count)); w.u16(UInt16(cookie.count)); w.u16(0)
        w.raw(name); w.pad(); w.raw(cookie); w.pad()
        let sent = w.bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard sent == w.bytes.count else { throw XConnectionError.connectFailed("short write") }

        guard let head = readExactly(fd, 8), let body = readExactly(fd, Int(head.u16(6)) * 4) else {
            throw XConnectionError.connectFailed("no setup reply")
        }
        guard head[0] == 1 else {
            let reason = String(decoding: body.prefix(Int(head[1])), as: UTF8.self)
            throw XConnectionError.setupRefused(reason.isEmpty ? "authentication failed" : reason)
        }

        var setup = XSetup()
        setup.resourceIDBase = body.u32(4)
        setup.resourceIDMask = body.u32(8)
        let vendorLength = Int(body.u16(16))
        let formatCount = Int(body.u8(21))
        setup.minKeycode = body.u8(26)
        setup.maxKeycode = body.u8(27)
        var at = 32 + ((vendorLength + 3) & ~3) + formatCount * 8
        // First screen.
        setup.root = body.u32(at)
        setup.width = Int(body.u16(at + 20))
        setup.height = Int(body.u16(at + 22))
        setup.rootVisual = body.u32(at + 32)
        setup.rootDepth = body.u8(at + 38)
        let depthCount = Int(body.u8(at + 39))
        at += 40
        for _ in 0..<depthCount {
            let depth = body.u8(at)
            let visualCount = Int(body.u16(at + 2))
            at += 8
            for _ in 0..<visualCount {
                if depth == 32 { setup.argbVisuals.insert(body.u32(at)) }
                at += 24
            }
        }
        return setup
    }
}
