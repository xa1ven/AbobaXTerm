import AXL10n
import Darwin
import Foundation

/// Where the headless X server binary and its data live.
public struct X11ServerInstallation: Equatable, Sendable {
    public var executable: String
    /// XKB data directory to pass with `-xkbdir`; nil uses the path compiled into the binary.
    public var xkbDirectory: String?

    /// Looks for the server bundled with the app first, then for a system-wide one.
    public static func locate(bundle: Bundle = .main,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> X11ServerInstallation? {
        let fm = FileManager.default
        // Development override: a server binary, or the root of a tree laid out like the bundled one.
        if let override = environment["ABX_X11_SERVER"] {
            if fm.isExecutableFile(atPath: override), !isDirectory(override) {
                return X11ServerInstallation(executable: override, xkbDirectory: environment["ABX_X11_XKBDIR"])
            }
            if let found = bundled(at: URL(fileURLWithPath: override, isDirectory: true)) { return found }
        }
        if let resources = bundle.resourceURL,
           let found = bundled(at: resources.appendingPathComponent("xserver", isDirectory: true)) {
            return found
        }
        // Fallback for builds made without Vendor/xserver: a server from XQuartz or Homebrew.
        for path in ["/opt/X11/bin/Xvfb", "/opt/homebrew/bin/Xvfb", "/usr/local/bin/Xvfb"] where fm.isExecutableFile(atPath: path) {
            return X11ServerInstallation(executable: path, xkbDirectory: nil)
        }
        return nil
    }

    /// The server built by Scripts/build-xserver.sh: `bin/Xvfb`, `bin/xkbcomp`, `share/X11/xkb`.
    private static func bundled(at root: URL) -> X11ServerInstallation? {
        let binary = root.appendingPathComponent("bin/Xvfb").path
        guard FileManager.default.isExecutableFile(atPath: binary) else { return nil }
        return X11ServerInstallation(executable: binary, xkbDirectory: root.appendingPathComponent("share/X11/xkb").path)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}

public enum X11ServerError: Error, LocalizedError, Equatable {
    case notInstalled
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: L("The built-in X server is missing from the app.")
        case .startFailed(let why): L("The built-in X server did not start: %@", why)
        }
    }
}

/// Runs the headless X server as a child process and owns its files in the
/// runtime directory: Xauthority, the `xauth` stand-in for ssh and the log.
final class X11ServerProcess: @unchecked Sendable {
    struct Endpoint: Equatable, Sendable {
        var display: Int
        var authority: X11Authority
        var socketPath: String { "/tmp/.X11-unix/X\(display)" }
        var displayName: String { ":\(display)" }
    }

    let installation: X11ServerInstallation
    let directory: URL
    /// Called (on an arbitrary thread) when the server exits on its own.
    var onExit: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var watchdog: Process?
    private var watchdogInput: Pipe?
    private var stopping = false

    static let displayCandidates = 41...60

    init(installation: X11ServerInstallation, directory: URL) {
        self.installation = installation
        self.directory = directory
    }

    var authorityFile: URL { directory.appendingPathComponent("x11-authority") }
    var xauthShim: URL { Self.xauthShim(in: directory) }
    var logFile: URL { directory.appendingPathComponent("x11-server.log") }
    private var stateFile: URL { directory.appendingPathComponent("x11-state") }

    /// Path given to ssh as `XAuthLocation`; the file appears once the server has started.
    static func xauthShim(in directory: URL) -> URL { directory.appendingPathComponent("abx-xauth") }

    /// Starts the server with a root window of `width` x `height` pixels.
    ///
    /// The display number and cookie are kept across restarts: a ControlMaster
    /// connection that outlives the app keeps forwarding to the same display
    /// with the same cookie.
    func start(width: Int, height: Int, dpi: Int) async throws -> Endpoint {
        let saved = loadState()
        let authority = saved?.authority ?? .random()
        try authority.xauthorityFile.write(to: authorityFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authorityFile.path)

        var candidates = Array(Self.displayCandidates)
        if let display = saved?.display {
            candidates.removeAll { $0 == display }
            candidates.insert(display, at: 0)
        }
        var lastFailure = "no free display"
        for display in candidates {
            // This server build takes no lock file: starting on a display that is in use
            // would silently replace the other server's socket. Probe it ourselves.
            if Self.isListening(onDisplay: display) {
                lastFailure = "display :\(display) is in use"
                continue
            }
            do {
                try await launch(display: display, width: width, height: height, dpi: dpi)
            } catch let X11ServerError.startFailed(why) {
                lastFailure = why
                continue
            }
            let endpoint = Endpoint(display: display, authority: authority)
            try saveState(endpoint)
            return endpoint
        }
        throw X11ServerError.startFailed(lastFailure)
    }

    func stop() {
        lock.lock()
        stopping = true
        let (process, watchdog, input) = (self.process, self.watchdog, self.watchdogInput)
        self.process = nil
        self.watchdog = nil
        self.watchdogInput = nil
        lock.unlock()
        // The watchdog goes first so it cannot signal a recycled pid.
        if let watchdog, watchdog.isRunning { watchdog.terminate() }
        try? input?.fileHandleForWriting.close()
        if let process, process.isRunning { process.terminate() }
    }

    /// True when some X server accepts connections on the display's Unix socket.
    /// A leftover socket file nobody listens on does not count.
    static func isListening(onDisplay display: Int) -> Bool {
        let path = "/tmp/.X11-unix/X\(display)"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    // MARK: Launch

    private func launch(display: Int, width: Int, height: Int, dpi: Int) async throws {
        var arguments = [
            ":\(display)", "-displayfd", "1",
            "-screen", "0", "\(width)x\(height)x24",
            "-auth", authorityFile.path,
            "-nolisten", "tcp", "-noreset",
            "-dpi", String(dpi),
        ]
        if let xkb = installation.xkbDirectory { arguments += ["-xkbdir", xkb] }

        FileManager.default.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: installation.executable)
        process.arguments = arguments
        // The bundled server runs its keymap compiler as "./xkbcomp" (the app can be
        // anywhere on disk, so no absolute path is compiled in).
        process.currentDirectoryURL = URL(fileURLWithPath: installation.executable).deletingLastPathComponent()
        let ready = Pipe()
        process.standardOutput = ready
        process.standardError = (try? FileHandle(forWritingTo: logFile)) ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.lock.lock()
            let unexpected = !self.stopping && self.process === finished
            if unexpected { self.process = nil }
            self.lock.unlock()
            if unexpected { self.onExit?() }
        }
        do {
            try process.run()
        } catch {
            throw X11ServerError.startFailed(error.localizedDescription)
        }

        // The server writes its display number to the pipe once it accepts
        // connections, or exits (closing the pipe) when the display is taken.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        let output: Data = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ready.fileHandleForReading.availableData)
            }
        }
        timeout.cancel()
        let reported = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard Int(reported) == display, process.isRunning else {
            if process.isRunning { process.terminate() }
            let log = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
            let reason = log.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            throw X11ServerError.startFailed(reason.map(String.init) ?? "display :\(display) is not available")
        }

        lock.withLock {
            stopping = false
            self.process = process
        }
        startWatchdog(for: process)
    }

    /// A shell that blocks on a pipe from the app and kills the server when
    /// the pipe closes, i.e. when the app dies without cleaning up.
    private func startWatchdog(for server: Process) {
        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = ["-c", "read _; kill \"$1\" 2>/dev/null", "sh", String(server.processIdentifier)]
        let input = Pipe()
        watchdog.standardInput = input
        watchdog.standardOutput = FileHandle.nullDevice
        watchdog.standardError = FileHandle.nullDevice
        guard (try? watchdog.run()) != nil else { return }
        lock.lock()
        self.watchdog = watchdog
        self.watchdogInput = input
        lock.unlock()
    }

    // MARK: Persistent state

    private func loadState() -> Endpoint? {
        guard let text = try? String(contentsOf: stateFile, encoding: .utf8) else { return nil }
        let parts = text.split(separator: " ").map(String.init)
        guard parts.count == 2, let display = Int(parts[0]), let authority = X11Authority(hex: parts[1]) else { return nil }
        return Endpoint(display: display, authority: authority)
    }

    private func saveState(_ endpoint: Endpoint) throws {
        let fm = FileManager.default
        try "\(endpoint.display) \(endpoint.authority.hex)".write(to: stateFile, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
        try endpoint.authority.xauthShim(display: endpoint.display).write(to: xauthShim, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: xauthShim.path)
    }
}
