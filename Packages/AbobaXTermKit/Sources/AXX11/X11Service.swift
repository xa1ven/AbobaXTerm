import AppKit

/// The app's built-in X11 display: a headless X server running as a hidden
/// child process, with its windows shown as native windows of this app.
///
/// The server starts on first use and lives until `shutdown()`. If it dies,
/// the next `ensureRunning()` starts a fresh one.
@MainActor
public final class X11Service {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case running(display: String)
        case failed(String)
    }

    public private(set) var state: State = .stopped
    public let runtimeDirectory: URL
    public let installation: X11ServerInstallation?
    /// False keeps X windows off screen (tests and the development harness).
    public var presentsWindows = true
    /// Called when the number or titles of X windows change.
    public var onChange: (() -> Void)?

    private var server: X11ServerProcess?
    private var manager: X11WindowManager?
    private var startTask: Task<String, Error>?
    private var generation = 0

    public init(runtimeDirectory: URL, installation: X11ServerInstallation? = .locate()) {
        self.runtimeDirectory = runtimeDirectory
        self.installation = installation
    }

    /// Whether the server binary is there at all.
    public var isAvailable: Bool { installation != nil }

    /// Path to pass to ssh as `XAuthLocation` (a stand-in for `xauth` that knows the server's cookie).
    public nonisolated static func xauthLocation(runtimeDirectory: URL) -> String {
        X11ServerProcess.xauthShim(in: runtimeDirectory).path
    }

    /// Number of X windows currently on screen.
    public var windowCount: Int {
        manager?.windows.values.filter { $0.isMapped && !$0.overrideRedirect }.count ?? 0
    }

    /// Starts the server if needed and returns the DISPLAY value for clients.
    public func ensureRunning() async throws -> String {
        if case .running(let display) = state { return display }
        if let startTask { return try await startTask.value }
        let task = Task { try await start() }
        startTask = task
        defer { startTask = nil }
        return try await task.value
    }

    /// Environment for X clients started on this Mac.
    public func localClientEnvironment() -> [String: String] {
        guard case .running(let display) = state, let server else { return [:] }
        return ["DISPLAY": display, "XAUTHORITY": server.authorityFile.path]
    }

    public func shutdown() {
        generation += 1
        manager?.connection.shutdown()
        manager?.tearDown()
        manager = nil
        server?.stop()
        server = nil
        state = .stopped
    }

    // MARK: Startup

    private func start() async throws -> String {
        guard let installation else {
            state = .failed(X11ServerError.notInstalled.localizedDescription)
            throw X11ServerError.notInstalled
        }
        state = .starting
        generation += 1
        let generation = generation
        do {
            let desktop = Self.currentDesktop()
            let server = X11ServerProcess(installation: installation, directory: runtimeDirectory)
            let endpoint = try await server.start(width: desktop.pixelWidth, height: desktop.pixelHeight,
                                                  dpi: Int(96 * desktop.scale))
            self.server = server
            server.onExit = { [weak self] in
                Task { @MainActor in self?.serverEnded(generation: generation) }
            }

            let connection = try XConnection(socketPath: endpoint.socketPath, cookie: endpoint.authority.cookie)
            let manager = try await X11WindowManager(connection: connection, desktop: desktop, presentsWindows: presentsWindows)
            manager.onChange = { [weak self] in self?.onChange?() }
            try await manager.start()
            self.manager = manager
            Task { [weak self] in
                await manager.run()
                self?.serverEnded(generation: generation)
            }
            state = .running(display: endpoint.displayName)
            return endpoint.displayName
        } catch {
            server?.stop()
            server = nil
            manager = nil
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    private func serverEnded(generation ended: Int) {
        guard ended == generation, state != .stopped else { return }
        manager?.connection.shutdown()
        manager?.tearDown()
        manager = nil
        server?.stop()
        server = nil
        state = .stopped
    }

    /// The X root window covers all screens, in points (see `X11Desktop`).
    private static func currentDesktop() -> X11Desktop {
        let frames = NSScreen.screens.map(\.frame)
        let union = frames.dropFirst().reduce(frames.first ?? CGRect(x: 0, y: 0, width: 1440, height: 900)) { $0.union($1) }
        return X11Desktop(frame: union, scale: 1)
    }

    // MARK: Debugging (development harness)

    public struct WindowDump: Sendable {
        public var id: UInt32
        public var title: String
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int
        public var isMapped: Bool
        public var overrideRedirect: Bool
        public var hostFrame: CGRect?
        public var png: Data?
    }

    public func debugWindows(includePixels: Bool = true) -> [WindowDump] {
        (manager?.snapshot(includePixels: includePixels) ?? []).map {
            WindowDump(id: $0.id, title: $0.title, x: $0.geometry.x, y: $0.geometry.y, width: $0.geometry.width,
                       height: $0.geometry.height, isMapped: $0.isMapped, overrideRedirect: $0.overrideRedirect,
                       hostFrame: $0.hostFrame, png: $0.png)
        }
    }

    /// Clicks inside a window (X pixels from its top-left corner).
    public func debugClick(window id: UInt32, x: Int, y: Int, button: Int = 1) {
        guard let manager, let window = manager.windows[id] else { return }
        manager.click(window, x: x, y: y, button: button)
    }

    public func debugMovePointer(window id: UInt32, x: Int, y: Int) {
        guard let manager, let window = manager.windows[id] else { return }
        manager.movePointer(to: CGPoint(x: x, y: y), in: window)
    }

    public func debugType(_ text: String) { manager?.keyboard.type(text) }
    public func debugTap(keyCode: UInt8, shift: Bool = false) { manager?.keyboard.tap(keyCode: keyCode, shift: shift) }

    public func debugKey(keyCode: UInt8, down: Bool) { manager?.keyboard.set(keyCode: keyCode, down: down) }

    /// Asks a window to close, as the title-bar button does.
    public func debugClose(window id: UInt32) {
        guard let manager, let window = manager.windows[id] else { return }
        manager.requestClose(window)
    }
}
