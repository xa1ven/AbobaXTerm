import AppKit

/// Managing, showing and hiding windows.
extension X11WindowManager {
    // MARK: Managing (MapRequest)

    /// A client asked to show a regular window: read its properties, place it and map it.
    func manage(_ window: X11Window) async {
        for atom in X11WindowProperties.tracked {
            let value = try? await connection.property(window.id, atoms[atom])
            window.properties.apply(atom, value, atoms: atoms)
        }
        // The window may have been destroyed while its properties were read.
        guard windows[window.id] === window else { return }

        var geometry = window.geometry
        geometry.border = 0
        let placed = initialContentRect(for: window)
        let position = desktop.geometry(forContentRect: placed)
        geometry.x = position.x
        geometry.y = position.y
        connection.configureWindow(window.id, mask: [.x, .y, .width, .height, .border], geometry: geometry)
        window.sentGeometry = geometry

        window.isManaged = true
        setWMState(window, normal: true)
        publishFrameExtents(window)
        publishClientList()
        connection.mapWindow(window.id)
        await reloadIcon(of: window)
    }

    /// Where a new managed window goes, as a Cocoa content rectangle.
    private func initialContentRect(for window: X11Window) -> CGRect {
        let size = CGSize(width: CGFloat(window.geometry.width) / desktop.scale,
                          height: CGFloat(window.geometry.height) / desktop.scale)
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? desktop.frame
        let titleBar = window.properties.wantsDecorations ? Self.titleBarHeight : 0

        var rect: CGRect
        if let host = window.host {
            // Shown before (the client hid it and shows it again): same place, possibly a new size.
            let previous = host.contentRect(forFrameRect: host.frame)
            return CGRect(x: previous.minX, y: previous.maxY - size.height, width: size.width, height: size.height)
        } else if window.properties.sizeHints.hasPosition, window.geometry.x != 0 || window.geometry.y != 0 {
            // The client (or its user, via -geometry) chose the position.
            rect = desktop.contentRect(for: window.geometry)
        } else if let parentID = window.properties.transientFor, let parent = windows[parentID], parent.isMapped {
            // Dialogs go over their parent.
            let over = parent.host.map { $0.contentRect(forFrameRect: $0.frame) } ?? desktop.contentRect(for: parent.geometry)
            rect = CGRect(x: over.midX - size.width / 2, y: over.midY - size.height / 2 + 20, width: size.width, height: size.height)
        } else if let point = cascadePoint, visible.contains(CGPoint(x: point.x + 40, y: point.y - 40)) {
            rect = CGRect(x: point.x, y: point.y - size.height, width: size.width, height: size.height)
        } else {
            rect = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height * 0.08,
                          width: size.width, height: size.height)
        }
        // Keep the title bar reachable.
        rect.origin.x = min(max(rect.minX, visible.minX), max(visible.minX, visible.maxX - min(size.width, 120)))
        let top = min(rect.maxY, visible.maxY - titleBar)
        rect.origin.y = max(top, visible.minY + min(size.height, 80)) - size.height
        if window.properties.transientFor == nil {
            cascadePoint = CGPoint(x: rect.minX + 26, y: rect.maxY - 26)
        }
        return rect
    }

    static let titleBarHeight: CGFloat = {
        let content = CGRect(x: 0, y: 0, width: 200, height: 200)
        return NSWindow.frameRect(forContentRect: content, styleMask: [.titled]).height - content.height
    }()

    func setWMState(_ window: X11Window, normal: Bool) {
        // WM_STATE: state (1 Normal, 0 Withdrawn) and icon window.
        connection.changeProperty(window.id, atoms[.wmState], type: atoms[.wmState], longs: [normal ? 1 : 0, 0])
    }

    func publishFrameExtents(_ window: X11Window) {
        let top = window.properties.wantsDecorations ? UInt32((Self.titleBarHeight * desktop.scale).rounded()) : 0
        connection.changeProperty(window.id, atoms[.netFrameExtents], type: atoms[.cardinal], longs: [0, 0, top, 0])
    }

    func reloadProperty(_ atom: XAtom, of window: X11Window) async {
        let value = try? await connection.property(window.id, atoms[atom])
        guard windows[window.id] === window else { return }
        window.properties.apply(atom, value, atoms: atoms)
        switch atom {
        case .netWMName, .wmName, .wmClass, .wmClientMachine:
            applyTitle(window)
            onChange?()
        case .wmNormalHints:
            applySizeHints(window)
        default:
            break
        }
    }

    // MARK: Icon

    /// Reads _NET_WM_ICON. It is not among `tracked`: icons run to megabytes
    /// and are read with their own size limit.
    func reloadIcon(of window: X11Window) async {
        let value = try? await connection.property(window.id, atoms[.netWMIcon], maxBytes: 4 << 20)
        guard windows[window.id] === window else { return }
        let icon = value.flatMap { X11Icon.best(in: $0.longs) }
        window.icon = icon.flatMap { icon in
            icon.makeImage().map { NSImage(cgImage: $0, size: CGSize(width: icon.width, height: icon.height)) }
        }
    }

    /// The Dock tile of a minimized window: its contents and the program's icon.
    /// Windows without an icon keep the system look.
    func dockTileView(for window: X11Window, size: CGSize) -> X11DockTileView? {
        guard let icon = window.icon, !window.overrideRedirect else { return nil }
        return X11DockTileView(contents: window.surface.makeImage(), icon: icon, size: size)
    }

    func hostWillMiniaturize(_ window: X11Window) {
        guard let host = window.host else { return }
        let tile = host.dockTile
        tile.contentView = dockTileView(for: window, size: tile.size)
        tile.display()
    }

    static func png(_ view: NSView) -> Data? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    static func png(_ image: NSImage) -> Data? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            .flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }

    // MARK: Showing (MapNotify)

    /// The window became viewable: start mirroring its pixels and put it on screen.
    func present(_ window: X11Window) async {
        guard let attributes = try? await connection.windowAttributes(window.id), !attributes.isInputOnly,
              let (depth, geometry) = try? await connection.geometry(window.id),
              windows[window.id] === window else { return }
        if window.overrideRedirect {
            // Popups are not managed, but their type tells menus from tooltips.
            let type = try? await connection.property(window.id, atoms[.netWMWindowType])
            guard windows[window.id] === window else { return }
            window.properties.apply(.netWMWindowType, type, atoms: atoms)
        }
        window.depth = depth
        window.geometry = geometry
        window.isMapped = true

        let surface = window.surface
        surface.hasAlpha = depth == 32
        surface.scale = desktop.scale
        surface.resizeBuffer(width: window.outerSize.width, height: window.outerSize.height)
        attachContents(window)

        if presentsWindows, isOnDesktop(window) {
            let host = window.host ?? makeHost(for: window)
            window.host = host
            applyHostFrame(window)
            applyTitle(window, host: host)
            if window.overrideRedirect {
                host.orderFrontRegardless()
            } else if NSApp.isActive {
                host.makeKeyAndOrderFront(nil)
            } else {
                host.orderFront(nil)
            }
            syncStackingFromScreen()
        } else if !window.overrideRedirect {
            // Nothing on screen will make it key (tests, harness): focus it directly.
            connection.raiseWindow(window.id)
            giveFocus(to: window)
        }
        onChange?()
    }

    /// Override-redirect helpers parked outside the screen are never shown.
    private func isOnDesktop(_ window: X11Window) -> Bool {
        let g = window.geometry
        // Once the root has been moved about, real popups can lie beyond its far edges.
        let within = rootHasMoved || (g.x < desktop.pixelWidth && g.y < desktop.pixelHeight)
        return within && g.x + g.width > 0 && g.y + g.height > 0
    }

    private func makeHost(for window: X11Window) -> NSWindow {
        let rect = desktop.contentRect(for: window.geometry)
        let host: NSWindow
        if window.overrideRedirect {
            let panel = X11PopupPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .popUpMenu
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.hasShadow = true
            host = panel
        } else {
            var style: NSWindow.StyleMask = [.borderless]
            if window.properties.wantsDecorations && window.properties.kind != .splash {
                style = [.titled, .closable]
                if window.properties.kind == .normal { style.insert(.miniaturizable) }
                if !window.properties.sizeHints.isFixedSize { style.insert(.resizable) }
            }
            host = X11HostWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
            host.tabbingMode = .disallowed
            host.isRestorable = false
            if window.properties.kind == .utility { host.level = .floating }
        }
        host.isReleasedWhenClosed = false
        host.acceptsMouseMovedEvents = true
        host.isOpaque = window.depth != 32
        host.backgroundColor = window.depth == 32 ? .clear : .windowBackgroundColor
        host.contentView = window.surface
        host.initialFirstResponder = window.surface
        host.delegate = window
        if !window.overrideRedirect {
            applyTitle(window, host: host)
            applySizeHints(window, host: host)
        }
        return host
    }

    func applyTitle(_ window: X11Window, host: NSWindow? = nil) {
        guard let host = host ?? window.host, !window.overrideRedirect else { return }
        host.title = window.properties.title
        updateWindowsMenuItem(window, host: host)
        // Which machine the program runs on.
        host.subtitle = window.properties.clientMachine ?? ""
    }

    /// AppKit lists titled windows in the Window menu by itself; windows whose
    /// program draws its own title bar are borderless here and are added by hand.
    private func updateWindowsMenuItem(_ window: X11Window, host: NSWindow) {
        guard !host.styleMask.contains(.titled), window.properties.kind != .splash else { return }
        NSApp.changeWindowsItem(host, title: window.properties.title, filename: false)
    }

    func applySizeHints(_ window: X11Window, host: NSWindow? = nil) {
        guard let host = host ?? window.host, !window.overrideRedirect else { return }
        let hints = window.properties.sizeHints
        let scale = desktop.scale
        func points(_ size: (width: Int, height: Int)) -> CGSize {
            CGSize(width: CGFloat(size.width) / scale, height: CGFloat(size.height) / scale)
        }
        host.contentMinSize = hints.minSize.map(points) ?? CGSize(width: 1, height: 1)
        host.contentMaxSize = hints.maxSize.map(points) ?? CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        host.contentResizeIncrements = hints.increment.map(points) ?? CGSize(width: 1, height: 1)
    }

    // MARK: Hiding (UnmapNotify, DestroyNotify)

    func dismiss(_ window: X11Window) {
        guard window.isMapped else { return }
        window.isMapped = false
        detachContents(window)
        window.host?.orderOut(nil)
        if let host = window.host { NSApp.removeWindowsItem(host) }
        if window.isManaged {
            window.isManaged = false
            setWMState(window, normal: false)
            publishClientList()
        }
        if focusedWindow == window.id {
            focusedWindow = nil
            connection.changeProperty(root, atoms[.netActiveWindow], type: atoms[.window], longs: [0])
        }
        onChange?()
    }

    /// The user clicked the close button: ask the client politely, or cut its connection.
    func requestClose(_ window: X11Window) {
        if window.properties.supportsDelete {
            connection.sendClientMessage(to: window.id, window: window.id, type: atoms[.wmProtocols],
                                         data: [atoms[.wmDeleteWindow], serverTime])
        } else {
            connection.killClient(window.id)
        }
    }
}
