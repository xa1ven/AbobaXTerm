import Darwin
import Foundation
import Synchronization

/// A response packet: type plus the payload after the request id.
struct SFTPResponse: Sendable {
    let type: SFTPPacketType
    let payload: Data
}

/// Low-level SFTP v3 transport over a child process (normally
/// `ssh -S <ControlPath> -s host sftp`, i.e. a channel of the existing
/// ControlMaster connection).
///
/// Requests may be issued concurrently; a reader thread matches responses to
/// requests by id, so pipelining (many reads/writes in flight) is natural.
final class SFTPConnection: @unchecked Sendable {
    private struct State {
        var nextID: UInt32 = 1
        var pending: [UInt32: CheckedContinuation<SFTPResponse, Error>] = [:]
        var versionWaiter: CheckedContinuation<(UInt32, [String: String]), Error>?
        var closedError: SFTPError?
        var stderrTail = ""
    }

    private let process: Process
    private let inputFD: Int32
    private let outputFD: Int32
    private let state = Mutex(State())
    private let writeLock = NSLock()

    private(set) var serverVersion: UInt32 = 0
    private(set) var extensions: [String: String] = [:]

    private init(process: Process, inputFD: Int32, outputFD: Int32) {
        self.process = process
        self.inputFD = inputFD
        self.outputFD = outputFD
    }

    /// Starts the subsystem process and performs the INIT/VERSION handshake.
    static func open(executable: String, arguments: [String], environment: [String: String]?) async throws -> SFTPConnection {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Writing to a dead ssh must not raise SIGPIPE in the app.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let connection = SFTPConnection(process: process,
                                        inputFD: stdin.fileHandleForWriting.fileDescriptor,
                                        outputFD: stdout.fileHandleForReading.fileDescriptor)
        // Keep the pipe objects alive as long as the connection.
        connection.pipes = [stdin, stdout, stderr]

        stderr.fileHandleForReading.readabilityHandler = { [weak connection] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let connection else {
                handle.readabilityHandler = nil
                return
            }
            connection.state.withLock { s in
                s.stderrTail = String((s.stderrTail + String(decoding: chunk, as: UTF8.self)).suffix(2000))
            }
        }
        process.terminationHandler = { [weak connection] _ in
            connection?.fail(SFTPError(status: .connectionLost, message: "ssh exited"))
        }

        try process.run()
        let reader = Thread { [connection] in connection.readLoop() }
        reader.name = "AbobaXTerm.sftp-reader"
        reader.start()

        let (version, extensions) = try await withCheckedThrowingContinuation { continuation in
            connection.state.withLock { $0.versionWaiter = continuation }
            var w = SFTPWriter()
            w.u32(3)
            do {
                try connection.sendPacket(type: .initialize, body: w.data)
            } catch {
                connection.fail(error as? SFTPError ?? SFTPError(status: .connectionLost, message: "\(error)"))
            }
        }
        connection.serverVersion = version
        connection.extensions = extensions
        return connection
    }

    private var pipes: [Pipe] = []

    deinit {
        close()
    }

    func close() {
        if process.isRunning { process.terminate() }
        fail(SFTPError(status: .connectionLost, message: "closed"))
    }

    var isClosed: Bool { state.withLock { $0.closedError != nil } }

    /// Sends a request and waits for its response.
    func request(_ type: SFTPPacketType, _ build: (inout SFTPWriter) -> Void) async throws -> SFTPResponse {
        var body = SFTPWriter()
        build(&body)
        let payload = body.data
        return try await withCheckedThrowingContinuation { continuation in
            let id: UInt32? = state.withLock { s in
                if let error = s.closedError {
                    continuation.resume(throwing: error)
                    return nil
                }
                let id = s.nextID
                s.nextID &+= 1
                s.pending[id] = continuation
                return id
            }
            guard let id else { return }
            var w = SFTPWriter()
            w.u32(id)
            w.data.append(payload)
            do {
                try sendPacket(type: type, body: w.data)
            } catch {
                fail(error as? SFTPError ?? SFTPError(status: .connectionLost, message: "\(error)"))
            }
        }
    }

    private func sendPacket(type: SFTPPacketType, body: Data) throws {
        var packet = SFTPWriter()
        packet.u32(UInt32(body.count + 1))
        packet.u8(type.rawValue)
        packet.data.append(body)
        writeLock.lock()
        defer { writeLock.unlock() }
        try packet.data.withUnsafeBytes { raw in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(inputFD, p, left)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SFTPError(status: .connectionLost, message: "write failed: \(String(cString: strerror(errno)))")
                }
                left -= n
                p += n
            }
        }
    }

    // MARK: Reader

    private func readLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let n = Darwin.read(outputFD, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            buffer.append(contentsOf: chunk[0..<n])

            while buffer.count >= 4 {
                let start = buffer.startIndex
                let length = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16
                    | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
                guard length >= 1, length < 64 * 1024 * 1024 else {
                    fail(SFTPError.protocolError("bad packet length \(length)"))
                    return
                }
                guard buffer.count >= 4 + length else { break }
                let packet = buffer.subdata(in: start + 4..<start + 4 + length)
                buffer.removeSubrange(start..<start + 4 + length)
                dispatch(packet)
            }
        }
        // Give stderr a moment to arrive so the error message is useful.
        usleep(50_000)
        let tail = state.withLock { $0.stderrTail }.trimmingCharacters(in: .whitespacesAndNewlines)
        fail(SFTPError(status: .connectionLost, message: tail.isEmpty ? "Connection closed" : tail))
    }

    private func dispatch(_ packet: Data) {
        var r = SFTPReader(packet)
        do {
            guard let type = SFTPPacketType(rawValue: try r.u8()) else { return }
            if type == .version {
                let version = try r.u32()
                var ext: [String: String] = [:]
                while r.remaining > 0 { ext[try r.string()] = try r.string() }
                let waiter = state.withLock { s -> CheckedContinuation<(UInt32, [String: String]), Error>? in
                    defer { s.versionWaiter = nil }
                    return s.versionWaiter
                }
                waiter?.resume(returning: (version, ext))
                return
            }
            let id = try r.u32()
            let continuation = state.withLock { $0.pending.removeValue(forKey: id) }
            continuation?.resume(returning: SFTPResponse(type: type, payload: packet.subdata(in: r.offset..<packet.endIndex)))
        } catch {
            fail(SFTPError.protocolError("malformed packet"))
        }
    }

    private func fail(_ error: SFTPError) {
        let (pending, version) = state.withLock { s -> ([CheckedContinuation<SFTPResponse, Error>], CheckedContinuation<(UInt32, [String: String]), Error>?) in
            if s.closedError == nil { s.closedError = error }
            let p = Array(s.pending.values)
            s.pending.removeAll()
            let v = s.versionWaiter
            s.versionWaiter = nil
            return (p, v)
        }
        let finalError = state.withLock { $0.closedError } ?? error
        for c in pending { c.resume(throwing: finalError) }
        version?.resume(throwing: finalError)
    }
}
