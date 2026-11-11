import AppKit

/// NSWindow that hosts a regular (window-manager managed) X window.
final class X11HostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Borderless panel for override-redirect X windows: menus, tooltips, combo
/// popups. It never takes keyboard focus; the client grabs input on the X side.
final class X11PopupPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One top-level X window and the Mac window that shows it.
@MainActor
final class X11Window: NSObject, NSWindowDelegate {
    let id: UInt32
    weak var manager: X11WindowManager?

    /// Position (root-relative) and size as last reported by the server.
    var geometry: XGeometry
    var overrideRedirect: Bool
    var isMapped = false
    /// True once the window went through MapRequest and got ICCCM state.
    var isManaged = false
    var properties = X11WindowProperties()
    var depth: UInt8 = 24

    // Off-screen contents.
    var damage: UInt32 = 0
    var pixmap: UInt32 = 0
    var pendingDamage: XRect?
    var isFlushing = false

    let surface: X11SurfaceView
    var host: NSWindow?
    /// Geometry last sent to the server from the Mac side (avoids echoing).
    var sentGeometry: XGeometry?
    /// True while the app itself moves or resizes `host`.
    var isApplyingGeometry = false

    init(id: UInt32, geometry: XGeometry, overrideRedirect: Bool, manager: X11WindowManager) {
        self.id = id
        self.geometry = geometry
        self.overrideRedirect = overrideRedirect
        self.manager = manager
        self.surface = X11SurfaceView(windowID: id)
        super.init()
        surface.input = manager
    }

    /// Size of the off-screen pixmap: the window plus its border on each side.
    var outerSize: (width: Int, height: Int) {
        (geometry.width + 2 * geometry.border, geometry.height + 2 * geometry.border)
    }

    func addDamage(_ rect: XRect) {
        pendingDamage = pendingDamage?.union(rect) ?? rect
    }

    func takeDamage() -> XRect? {
        defer { pendingDamage = nil }
        return pendingDamage
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        manager?.requestClose(self)
        return false
    }

    func windowDidResize(_ notification: Notification) { manager?.hostGeometryChanged(self) }
    func windowDidMove(_ notification: Notification) { manager?.hostGeometryChanged(self) }
    func windowDidChangeScreen(_ notification: Notification) { manager?.hostGeometryChanged(self) }
    func windowDidBecomeKey(_ notification: Notification) { manager?.hostBecameKey(self) }
    func windowDidResignKey(_ notification: Notification) { manager?.hostResignedKey(self) }
    func windowDidEndLiveResize(_ notification: Notification) { manager?.hostGeometryChanged(self) }
}
