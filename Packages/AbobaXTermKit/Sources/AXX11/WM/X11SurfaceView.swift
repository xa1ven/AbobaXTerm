import AppKit

/// Receives input from a surface view (implemented by the window manager).
@MainActor
protocol X11SurfaceInput: AnyObject {
    /// `point` is in X pixels relative to the window's top-left corner.
    func surface(_ view: X11SurfaceView, pointerAt point: CGPoint)
    func surface(_ view: X11SurfaceView, button: Int, pressed: Bool, at point: CGPoint)
    func surface(_ view: X11SurfaceView, scrollBy delta: CGSize, precise: Bool, at point: CGPoint)
    func surface(_ view: X11SurfaceView, key event: NSEvent, pressed: Bool)
    func surface(_ view: X11SurfaceView, modifiersChanged event: NSEvent)
    func surfacePointerEntered(_ view: X11SurfaceView)
}

/// Shows the pixels of one X window and forwards mouse and keyboard to it.
///
/// The pixel buffer mirrors the window's off-screen pixmap: damaged
/// rectangles are copied in with `blit`, then `present` hands the result to
/// Core Animation.
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
        layoutSurface()
    }

    /// Copies a rectangle of 32-bit pixels (as returned by GetImage) into the buffer.
    func blit(_ rect: XRect, _ data: [UInt8]) {
        guard let pixels else { return }
        let clipped = rect.intersection(XRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard !clipped.isEmpty, data.count >= rect.width * rect.height * 4 else { return }
        data.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            for row in 0..<clipped.height {
                let from = base + ((clipped.y - rect.y + row) * rect.width + (clipped.x - rect.x)) * 4
                memcpy(pixels + ((clipped.y + row) * pixelWidth + clipped.x) * 4, from, clipped.width * 4)
            }
        }
        dirty = true
    }

    /// Shows the current buffer contents.
    func present() {
        guard dirty, let image = makeImage() else { return }
        dirty = false
        surfaceLayer.contents = image
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

    override func keyDown(with event: NSEvent) { input?.surface(self, key: event, pressed: true) }
    override func keyUp(with event: NSEvent) { input?.surface(self, key: event, pressed: false) }
    override func flagsChanged(with event: NSEvent) { input?.surface(self, modifiersChanged: event) }
}
