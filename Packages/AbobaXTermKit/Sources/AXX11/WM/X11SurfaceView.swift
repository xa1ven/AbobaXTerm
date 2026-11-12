import AppKit
import IOSurface

/// Receives input from a surface view (implemented by the window manager).
@MainActor
protocol X11SurfaceInput: AnyObject {
    /// `point` is in X pixels relative to the window's top-left corner.
    func surface(_ view: X11SurfaceView, pointerAt point: CGPoint)
    func surface(_ view: X11SurfaceView, button: Int, pressed: Bool, at point: CGPoint)
    func surface(_ view: X11SurfaceView, scrollBy delta: CGSize, precise: Bool, at point: CGPoint)
    func surface(_ view: X11SurfaceView, key event: NSEvent, pressed: Bool)
    /// A Command combination, before the app's menus see it. True if it was consumed.
    func surface(_ view: X11SurfaceView, shortcut event: NSEvent) -> Bool
    /// Edit menu items (Copy, Paste and so on) for the window's program.
    func surface(_ view: X11SurfaceView, canPerform command: X11EditCommand) -> Bool
    func surface(_ view: X11SurfaceView, perform command: X11EditCommand)
    func surface(_ view: X11SurfaceView, modifiersChanged event: NSEvent)
    func surfacePointerEntered(_ view: X11SurfaceView)
}

/// Shows the pixels of one X window and forwards mouse and keyboard to it.
///
/// The pixel buffer mirrors the window's off-screen pixmap: damaged
/// rectangles are copied in with `blit`, then `present` copies what changed
/// into the back one of two IOSurfaces and shows it. The window server reads
/// a surface directly, so a frame costs only its damaged pixels; a CGImage as
/// layer contents is copied and colour-matched whole on every change.
final class X11SurfaceView: NSView {
    weak var input: X11SurfaceInput?
    /// X id of the window this view shows.
    let windowID: UInt32
    /// X pixels per point.
    var scale: CGFloat = 1 { didSet { layoutSurface() } }
    /// Depth-32 windows carry premultiplied alpha.
    var hasAlpha = false
    var cursor: NSCursor = .arrow { didSet { if cursor !== oldValue { window?.invalidateCursorRects(for: self) } } }

    private(set) var pixelWidth = 0
    private(set) var pixelHeight = 0
    /// Only touched on the main thread; `deinit` frees it.
    nonisolated(unsafe) private var pixels: UnsafeMutablePointer<UInt8>?
    private let surfaceLayer = CALayer()
    private var tracking: NSTrackingArea?
    private var dirty = false
    /// Front and back surface, swapped by `present`.
    private var surfaces: [IOSurface] = []
    /// Per surface: the area where it differs from `pixels`.
    private var stale = [XRect(x: 0, y: 0, width: 0, height: 0), XRect(x: 0, y: 0, width: 0, height: 0)]
    private var front = 0

    init(windowID: UInt32) {
        self.windowID = windowID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        surfaceLayer.anchorPoint = .zero
        surfaceLayer.magnificationFilter = .nearest
        surfaceLayer.minificationFilter = .linear
        surfaceLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(surfaceLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { pixels?.deallocate() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { !hasAlpha }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Pixels

    /// Reallocates the buffer for a new window size, keeping the overlapping part.
    func resizeBuffer(width: Int, height: Int) {
        guard width != pixelWidth || height != pixelHeight, width > 0, height > 0 else { return }
        let fresh = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
        fresh.initialize(repeating: hasAlpha ? 0 : 0xFF, count: width * height * 4)
        if let old = pixels {
            let rows = min(height, pixelHeight), bytes = min(width, pixelWidth) * 4
            for row in 0..<rows {
                memcpy(fresh + row * width * 4, old + row * pixelWidth * 4, bytes)
            }
            old.deallocate()
        }
        pixels = fresh
        pixelWidth = width
        pixelHeight = height
        dirty = true
        surfaces = (0..<2).compactMap { _ in Self.makeSurface(width: width, height: height) }
        stale = [XRect(x: 0, y: 0, width: width, height: height), XRect(x: 0, y: 0, width: width, height: height)]
        surfaceLayer.isOpaque = !hasAlpha
        layoutSurface()
    }

    /// Copies a rectangle of 32-bit pixels (as returned by GetImage) into the buffer.
    /// The pixels start `offset` bytes into `data`.
    func blit(_ rect: XRect, _ data: [UInt8], offset: Int = 0) {
        guard let pixels else { return }
        let clipped = rect.intersection(XRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard !clipped.isEmpty, data.count >= offset + rect.width * rect.height * 4 else { return }
        data.withUnsafeBytes { source in
            guard let base = source.baseAddress.map({ $0 + offset }) else { return }
            for row in 0..<clipped.height {
                let from = base + ((clipped.y - rect.y + row) * rect.width + (clipped.x - rect.x)) * 4
                let to = pixels + ((clipped.y + row) * pixelWidth + clipped.x) * 4
                memcpy(to, from, clipped.width * 4)
                if !hasAlpha {
                    // The unused byte of depth-24 pixels is the surface's alpha.
                    let words = UnsafeMutableRawPointer(to).assumingMemoryBound(to: UInt32.self)
                    for column in 0..<clipped.width { words[column] |= 0xFF00_0000 }
                }
            }
        }
        for index in stale.indices { stale[index] = stale[index].union(clipped) }
        dirty = true
    }

    /// Shows the current buffer contents.
    func present() {
        guard dirty, let pixels else { return }
        guard surfaces.count == 2 else {
            // No surfaces (allocation failed): fall back to a copied image.
            dirty = false
            surfaceLayer.contents = makeImage()
            return
        }
        dirty = false
        let back = 1 - front
        let surface = surfaces[back]
        let rect = stale[back].intersection(XRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        if !rect.isEmpty {
            surface.lock(options: [], seed: nil)
            let stride = surface.bytesPerRow
            for row in rect.y..<rect.maxY {
                memcpy(surface.baseAddress + row * stride + rect.x * 4, pixels + (row * pixelWidth + rect.x) * 4, rect.width * 4)
            }
            surface.unlock(options: [], seed: nil)
        }
        stale[back] = XRect(x: 0, y: 0, width: 0, height: 0)
        front = back
        surfaceLayer.contents = surface
    }

    /// The pixel (BGRA, as a little-endian word) on screen at `x`,`y`: read from the
    /// surface being shown, not from the buffer (for tests).
    func shownPixel(x: Int, y: Int) -> UInt32? {
        guard surfaces.count == 2, x >= 0, y >= 0, x < pixelWidth, y < pixelHeight else { return nil }
        let surface = surfaces[front]
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        return (surface.baseAddress + y * surface.bytesPerRow + x * 4).loadUnaligned(as: UInt32.self)
    }

    private static func makeSurface(width: Int, height: Int) -> IOSurface? {
        guard let surface = IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA,
        ]) else { return nil }
        if let space = CGColorSpace(name: CGColorSpace.sRGB), let profile = space.copyPropertyList() {
            IOSurfaceSetValue(unsafeBitCast(surface, to: IOSurfaceRef.self), kIOSurfaceColorSpace, profile)
        }
        return surface
    }

    /// Snapshot of the buffer (also used for debugging dumps).
    func makeImage() -> CGImage? {
        guard let pixels, pixelWidth > 0, pixelHeight > 0 else { return nil }
        let data = Data(bytes: pixels, count: pixelWidth * pixelHeight * 4) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        let alpha: CGImageAlphaInfo = hasAlpha ? .premultipliedFirst : .noneSkipFirst
        return CGImage(width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: pixelWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    override func layout() {
        super.layout()
        layoutSurface()
    }

    /// Keeps the image at natural size in the view's top-left corner, so a
    /// live resize reveals background instead of stretching stale pixels.
    private func layoutSurface() {
        let size = CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
        // The backing layer of a flipped view has its origin at the top-left.
        let flippedLayer = layer?.isGeometryFlipped ?? false
        let y = flippedLayer ? 0 : bounds.height - size.height
        surfaceLayer.frame = CGRect(origin: CGPoint(x: 0, y: y), size: size)
        surfaceLayer.isGeometryFlipped = false
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }

    private func point(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: (local.x * scale).rounded(.down), y: (local.y * scale).rounded(.down))
    }

    override func mouseEntered(with event: NSEvent) {
        input?.surfacePointerEntered(self)
        input?.surface(self, pointerAt: point(event))
    }

    override func mouseExited(with event: NSEvent) { input?.surface(self, pointerAt: point(event)) }
    override func mouseMoved(with event: NSEvent) { input?.surface(self, pointerAt: point(event)) }
    override func mouseDragged(with event: NSEvent) { input?.surface(self, pointerAt: point(event)) }
    override func rightMouseDragged(with event: NSEvent) { input?.surface(self, pointerAt: point(event)) }
    override func otherMouseDragged(with event: NSEvent) { input?.surface(self, pointerAt: point(event)) }

    override func mouseDown(with event: NSEvent) { input?.surface(self, button: 1, pressed: true, at: point(event)) }
    override func mouseUp(with event: NSEvent) { input?.surface(self, button: 1, pressed: false, at: point(event)) }
    override func rightMouseDown(with event: NSEvent) { input?.surface(self, button: 3, pressed: true, at: point(event)) }
    override func rightMouseUp(with event: NSEvent) { input?.surface(self, button: 3, pressed: false, at: point(event)) }

    override func otherMouseDown(with event: NSEvent) {
        input?.surface(self, button: Self.xButton(event.buttonNumber), pressed: true, at: point(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        input?.surface(self, button: Self.xButton(event.buttonNumber), pressed: false, at: point(event))
    }

    override func scrollWheel(with event: NSEvent) {
        input?.surface(self, scrollBy: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
                       precise: event.hasPreciseScrollingDeltas, at: point(event))
    }

    /// Cocoa button 2 is the middle button (X button 2); 3 and 4 are back/forward (X 8 and 9).
    private static func xButton(_ cocoa: Int) -> Int {
        switch cocoa {
        case 2: 2
        case 3: 8
        case 4: 9
        default: 2
        }
    }

    // MARK: Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Copy, paste and the like belong to the X program, not to the app's Edit menu.
        if event.type == .keyDown, let window, window.isKeyWindow, window.firstResponder === self,
           input?.surface(self, shortcut: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) { input?.surface(self, key: event, pressed: true) }
    override func keyUp(with event: NSEvent) { input?.surface(self, key: event, pressed: false) }
    override func flagsChanged(with event: NSEvent) { input?.surface(self, modifiersChanged: event) }

    // MARK: Edit menu

    @objc func undo(_ sender: Any?) { edit(.undo) }
    @objc func cut(_ sender: Any?) { edit(.cut) }
    @objc func copy(_ sender: Any?) { edit(.copy) }
    @objc func paste(_ sender: Any?) { edit(.paste) }
    override func selectAll(_ sender: Any?) { edit(.selectAll) }

    private func edit(_ command: X11EditCommand) {
        // The menu's key equivalent fired, so `performKeyEquivalent` declined it:
        // Command shortcuts are not being translated and the key belongs to the program.
        if let event = NSApp.currentEvent, event.type == .keyDown, event.modifierFlags.contains(.command) {
            input?.surface(self, key: event, pressed: true)
            return
        }
        input?.surface(self, perform: command)
    }

    private static let editCommands: [Selector: X11EditCommand] = [
        #selector(undo(_:)): .undo, #selector(cut(_:)): .cut, #selector(copy(_:)): .copy,
        #selector(paste(_:)): .paste, #selector(selectAll(_:)): .selectAll,
    ]
}

extension X11SurfaceView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action, let command = Self.editCommands[action] else { return true }
        return input?.surface(self, canPerform: command) ?? false
    }
}
