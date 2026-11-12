import AppKit
import SwiftUI

/// AppKit side of the sessions list, placed behind it as a background view.
///
/// - Calls `onEmptyAreaClick` when the user clicks the empty area of the list
///   (below or between rows). The click still reaches the list as usual.
/// - Turns off the list's own selection highlight: rows draw a neutral mark.
/// - Gives the list keyboard focus when a row is clicked (rows handle their
///   clicks with SwiftUI gestures, so the table itself may not see them).
/// - Reports through `onFocusChange` when the list gains or loses focus.
struct SidebarTableBridge: NSViewRepresentable {
    let onEmptyAreaClick: () -> Void
    let onFocusChange: (Bool) -> Void

    func makeNSView(context: Context) -> BridgeView {
        let view = BridgeView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: BridgeView, context: Context) {
        view.onEmptyAreaClick = onEmptyAreaClick
        view.onFocusChange = onFocusChange
        view.adoptTable()
    }

    final class BridgeView: NSView {
        var onEmptyAreaClick: (() -> Void)?
        var onFocusChange: ((Bool) -> Void)?
        private var monitor: Any?
        private var responderObservation: NSKeyValueObservation?
        private weak var table: NSTableView?
        private var tableFocused = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            responderObservation = nil
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let windowNumber = event.windowNumber
                let point = event.locationInWindow
                MainActor.assumeIsolated {
                    self?.handleClick(windowNumber: windowNumber, at: point)
                }
                return event
            }
            responderObservation = window.observe(\.firstResponder) { [weak self] _, _ in
                // Posted on the main thread, in the middle of makeFirstResponder.
                DispatchQueue.main.async { self?.responderChanged() }
            }
            DispatchQueue.main.async { [weak self] in self?.adoptTable() }
        }

        /// Finds the list's table (the nearest one around this view) and
        /// turns its selection highlight off.
        func adoptTable() {
            if table == nil {
                var ancestor = superview
                while let current = ancestor, table == nil {
                    table = Self.findTable(in: current)
                    ancestor = current.superview
                }
            }
            if let table, table.selectionHighlightStyle != .none {
                table.selectionHighlightStyle = .none
            }
        }

        private static func findTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for subview in view.subviews {
                if let table = findTable(in: subview) { return table }
            }
            return nil
        }

        private func responderChanged() {
            var focused = false
            if let table, let responder = window?.firstResponder as? NSView {
                focused = responder.isDescendant(of: table)
            }
            guard focused != tableFocused else { return }
            tableFocused = focused
            onFocusChange?(focused)
        }

        private func handleClick(windowNumber: Int, at point: NSPoint) {
            guard let window, window.windowNumber == windowNumber,
                  let contentView = window.contentView,
                  let hit = contentView.hitTest(contentView.convert(point, from: nil)) else { return }
            var view: NSView? = hit
            while let current = view, !(current is NSTableView) { view = current.superview }
            guard let clicked = view as? NSTableView else { return }
            adoptTable()
            guard clicked === table else { return }
            if clicked.row(at: clicked.convert(point, from: nil)) == -1 {
                DispatchQueue.main.async { self.onEmptyAreaClick?() }
            } else if window.firstResponder !== clicked {
                window.makeFirstResponder(clicked)
            }
        }
    }
}
