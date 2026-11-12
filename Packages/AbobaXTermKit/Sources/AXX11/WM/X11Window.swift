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
    /// The program's own icon (_NET_WM_ICON), if it set one.
    var icon: NSImage?

    // Off-screen contents.
    var damage: UInt32 = 0
    var pixmap: UInt32 = 0
    var pendingDamage = X11DamageRegion()
    var isFlushing = false
    /// When the previous round of fetching damage started (paces fast-drawing clients).
    var flushedAt: ContinuousClock.Instant?
    /// When the oldest damage not yet shown arrived (for draw statistics).
    var damagedAt: ContinuousClock.Instant = .now

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
        if pendingDamage.isEmpty { damagedAt = .now }
        pendingDamage.add(rect)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        manager?.requestClose(self)
        return false
    }

    func windowDidResize(_ notification: Notification) { manager?.hostGeometryChanged(self) }
    func windowDidMove(_ notification: Notification) { manager?.hostGeometryChanged(self) }
    func windowDidChangeScreen(_ notification: Notification) {
        manager?.hostGeometryChanged(self)
        manager?.publishWorkarea()
    }
    func windowWillMiniaturize(_ notification: Notification) { manager?.hostWillMiniaturize(self) }
    func windowDidBecomeKey(_ notification: Notification) { manager?.hostBecameKey(self) }
    func windowDidResignKey(_ notification: Notification) { manager?.hostResignedKey(self) }
    func windowDidEndLiveResize(_ notification: Notification) { manager?.hostGeometryChanged(self) }
}

/// Damaged parts of a window waiting to be fetched: a few rectangles rather than
/// one bounding box, so a spinner in one corner and a clock in another do not
/// cost everything in between.
struct X11DamageRegion: Equatable {
    static let limit = 8
    private(set) var rects: [XRect] = []

    var isEmpty: Bool { rects.isEmpty }

    mutating func add(_ rect: XRect) {
        guard !rect.isEmpty else { return }
        var merged = rect
        var index = 0
        while index < rects.count {
            let other = rects[index]
            let union = merged.union(other)
            // Merge when one fetch of the union costs about the same as two fetches.
            if union.width * union.height <= (merged.width * merged.height + other.width * other.height) * 5 / 4 {
                merged = union
                rects.remove(at: index)
                index = 0
            } else {
                index += 1
            }
        }
        rects.append(merged)
        if rects.count > Self.limit {
            rects = [rects.dropFirst().reduce(rects[0]) { $0.union($1) }]
        }
    }

    /// Returns the rectangles clipped to `bounds` and empties the region.
    mutating func take(clippedTo bounds: XRect) -> [XRect] {
        defer { rects = [] }
        return rects.map { $0.intersection(bounds) }.filter { !$0.isEmpty }
    }
}
