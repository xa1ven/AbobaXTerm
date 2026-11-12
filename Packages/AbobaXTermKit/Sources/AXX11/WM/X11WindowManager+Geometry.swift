import AppKit

/// Geometry, stacking and focus: kept in sync between X and the Mac windows.
///
/// For managed windows the Mac window is the authority on position (the user
/// drags it); the server is told. Sizes can change from either side.
/// Override-redirect windows (menus, tooltips) place themselves.
extension X11WindowManager {
    // MARK: X -> Mac

    /// A client wants to move, resize or restack one of its windows.
    func configureRequested(_ id: UInt32, geometry requested: XGeometry, mask: XConfigureMask, sibling: UInt32, stackMode: UInt8) {
        guard let window = windows[id], window.isManaged else {
            // Not shown yet: let the client set things up as it likes.
            connection.configureWindow(id, mask: mask, geometry: requested, sibling: sibling, stackMode: stackMode)
            return
        }
        var target = window.geometry
        if mask.contains(.x) { target.x = requested.x }
        if mask.contains(.y) { target.y = requested.y }
        if mask.contains(.width) { target.width = requested.width }
        if mask.contains(.height) { target.height = requested.height }
        target.border = 0

        if let host = window.host, !mask.isDisjoint(with: [.x, .y, .width, .height]) {
            // Let AppKit apply its own constraints (menu bar, size limits), then report what it allowed.
            window.isApplyingGeometry = true
            var rect = desktop.contentRect(for: target)
            if mask.isDisjoint(with: [.x, .y]) {
                // Resize only: keep the top-left corner where the user has it.
                let current = host.contentRect(forFrameRect: host.frame)
                rect.origin = CGPoint(x: current.minX, y: current.maxY - rect.height)
            }
            host.setFrame(host.frameRect(forContentRect: rect), display: true)
            window.isApplyingGeometry = false
            target = desktop.geometry(forContentRect: host.contentRect(forFrameRect: host.frame))
        }

        if target == window.geometry {
            // ICCCM: a request that changes nothing still gets an answer.
            sendSyntheticConfigure(window)
        } else {
            connection.configureWindow(id, mask: [.x, .y, .width, .height, .border], geometry: target)
            window.sentGeometry = target
        }
        if mask.contains(.stackMode), stackMode == 0, presentsWindows == false {
            connection.raiseWindow(id)
        }
    }

    private func sendSyntheticConfigure(_ window: X11Window) {
        let g = window.geometry
        var w = ByteWriter()
        w.u8(22); w.u8(0); w.u16(0)
        w.u32(window.id); w.u32(window.id); w.u32(0)
        w.i16(Int16(clamping: g.x)); w.i16(Int16(clamping: g.y))
        w.u16(UInt16(clamping: g.width)); w.u16(UInt16(clamping: g.height))
        w.u16(0); w.u8(0); w.u8(0)
        w.zeros(4)
        connection.sendEvent(to: window.id, eventMask: XEventMask.structureNotify, event: w.bytes)
    }

    /// The server reports a window's new position or size.
    func geometryChanged(_ window: X11Window, to geometry: XGeometry) {
        let resized = geometry.width != window.geometry.width || geometry.height != window.geometry.height
            || geometry.border != window.geometry.border
        window.geometry = geometry
        guard window.isMapped else { return }
        if resized {
            window.surface.resizeBuffer(width: window.outerSize.width, height: window.outerSize.height)
            attachContents(window)
        }
        if window.overrideRedirect || resized { applyHostFrame(window) }
    }

    /// Moves/resizes the Mac window to match the X geometry.
    func applyHostFrame(_ window: X11Window) {
        guard let host = window.host else { return }
        var content = desktop.contentRect(for: window.geometry)
        if !window.overrideRedirect, host.isVisible {
            // Managed windows stay where the user put them; only the size follows X.
            let current = host.contentRect(forFrameRect: host.frame)
            content.origin = CGPoint(x: current.minX, y: current.maxY - content.height)
        }
        let frame = host.frameRect(forContentRect: content)
        guard frame != host.frame else { return }
        window.isApplyingGeometry = true
        host.setFrame(frame, display: true)
        window.isApplyingGeometry = false
        if !window.overrideRedirect { hostGeometryChanged(window) }
    }

    // MARK: Mac -> X

    /// The Mac window was moved or resized (by the user or by AppKit).
    func hostGeometryChanged(_ window: X11Window) {
        guard let host = window.host, !window.overrideRedirect, window.isMapped, !window.isApplyingGeometry else { return }
        var target = desktop.geometry(forContentRect: host.contentRect(forFrameRect: host.frame))
        target.border = 0
        guard target != window.geometry, target != window.sentGeometry else { return }
        window.sentGeometry = target
        connection.configureWindow(window.id, mask: [.x, .y, .width, .height], geometry: target)
    }

    // MARK: Screens

    /// Makes sure the root window lies under `window`, so the X pointer can
    /// reach it and its menus open next to it.
    ///
    /// The root is as large as the screens were when the server started. A
    /// window on a screen connected later (or rearranged) is outside it; the
    /// root is then laid over that window instead, and every X window is told
    /// its new root position. Nothing moves on the Mac.
    func ensureReachable(_ window: X11Window) {
        guard presentsWindows, !window.overrideRedirect, window.isMapped, let host = window.host, host.isVisible,
              !host.isMiniaturized else { return }
        let content = host.contentRect(forFrameRect: host.frame)
        // Only the part on screen matters (windows may hang over a screen edge).
        let screens = NSScreen.screens.map(\.frame)
        let onScreen = screens.map { $0.intersection(content) }.filter { !$0.isEmpty }
        guard let first = onScreen.first else { return }
        let needed = onScreen.dropFirst().reduce(first) { $0.union($1) }
        guard !desktop.reaches(needed) else { return }
        moveRoot(to: desktop.recentered(on: needed))
    }

    /// The pointer is about to go to a root position outside the root window
    /// (`window` is larger than the root, or was just dragged away): lay the
    /// root under the pointer. Returns false if the position was fine.
    func bringRoot(under position: (x: Int, y: Int), in window: X11Window) -> Bool {
        guard presentsWindows, window.host?.isVisible == true,
              !(0..<desktop.pixelWidth).contains(position.x) || !(0..<desktop.pixelHeight).contains(position.y) else { return false }
        let spot = CGRect(x: desktop.frame.minX + CGFloat(position.x) / desktop.scale,
                          y: desktop.frame.maxY - CGFloat(position.y) / desktop.scale, width: 0, height: 0)
        let before = desktop
        ensureReachable(window)
        let x = (spot.minX - desktop.frame.minX) * desktop.scale, y = (desktop.frame.maxY - spot.minY) * desktop.scale
        if desktop == before || !(0..<CGFloat(desktop.pixelWidth)).contains(x) || !(0..<CGFloat(desktop.pixelHeight)).contains(y) {
            moveRoot(to: desktop.recentered(on: spot))
        }
        return true
    }

    /// Lays the root window over another part of the Mac desktop and gives
    /// every X window its new root position. Nothing moves on screen.
    func moveRoot(to target: X11Desktop) {
        let dx = Int(((desktop.frame.minX - target.frame.minX) * desktop.scale).rounded())
        let dy = Int(((target.frame.maxY - desktop.frame.maxY) * desktop.scale).rounded())
        guard dx != 0 || dy != 0 else { return }
        desktop = target
        rootHasMoved = true
        if let old = pointer { pointer = (old.x + dx, old.y + dy) }
        for window in windows.values where window.isMapped {
            var moved = window.geometry
            moved.x += dx
            moved.y += dy
            connection.configureWindow(window.id, mask: [.x, .y], geometry: moved)
            if !window.overrideRedirect { window.sentGeometry = moved }
            // Pointer positions are computed from this before the server confirms.
            window.geometry = moved
        }
        publishWorkarea()
    }

    /// The screens changed while windows are open (the root keeps its size
    /// until the server can restart): bring back windows left off screen and
    /// tell clients the new free area.
    func screensChanged() {
        guard presentsWindows else { return }
        let screens = NSScreen.screens
        guard let home = NSScreen.main ?? screens.first else { return }
        for window in windows.values where !window.overrideRedirect {
            guard let host = window.host, host.isVisible, !host.isMiniaturized else { continue }
            // Reachable means: enough of the title bar is on some screen to grab it.
            let grip = CGRect(x: host.frame.minX, y: host.frame.maxY - 30, width: host.frame.width, height: 30)
            let visible = screens.contains { screen in
                let part = screen.visibleFrame.intersection(grip)
                return part.width >= 60 && part.height >= 15
            }
            guard !visible else { continue }
            var frame = host.frame
            let area = home.visibleFrame
            frame.origin.x = min(max(area.midX - frame.width / 2, area.minX), max(area.minX, area.maxX - frame.width))
            frame.origin.y = max(area.minY, min(area.maxY - frame.height, area.midY - frame.height / 2))
            if frame.height > area.height { frame.origin.y = area.maxY - frame.height }
            host.setFrame(frame, display: true)
        }
        if let id = focusedWindow, let window = windows[id] { ensureReachable(window) }
        publishWorkarea()
    }

    // MARK: Stacking

    /// Restacks the X windows like the Mac windows on screen, so the pointer
    /// hits the window the user actually sees under it.
    func syncStackingFromScreen() {
        guard presentsWindows else { return }
        var byNumber: [Int: UInt32] = [:]
        for window in windows.values where window.isMapped {
            if let host = window.host, host.isVisible { byNumber[host.windowNumber] = window.id }
        }
        guard byNumber.count > 1 else { return }
        // Front-to-back on screen -> bottom-to-top for X.
        let desired = Array((NSWindow.windowNumbers(options: []) ?? []).compactMap { byNumber[$0.intValue] }.reversed())
        let current = stack.filter { desired.contains($0) }
        guard desired != current, desired.count > 1 else { return }
        for index in 1..<desired.count {
            connection.raiseWindow(desired[index], above: desired[index - 1])
        }
        // Keep the local view current until the ConfigureNotify events arrive.
        let others = stack.filter { !desired.contains($0) }
        stack = others + desired
    }

    // MARK: Focus

    func hostBecameKey(_ window: X11Window) {
        ensureReachable(window)
        syncStackingFromScreen()
        giveFocus(to: window)
        publishWorkarea()
        keyboard.syncModifiers(NSEvent.modifierFlags)
        offerPasteboard()
    }

    func hostResignedKey(_ window: X11Window) {
        keyboard.releaseAll()
        // Another X window may be taking over; decide once AppKit has settled.
        DispatchQueue.main.async { [weak self] in
            guard let self, !(NSApp.keyWindow is X11HostWindow), self.focusedWindow == window.id else { return }
            self.dismissMenus()
            self.dropFocus()
        }
    }

    /// Open menus hold a grab and would stay up after the user clicked
    /// elsewhere on the Mac: close them the way the user would, with Escape
    /// (one per menu level).
    func dismissMenus() {
        let open = windows.values.filter { $0.isMapped && $0.overrideRedirect && $0.properties.kind == .menu }.count
        for _ in 0..<open { keyboard.tap(keyCode: 53) }
    }

    /// Gives X keyboard focus according to the client's ICCCM input model.
    func giveFocus(to window: X11Window) {
        guard window.isMapped, !window.overrideRedirect else { return }
        if window.properties.acceptsInput {
            connection.setInputFocus(window.id, revertTo: 1, time: 0)
        }
        if window.properties.supportsTakeFocus {
            connection.sendClientMessage(to: window.id, window: window.id, type: atoms[.wmProtocols],
                                         data: [atoms[.wmTakeFocus], serverTime])
        }
        focusedWindow = window.id
        connection.changeProperty(root, atoms[.netActiveWindow], type: atoms[.window], longs: [window.id])
    }

    /// No X window has the keyboard (the user works in another Mac window or app).
    func dropFocus() {
        focusedWindow = nil
        connection.setInputFocus(0, revertTo: 0, time: 0)
        connection.changeProperty(root, atoms[.netActiveWindow], type: atoms[.window], longs: [0])
    }

    /// A client asked for one of its windows to come forward (_NET_ACTIVE_WINDOW).
    func activate(_ window: X11Window) {
        guard window.isMapped else { return }
        if let host = window.host {
            if host.isMiniaturized { host.deminiaturize(nil) }
            host.makeKeyAndOrderFront(nil)
        } else {
            connection.raiseWindow(window.id)
            giveFocus(to: window)
        }
    }
}
