import AppKit

/// Mouse and keyboard from the surface views, injected with XTEST.
///
/// X has one pointer in root coordinates: the position inside a view is
/// offset by that window's X position, so the server routes the event to the
/// same window (and child widget) the user sees under the mouse.
extension X11WindowManager: X11SurfaceInput {
    func surfacePointerEntered(_ view: X11SurfaceView) {
        syncStackingFromScreen()
        view.cursor = currentCursor
    }

    func surface(_ view: X11SurfaceView, pointerAt point: CGPoint) {
        guard let window = windows[view.windowID] else { return }
        movePointer(to: point, in: window)
    }

    func surface(_ view: X11SurfaceView, button: Int, pressed: Bool, at point: CGPoint) {
        guard let window = windows[view.windowID], (1...255).contains(button) else { return }
        if pressed {
            syncStackingFromScreen()
            keyboard.commitModifiers()
        }
        movePointer(to: point, in: window)
        connection.fakeInput(ext, pressed ? .buttonPress : .buttonRelease, detail: UInt8(button))
    }

    func surface(_ view: X11SurfaceView, scrollBy delta: CGSize, precise: Bool, at point: CGPoint) {
        guard let window = windows[view.windowID] else { return }
        movePointer(to: point, in: window)
        // X scrolling is button clicks: 4 up, 5 down, 6 left, 7 right.
        let step: CGFloat = precise ? 14 : 1
        scrollRemainder.width += delta.width
        scrollRemainder.height += delta.height
        func clicks(_ amount: inout CGFloat, positive: UInt8, negative: UInt8) {
            var count = Int(abs(amount) / step)
            guard count > 0 else { return }
            let button = amount > 0 ? positive : negative
            amount -= CGFloat(count) * step * (amount > 0 ? 1 : -1)
            count = min(count, 12)
            for _ in 0..<count {
                connection.fakeInput(ext, .buttonPress, detail: button)
                connection.fakeInput(ext, .buttonRelease, detail: button)
            }
        }
        clicks(&scrollRemainder.height, positive: 4, negative: 5)
        clicks(&scrollRemainder.width, positive: 6, negative: 7)
    }

    func surface(_ view: X11SurfaceView, key event: NSEvent, pressed: Bool) {
        keyboard.key(event, pressed: pressed)
    }

    func surface(_ view: X11SurfaceView, modifiersChanged event: NSEvent) {
        keyboard.modifiersChanged(event)
    }

    func surface(_ view: X11SurfaceView, shortcut event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers == .command, let window = windows[view.windowID] else { return false }
        // Whatever becomes of it (shortcut, menu of the app, Super+key), Command was not just tapped.
        keyboard.commandKeyUsed()
        return performShortcut(macKey: event.keyCode, in: window)
    }

    /// Command+key in `window`: copy, paste and friends in the program's own
    /// terms (see `X11Shortcut`). False if the key is not such a shortcut.
    @discardableResult
    func performShortcut(macKey: UInt16, in window: X11Window) -> Bool {
        guard let keysym = keyboard.shortcutKeysym(forMacKey: macKey),
              let action = X11Shortcut.action(forKeysym: keysym, style: window.properties.shortcutStyle) else { return false }
        switch action {
        case .control(let shift):
            offerPasteboard()
            keyboard.sendChord(macKey: macKey, control: true, shift: shift)
        case .copySelection:
            copyPrimarySelection()
        case .pasteSelection:
            offerPasteboard()
            offerPrimarySelection()
            keyboard.sendChord(macKey: 114, control: false, shift: true) // Shift+Insert
        case .ignore:
            break
        }
        return true
    }

    /// `point` is in X pixels relative to the window's top-left corner.
    func movePointer(to point: CGPoint, in window: X11Window) {
        let x = window.geometry.x + window.geometry.border + Int(point.x)
        let y = window.geometry.y + window.geometry.border + Int(point.y)
        if let pointer, pointer.x == x, pointer.y == y { return }
        pointer = (x, y)
        connection.fakeInput(ext, .motion, x: x, y: y)
    }

    // MARK: Scripted input (tests and the development harness)

    /// Clicks at a position inside `window`, in X pixels.
    func click(_ window: X11Window, x: Int, y: Int, button: Int = 1) {
        movePointer(to: CGPoint(x: x, y: y), in: window)
        connection.fakeInput(ext, .buttonPress, detail: UInt8(button))
        connection.fakeInput(ext, .buttonRelease, detail: UInt8(button))
    }
}
