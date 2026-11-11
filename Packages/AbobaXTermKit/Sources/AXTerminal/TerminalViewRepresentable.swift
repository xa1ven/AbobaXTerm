import AppKit
import SwiftUI

/// Container that keeps a margin around the terminal, filled with the
/// terminal's background color so the padding looks like part of it.
public final class TerminalContainerView: NSView {
    static let insets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 8)

    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override public var wantsUpdateLayer: Bool { true }

    override public func updateLayer() {
        layer?.backgroundColor = TerminalTheme.current(for: effectiveAppearance).background.cgColor
    }

    func attach(_ terminal: NSView) {
        guard terminal.superview !== self else { return }
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        let insets = Self.insets
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }
}

/// Hosts a tab's long-lived terminal view in SwiftUI.
///
/// The `AXTerminalView` belongs to the tab and survives tab switches; this
/// representable only re-parents it into a fresh container.
public struct TerminalViewRepresentable: NSViewRepresentable {
    let tab: TerminalTab

    public init(tab: TerminalTab) {
        self.tab = tab
    }

    public func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.attach(tab.terminalView)
        let terminal = tab.terminalView
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
        return container
    }

    public func updateNSView(_ container: TerminalContainerView, context: Context) {
        container.attach(tab.terminalView)
    }
}
