import AXAskpassProtocol
import Darwin
import Foundation

/// Tiny request/response server on an AF_UNIX socket.
///
/// Each client sends one line and gets one reply. Only clients running as the
/// same user are accepted (checked with getpeereid), and the socket file is
/// created with mode 0600 inside a 0700 directory.
final class UnixSocketServer: @unchecked Sendable {
    typealias Handler = @Sendable (Data) async -> Data

    let path: String
    private let listenFD: Int32
    private let handler: Handler

    init(path: String, handler: @escaping Handler) throws {
        self.path = path
        self.handler = handler

        var addr = try UnixSocket.address(for: path)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocket.SocketError(operation: "socket", code: errno) }

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw UnixSocket.SocketError(operation: "bind", code: code)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw UnixSocket.SocketError(operation: "listen", code: code)
        }
        listenFD = fd

        let thread = Thread { [self] in acceptLoop() }
        thread.name = "AbobaXTerm.askpass"
        thread.start()
    }

    func stop() {
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        unlink(path)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return // listening socket closed
            }

            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                close(client)
                continue
            }

            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            guard let request = try? UnixSocket.readLine(fd: client), !request.isEmpty else {
                close(client)
                continue
            }
            let handler = self.handler
            Task.detached {
                let reply = await handler(request)
                try? UnixSocket.writeAll(fd: client, data: reply)
                close(client)
            }
        }
    }
}
