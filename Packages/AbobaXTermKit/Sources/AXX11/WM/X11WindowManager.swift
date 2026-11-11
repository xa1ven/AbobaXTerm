import AppKit

/// Window manager and compositor for the embedded X server.
///
/// The server keeps every top-level window in an off-screen pixmap
/// (Composite). This class shows each of them in a native window, keeps
/// geometry, stacking and focus in sync both ways, and injects the user's
/// mouse and keyboard input (XTEST).
@MainActor
final class X11WindowManager {
    let connection: XConnection
    let ext: XExtensions
    let atoms: XAtomTable
    let keyboard: X11Keyboard
    var desktop: X11Desktop
    /// False in tests and the development harness: windows are tracked and
    /// rendered into buffers, but never put on screen.
    let presentsWindows: Bool

    var root: UInt32 { connection.setup.root }
    var windows: [UInt32: X11Window] = [:]
    /// Top-level windows as stacked on the X side, bottom-most first.
    var stack: [UInt32] = []
    var focusedWindow: UInt32?
    /// Where the next window without a position of its own goes (Cocoa top-left).
    var cascadePoint: CGPoint?
    /// Last pointer position sent to the server (root coordinates).
    var pointer: (x: Int, y: Int)?
    var scrollRemainder = CGSize.zero
    var cursorSerial: UInt32 = 0
    var clipboard = X11ClipboardState()
    /// The pasteboard mirrored to the X clipboard (tests use a private one).
    var pasteboard = NSPasteboard.general
    var currentCursor: NSCursor = .arrow

    /// Invisible window owned by the manager: EWMH check window, selection owner.
    var helperWindow: UInt32 = 0
    private var timeBase: (server: UInt32, local: TimeInterval)?
    /// Called after windows appear, disappear or change title.
    var onChange: (() -> Void)?

    init(connection: XConnection, desktop: X11Desktop, presentsWindows: Bool) async throws {
        self.connection = connection
        self.desktop = desktop
        self.presentsWindows = presentsWindows
        self.ext = try await XExtensions.negotiate(connection)
        self.atoms = try await XAtomTable.intern(on: connection)
        self.keyboard = X11Keyboard(connection: connection, ext: ext)
    }

    // MARK: Startup

    /// Takes over the root window. Throws if the server refuses (e.g. another window manager).
    func start() async throws {
        let c = connection
        c.selectInput(root, XEventMask.substructureRedirect | XEventMask.substructureNotify | XEventMask.propertyChange)
        c.compositeRedirectSubwindows(ext, root)
        try await c.sync()

        helperWindow = c.createHelperWindow(parent: root, eventMask: XEventMask.propertyChange)
        let name = Array("AbobaXTerm".utf8)
        c.changeProperty(helperWindow, atoms[.netWMName], type: atoms[.utf8String], format: 8, data: name)
        c.changeProperty(helperWindow, atoms[.netSupportingWMCheck], type: atoms[.window], longs: [helperWindow])
        c.changeProperty(root, atoms[.netSupportingWMCheck], type: atoms[.window], longs: [helperWindow])
        let supported: [XAtom] = [
            .netSupported, .netSupportingWMCheck, .netActiveWindow, .netClientList, .netCloseWindow,
            .netWorkarea, .netNumberOfDesktops, .netCurrentDesktop, .netDesktopGeometry, .netDesktopViewport,
            .netFrameExtents, .netRequestFrameExtents, .netWMName, .netWMState, .netWMStateModal, .netWMStateFocused,
            .netWMStateHidden, .netWMWindowType, .netWMWindowTypeNormal, .netWMWindowTypeDialog,
            .netWMWindowTypeUtility, .netWMWindowTypeSplash, .netWMWindowTypeMenu, .netWMWindowTypeDropdownMenu,
            .netWMWindowTypePopupMenu, .netWMWindowTypeTooltip, .netWMWindowTypeNotification, .netWMWindowTypeCombo,
            .netWMWindowTypeDND,
        ]
        c.changeProperty(root, atoms[.netSupported], type: atoms[.atom], longs: supported.map { atoms[$0] })
        c.changeProperty(root, atoms[.netNumberOfDesktops], type: atoms[.cardinal], longs: [1])
        c.changeProperty(root, atoms[.netCurrentDesktop], type: atoms[.cardinal], longs: [0])
        c.changeProperty(root, atoms[.netDesktopViewport], type: atoms[.cardinal], longs: [0, 0])
        c.changeProperty(root, atoms[.netActiveWindow], type: atoms[.window], longs: [0])
        c.changeProperty(root, atoms[.netClientList], type: atoms[.window], longs: [])
        publishDesktop()
        publishSettings()

        // Plain arrow instead of the server's default "X" cursor.
        c.setWindowCursor(root, cursor: c.createFontCursor(glyph: 68))
        c.xfixesSelectCursorInput(ext, root)
        startClipboard()
        await keyboard.install()

        // Windows that already exist (the app reconnecting to a running server).
        for child in (try? await c.queryTree(root)) ?? [] where !isOwn(child) {
            guard let attributes = try? await c.windowAttributes(child), let (_, g) = try? await c.geometry(child) else { continue }
            let window = track(child, geometry: g, overrideRedirect: attributes.overrideRedirect)
            if attributes.isViewable {
                if attributes.overrideRedirect { await present(window) } else { await manage(window) }
            }
        }
    }

    /// Publishes the desktop size and the area free of menu bar and Dock.
    func publishDesktop() {
        let size = [UInt32(desktop.pixelWidth), UInt32(desktop.pixelHeight)]
        connection.changeProperty(root, atoms[.netDesktopGeometry], type: atoms[.cardinal], longs: size)
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? desktop.frame
        let area = desktop.xRect(for: visible.intersection(desktop.frame))
        connection.changeProperty(root, atoms[.netWorkarea], type: atoms[.cardinal],
                                  longs: [area.x, area.y, area.width, area.height].map { UInt32(max(0, $0)) })
    }

    /// Tells clients the UI scale and font settings (XSETTINGS manager + X resources).
    private func publishSettings() {
        let c = connection
        let scale = max(1, Int(desktop.scale.rounded()))
        let resources = Array(X11Settings.resources(scale: scale).utf8)
        c.changeProperty(root, atoms[.resourceManager], type: atoms[.string], format: 8, data: resources)

        let settings = X11Settings.desktop(scale: scale).encoded(serial: 1)
        c.changeProperty(helperWindow, atoms[.xsettingsSettings], type: atoms[.xsettingsSettings], format: 8, data: settings)
        c.setSelectionOwner(atoms[.xsettingsScreen], owner: helperWindow)
        // Announce the new manager to clients that are already running.
        c.sendClientMessage(to: root, window: root, type: atoms[.manager],
                            data: [0, atoms[.xsettingsScreen], helperWindow], eventMask: XEventMask.structureNotify)
    }

    /// Handles events until the server connection ends.
    func run() async {
        let bases = ext.events
        for await packet in connection.events {
            await handle(XEvent.decode(packet, bases: bases))
        }
        tearDown()
    }

    /// Closes every window (the server went away).
    func tearDown() {
        for window in windows.values {
            window.host?.delegate = nil
            window.host?.close()
            window.host = nil
        }
        windows.removeAll()
        stack.removeAll()
        onChange?()
    }

    // MARK: Events

    private func handle(_ event: XEvent) async {
        switch event {
        case .createNotify(let id, let parent, let geometry, let overrideRedirect):
            guard parent == root, !isOwn(id) else { return }
            track(id, geometry: geometry, overrideRedirect: overrideRedirect)

        case .destroyNotify(let id):
            forget(id)

        case .reparentNotify(let id, let parent):
            if parent != root { forget(id) }

        case .mapRequest(let id, _):
            guard let window = windows[id] else {
                connection.mapWindow(id)
                return
            }
            await manage(window)

        case .mapNotify(let id, let overrideRedirect):
            guard let window = windows[id] else { return }
            window.overrideRedirect = overrideRedirect
            await present(window)

        case .unmapNotify(let id, _):
            guard let window = windows[id] else { return }
            dismiss(window)

        case .configureRequest(let id, let sibling, let stackMode, let geometry, let mask):
            configureRequested(id, geometry: geometry, mask: XConfigureMask(rawValue: mask), sibling: sibling, stackMode: stackMode)

        case .configureNotify(let id, let above, let geometry, let overrideRedirect):
            guard let window = windows[id] else { return }
            restacked(id, above: above)
            window.overrideRedirect = overrideRedirect
            geometryChanged(window, to: geometry)

        case .propertyNotify(let id, let atom, let time, let deleted):
            noteServerTime(time)
            if id == helperWindow {
                await helperPropertyChanged(atom, deleted: deleted)
                return
            }
            guard let window = windows[id], let known = atoms.known(atom), X11WindowProperties.tracked.contains(known) else { return }
            await reloadProperty(known, of: window)

        case .clientMessage(let id, let type, _, let data):
            clientMessage(window: id, type: type, data: data)

        case .damageNotify(let drawable, _, let area):
            guard let window = windows[drawable], window.isMapped else { return }
            window.addDamage(area)
            scheduleFlush(window)

        case .xfixesCursorNotify(let serial, _):
            await cursorChanged(serial: serial)

        case .selectionRequest(let time, _, let requestor, let selection, let target, let property):
            selectionRequested(requestor: requestor, selection: selection, target: target, property: property, time: time)

        case .selectionClear(_, _, let selection):
            selectionCleared(selection: selection)

        case .selectionNotify(_, let requestor, let selection, let target, let property):
            if requestor == helperWindow { await selectionArrived(selection: selection, target: target, property: property) }

        case .xfixesSelectionNotify(let owner, let selection, let time):
            noteServerTime(time)
            selectionOwnerChanged(selection: selection, owner: owner)

        case .mappingNotify, .focusIn, .focusOut, .shapeNotify, .other:
            break
        }
    }

    // MARK: Bookkeeping

    /// Resources created by this connection (helper windows) are not managed.
    func isOwn(_ id: UInt32) -> Bool {
        id & ~connection.setup.resourceIDMask == connection.setup.resourceIDBase
    }

    @discardableResult
    private func track(_ id: UInt32, geometry: XGeometry, overrideRedirect: Bool) -> X11Window {
        if let existing = windows[id] { return existing }
        let window = X11Window(id: id, geometry: geometry, overrideRedirect: overrideRedirect, manager: self)
        windows[id] = window
        stack.append(id)
        connection.selectInput(id, XEventMask.propertyChange)
        return window
    }

    private func forget(_ id: UInt32) {
        guard let window = windows.removeValue(forKey: id) else { return }
        stack.removeAll { $0 == id }
        dismiss(window)
        window.host?.delegate = nil
        window.host?.close()
        window.host = nil
        if focusedWindow == id { focusedWindow = nil }
        publishClientList()
        onChange?()
    }

    private func restacked(_ id: UInt32, above sibling: UInt32) {
        guard let from = stack.firstIndex(of: id) else { return }
        stack.remove(at: from)
        if sibling == 0 {
            stack.insert(id, at: 0)
        } else if let index = stack.firstIndex(of: sibling) {
            stack.insert(id, at: index + 1)
        } else {
            // The sibling is one of the helper windows: keep the old place.
            stack.insert(id, at: min(from, stack.count))
        }
    }

    func publishClientList() {
        let ids = stack.filter { windows[$0]?.isManaged == true }
        connection.changeProperty(root, atoms[.netClientList], type: atoms[.window], longs: ids)
    }

    // MARK: Server time

    /// Remembers a server timestamp so later requests can carry a current one.
    func noteServerTime(_ time: UInt32) {
        guard time != 0 else { return }
        timeBase = (time, ProcessInfo.processInfo.systemUptime)
    }

    /// Estimate of the server clock (never ahead of it), or 0 = CurrentTime.
    var serverTime: UInt32 {
        guard let timeBase else { return 0 }
        let elapsed = ProcessInfo.processInfo.systemUptime - timeBase.local
        return timeBase.server &+ UInt32(max(0, elapsed * 1000))
    }

    // MARK: Client messages

    private func clientMessage(window id: UInt32, type: UInt32, data: [UInt32]) {
        guard let window = windows[id] else { return }
        switch atoms.known(type) {
        case .netActiveWindow:
            activate(window)
        case .netCloseWindow:
            requestClose(window)
        case .wmChangeState where data.first == 3: // IconicState
            window.host?.miniaturize(nil)
        case .netRequestFrameExtents:
            publishFrameExtents(window)
        default:
            break
        }
    }

    // MARK: Debugging

    struct Snapshot: Sendable {
        var id: UInt32
        var title: String
        var geometry: XGeometry
        var isMapped: Bool
        var overrideRedirect: Bool
        var hostFrame: CGRect?
        var png: Data?
    }

    /// State and pixels of every tracked window, bottom-most first.
    func snapshot(includePixels: Bool = true) -> [Snapshot] {
        stack.compactMap { windows[$0] }.map { window in
            var png: Data?
            if includePixels, window.isMapped, let image = window.surface.makeImage() {
                png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            }
            return Snapshot(id: window.id, title: window.properties.title, geometry: window.geometry,
                            isMapped: window.isMapped, overrideRedirect: window.overrideRedirect,
                            hostFrame: window.host?.frame, png: png)
        }
    }
}
