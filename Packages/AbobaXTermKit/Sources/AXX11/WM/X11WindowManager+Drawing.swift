import AppKit

/// Mirroring window pixels (Composite + Damage) and the pointer shape (XFixes).
extension X11WindowManager {
    // MARK: Contents

    /// (Re)binds the window's off-screen pixmap and schedules a full repaint.
    /// Called when the window is mapped and whenever it changes size: the
    /// server allocates a new pixmap then.
    func attachContents(_ window: X11Window) {
        if window.pixmap != 0 { connection.freePixmap(window.pixmap) }
        window.pixmap = connection.compositeNameWindowPixmap(ext, window.id)
        if window.damage == 0 { window.damage = connection.damageCreate(ext, window.id) }
        window.pendingDamage = X11DamageRegion()
        window.addDamage(XRect(x: 0, y: 0, width: window.outerSize.width, height: window.outerSize.height))
        scheduleFlush(window)
    }

    func detachContents(_ window: X11Window) {
        if window.damage != 0 { connection.damageDestroy(ext, window.damage) }
        if window.pixmap != 0 { connection.freePixmap(window.pixmap) }
        window.damage = 0
        window.pixmap = 0
        window.pendingDamage = X11DamageRegion()
    }

    /// Fetches damaged pixels and shows them. One fetch runs per window at a
    /// time; damage that arrives meanwhile is merged into the next round.
    func scheduleFlush(_ window: X11Window) {
        guard !window.isFlushing else { return }
        window.isFlushing = true
        Task { @MainActor [weak self, weak window] in
            // Let the events already received be handled first: one frame of a client
            // usually arrives as several damage events in a row.
            await Task.yield()
            let clock = ContinuousClock()
            while let self, let window, window.isMapped, window.pixmap != 0, !window.pendingDamage.isEmpty {
                // A client that draws faster than the display shows is not followed frame by frame.
                if let last = window.flushedAt, clock.now - last < Self.flushInterval {
                    try? await Task.sleep(for: Self.flushInterval - (clock.now - last), tolerance: .zero)
                    continue
                }
                let bounds = XRect(x: 0, y: 0, width: window.outerSize.width, height: window.outerSize.height)
                let rects = window.pendingDamage.take(clippedTo: bounds)
                guard !rects.isEmpty else { continue }
                let pixmap = window.pixmap
                let arrived = window.damagedAt, started = clock.now
                window.flushedAt = started
                // Clear the server-side record first: drawing after this point is reported again.
                self.connection.damageSubtractAll(self.ext, window.damage)
                var images: [[UInt8]] = []
                for rect in rects {
                    // A failure means the pixmap was replaced by a resize; that already queued a full repaint.
                    guard let data = try? await self.connection.image(pixmap, rect) else { break }
                    images.append(data)
                }
                guard images.count == rects.count, window.pixmap == pixmap else { continue }
                let fetched = clock.now
                for (rect, data) in zip(rects, images) {
                    window.surface.blit(rect, data, offset: XConnection.imageHeader)
                }
                let copied = clock.now
                window.surface.present()
                let shown = clock.now
                self.drawStats.add(pixels: rects.reduce(0) { $0 + $1.width * $1.height },
                                   windowPixels: bounds.width * bounds.height,
                                   waited: started - arrived, fetch: fetched - started, blit: copied - fetched,
                                   present: shown - copied)
            }
            window?.isFlushing = false
        }
    }

    /// Shortest time between two fetches of one window (120 per second).
    static let flushInterval = Duration.milliseconds(8)

    // MARK: Cursor

    /// The pointer shape changed on the X side: show the same one on the Mac.
    func cursorChanged(serial: UInt32) async {
        guard serial != cursorSerial, let image = try? await connection.xfixesCursorImage(ext) else { return }
        cursorSerial = image.serial
        currentCursor = X11CursorMapper.cursor(for: image, scale: desktop.scale)
        // The pointer is global on the X side, so every surface shows the same shape.
        for window in windows.values {
            window.surface.cursor = currentCursor
        }
    }
}

/// Turns X cursor images into NSCursors, preferring the system's own shapes.
@MainActor
enum X11CursorMapper {
    /// Cursor-theme names (as set by toolkits through libXcursor) with a native equivalent.
    private static let named: [String: NSCursor] = [
        "left_ptr": .arrow, "default": .arrow, "arrow": .arrow, "top_left_arrow": .arrow,
        "xterm": .iBeam, "text": .iBeam, "ibeam": .iBeam,
        "hand1": .pointingHand, "hand2": .pointingHand, "pointer": .pointingHand, "pointing_hand": .pointingHand,
        "crosshair": .crosshair, "cross": .crosshair, "tcross": .crosshair,
        "grab": .openHand, "openhand": .openHand, "fleur": .openHand,
        "grabbing": .closedHand, "closedhand": .closedHand,
        "sb_h_double_arrow": .resizeLeftRight, "ew-resize": .resizeLeftRight, "col-resize": .resizeLeftRight,
        "h_double_arrow": .resizeLeftRight, "left_side": .resizeLeftRight, "right_side": .resizeLeftRight,
        "e-resize": .resizeLeftRight, "w-resize": .resizeLeftRight,
        "sb_v_double_arrow": .resizeUpDown, "ns-resize": .resizeUpDown, "row-resize": .resizeUpDown,
        "v_double_arrow": .resizeUpDown, "top_side": .resizeUpDown, "bottom_side": .resizeUpDown,
        "n-resize": .resizeUpDown, "s-resize": .resizeUpDown,
        "not-allowed": .operationNotAllowed, "crossed_circle": .operationNotAllowed, "no-drop": .operationNotAllowed,
        "copy": .dragCopy, "alias": .dragLink, "context-menu": .contextualMenu,
    ]

    /// X pixels per point for a cursor image. Theme cursors follow `Xcursor.size` and
    /// are drawn for the server's scale; cursors from the core "cursor" font and old
    /// bitmap cursors (unnamed, tiny) know nothing about it and would shrink to a speck.
    static func pixelsPerPoint(name: String, width: Int, height: Int, scale: CGFloat) -> CGFloat {
        name.isEmpty && max(width, height) <= 24 ? 1 : scale
    }

    static func cursor(for image: XConnection.CursorImage, scale: CGFloat) -> NSCursor {
        if let native = named[image.name] { return native }
        let scale = pixelsPerPoint(name: image.name, width: image.width, height: image.height, scale: scale)
        guard image.width > 0, image.height > 0, image.pixels.count >= image.width * image.height * 4,
              let provider = CGDataProvider(data: Data(image.pixels) as CFData),
              let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return .arrow }
        // Fully transparent cursors are how clients hide the pointer.
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let picture = NSImage(cgImage: cg, size: size)
        return NSCursor(image: picture, hotSpot: NSPoint(x: CGFloat(image.hotX) / scale, y: CGFloat(image.hotY) / scale))
    }
}

/// Where the time of mirroring window contents goes (read by the harness's `stats` step).
struct X11DrawStats {
    private(set) var rounds = 0
    private(set) var pixels = 0
    private(set) var windowPixels = 0
    private(set) var waited = Duration.zero
    private(set) var fetch = Duration.zero
    private(set) var blit = Duration.zero
    private(set) var present = Duration.zero
    private(set) var worst = Duration.zero

    mutating func add(pixels: Int, windowPixels: Int, waited: Duration, fetch: Duration, blit: Duration, present: Duration) {
        rounds += 1
        self.pixels += pixels
        self.windowPixels += windowPixels
        self.waited += waited
        self.fetch += fetch
        self.blit += blit
        self.present += present
        worst = max(worst, waited + fetch + blit + present)
    }

    var summary: String {
        guard rounds > 0 else { return "no frames" }
        func ms(_ d: Duration) -> String {
            let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            return String(format: "%.2f", seconds * 1000 / Double(rounds))
        }
        let total = waited + fetch + blit + present
        let share = windowPixels > 0 ? 100 * pixels / windowPixels : 0
        let megabytes = String(format: "%.1f", Double(pixels) * 4 / 1_048_576 / Double(rounds))
        return "frames=\(rounds) avg ms: total=\(ms(total)) wait=\(ms(waited)) fetch=\(ms(fetch)) blit=\(ms(blit)) "
            + "present=\(ms(present)); worst=\(String(format: "%.1f", Double(worst.components.attoseconds) / 1e15 + Double(worst.components.seconds) * 1000)) ms; "
            + "fetched \(megabytes) MB/frame, \(share)% of the window"
    }
}
