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
    /// On a Retina display, run the server at device-pixel resolution and have
    /// toolkits render at 2x. Off: everything at 1x, enlarged by the Mac
    /// (soft, but old X programs that cannot scale keep their size).
    /// Changing it restarts the server once no X windows are open.
    public var prefersHiDPI = true { didSet { if prefersHiDPI != oldValue { applyDesktopChange() } } }
    /// Command+C/V/X/A/Z copy, paste, cut, select all and undo in X programs
    /// (sent as each program's own shortcut). Off: Command is always the Super
    /// key, which is what a virtual machine's console wants.
    public var translatesCommandShortcuts = true {
        didSet { manager?.keyboard.translatesCommandShortcuts = translatesCommandShortcuts }
    }
    /// Pasteboard mirrored to the X clipboard; tests substitute a private one.
    public var pasteboard = NSPasteboard.general
    /// Fixed scale for tests; nil follows the screens.
    public var scaleOverride: CGFloat?
    /// Fixed root size in points for the harness (a root smaller than the
    /// screens, as after connecting a monitor); nil covers all screens.
    public var rootSizeOverride: CGSize?
    /// Called when the number or titles of X windows change.
    public var onChange: (() -> Void)?

    private var server: X11ServerProcess?
    private var manager: X11WindowManager?
    private var startTask: Task<String, Error>?
    private var generation = 0
    private var restartPending = false
    /// The desktop the running server was started for.
    private var startedDesktop: X11Desktop?
    private var screenObserver: NSObjectProtocol?

    public init(runtimeDirectory: URL, installation: X11ServerInstallation? = .locate()) {
        self.runtimeDirectory = runtimeDirectory
        self.installation = installation
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyDesktopChange(screensChanged: true) }
        }
    }

    /// The root window's size and scale are fixed when the server starts. When
    /// the screens or the HiDPI preference change, restart it — but only while
    /// no X program has a window open; otherwise as soon as the last one closes.
    /// Until then the window manager makes do with the root it has
    /// (`X11WindowManager.ensureReachable`).
    private func applyDesktopChange(screensChanged: Bool = false) {
        guard case .running = state, manager != nil else { return }
        if screensChanged, windowCount > 0 {
            // AppKit moves windows off a disconnected screen itself; look afterwards.
            let generation = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.generation == generation else { return }
                self.manager?.screensChanged()
            }
        }
        guard currentDesktop() != startedDesktop else {
            restartPending = false
            return
        }
        guard windowCount == 0 else {
            restartPending = true
            return
        }
        restartPending = false
        shutdown()
        Task { _ = try? await ensureRunning() }
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
        restartPending = false
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
            let desktop = currentDesktop()
            startedDesktop = desktop
            let server = X11ServerProcess(installation: installation, directory: runtimeDirectory)
            let endpoint = try await server.start(width: desktop.pixelWidth, height: desktop.pixelHeight,
                                                  dpi: Int(96 * desktop.scale))
            self.server = server
            server.onExit = { [weak self] in
                Task { @MainActor in self?.serverEnded(generation: generation) }
            }

            let connection = try XConnection(socketPath: endpoint.socketPath, cookie: endpoint.authority.cookie)
            let manager = try await X11WindowManager(connection: connection, desktop: desktop, presentsWindows: presentsWindows)
            manager.pasteboard = pasteboard
            manager.keyboard.translatesCommandShortcuts = translatesCommandShortcuts
            manager.onChange = { [weak self] in
                guard let self else { return }
                self.onChange?()
                if self.restartPending { self.applyDesktopChange() }
            }
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
    private func currentDesktop() -> X11Desktop {
        let frames = NSScreen.screens.map(\.frame)
        let union = frames.dropFirst().reduce(frames.first ?? CGRect(x: 0, y: 0, width: 1440, height: 900)) { $0.union($1) }
        let densest = NSScreen.screens.map(\.backingScaleFactor).max() ?? 1
        let scale = scaleOverride ?? (prefersHiDPI ? max(1, densest.rounded()) : 1)
        if let size = rootSizeOverride {
            return X11Desktop(frame: CGRect(x: union.minX, y: union.maxY - size.height, width: size.width, height: size.height),
                              scale: scale)
        }
        return X11Desktop(frame: union, scale: scale)
    }

    /// The scale the running server was started with (X pixels per point).
    public var activeScale: CGFloat? { manager?.desktop.scale }

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
        public var icon: Data?
        public var dockTile: Data?
    }

    public func debugWindows(includePixels: Bool = true) -> [WindowDump] {
        (manager?.snapshot(includePixels: includePixels) ?? []).map {
            WindowDump(id: $0.id, title: $0.title, x: $0.geometry.x, y: $0.geometry.y, width: $0.geometry.width,
                       height: $0.geometry.height, isMapped: $0.isMapped, overrideRedirect: $0.overrideRedirect,
                       hostFrame: $0.hostFrame, png: $0.png,
                       icon: $0.icon, dockTile: $0.dockTile)
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

    /// Offers the pasteboard to X clients, as happens when an X window becomes key.
    public func debugOfferPasteboard() { manager?.offerPasteboard() }

    public func debugType(_ text: String) { manager?.keyboard.type(text) }
    public func debugTap(keyCode: UInt8, shift: Bool = false) { manager?.keyboard.tap(keyCode: keyCode, shift: shift) }

    public func debugKey(keyCode: UInt8, down: Bool) { manager?.keyboard.set(keyCode: keyCode, down: down) }

    /// Command+key in a window, as the user would press it. False if it is not a translated shortcut.
    @discardableResult
    public func debugShortcut(window id: UInt32, keyCode: UInt8) -> Bool {
        guard let manager, let window = manager.windows[id] else { return false }
        return manager.performShortcut(macKey: UInt16(keyCode), in: window)
    }

    /// Presses or releases the left button at a position in a window (for scripted drags).
    public func debugButton(window id: UInt32, x: Int, y: Int, pressed: Bool) {
        guard let manager, let window = manager.windows[id] else { return }
        manager.movePointer(to: CGPoint(x: x, y: y), in: window)
        manager.connection.fakeInput(manager.ext, pressed ? .buttonPress : .buttonRelease, detail: 1)
    }

    /// Draw timing since the last call (see `X11DrawStats`).
    public func debugDrawStats() -> String {
        guard let manager else { return "no server" }
        defer { manager.drawStats = X11DrawStats() }
        return manager.drawStats.summary
    }

    /// Asks a window to close, as the title-bar button does.
    public func debugClose(window id: UInt32) {
        guard let manager, let window = manager.windows[id] else { return }
        manager.requestClose(window)
    }
}
