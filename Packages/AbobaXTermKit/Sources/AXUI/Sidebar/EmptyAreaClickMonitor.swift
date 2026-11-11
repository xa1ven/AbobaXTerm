import AppKit
import SwiftUI

/// Calls `action` when the user clicks the empty area of the sidebar outline
/// (below or between rows). The click still reaches the list as usual.
struct EmptyAreaClickMonitor: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.action = action
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.action = action
    }

    final class MonitorView: NSView {
        var action: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let windowNumber = event.windowNumber
                let point = event.locationInWindow
                MainActor.assumeIsolated {
                    self?.handleClick(windowNumber: windowNumber, at: point)
                }
                return event
            }
        }

        private func handleClick(windowNumber: Int, at point: NSPoint) {
            guard let window, window.windowNumber == windowNumber,
                  let contentView = window.contentView,
                  let hit = contentView.hitTest(contentView.convert(point, from: nil)) else { return }
            // Only the sidebar is a table/outline view in the main window.
            var view: NSView? = hit
            while let current = view, !(current is NSTableView) { view = current.superview }
            guard let table = view as? NSTableView else { return }
            if table.row(at: table.convert(point, from: nil)) == -1 {
                DispatchQueue.main.async { self.action?() }
            }
        }
    }
}
