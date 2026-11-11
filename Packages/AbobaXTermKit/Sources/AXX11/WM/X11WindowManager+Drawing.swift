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
        window.pendingDamage = XRect(x: 0, y: 0, width: window.outerSize.width, height: window.outerSize.height)
        scheduleFlush(window)
    }

    func detachContents(_ window: X11Window) {
        if window.damage != 0 { connection.damageDestroy(ext, window.damage) }
        if window.pixmap != 0 { connection.freePixmap(window.pixmap) }
        window.damage = 0
        window.pixmap = 0
        window.pendingDamage = nil
    }

    /// Fetches damaged pixels and shows them. One fetch runs per window at a
    /// time; damage that arrives meanwhile is merged into the next round.
    func scheduleFlush(_ window: X11Window) {
        guard !window.isFlushing else { return }
        window.isFlushing = true
        Task { @MainActor [weak self, weak window] in
            // Let the client finish the frame it is drawing.
            try? await Task.sleep(for: .milliseconds(3))
            while let self, let window, window.isMapped, window.pixmap != 0, let damaged = window.takeDamage() {
                let bounds = XRect(x: 0, y: 0, width: window.outerSize.width, height: window.outerSize.height)
                let rect = damaged.intersection(bounds)
                guard !rect.isEmpty else { continue }
                let pixmap = window.pixmap
                // Clear the server-side record first: drawing after this point is reported again.
                self.connection.damageSubtractAll(self.ext, window.damage)
                guard let data = try? await self.connection.image(pixmap, rect) else {
                    // The pixmap was replaced by a resize; that already queued a full repaint.
                    continue
                }
                guard window.pixmap == pixmap else { continue }
                window.surface.blit(rect, data)
                window.surface.present()
            }
            window?.isFlushing = false
        }
    }

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

    static func cursor(for image: XConnection.CursorImage, scale: CGFloat) -> NSCursor {
        if let native = named[image.name] { return native }
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
