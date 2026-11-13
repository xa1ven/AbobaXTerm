import AppKit
import SwiftUI

/// The app's few animations in one place: short enough not to get in the way,
/// and reduced to a plain fade when "Reduce motion" is on in System Settings.
///
/// Not animated on purpose: switching tabs, hover highlights, the numbers in
/// the status bar and terminal output. They happen all the time.
@MainActor
enum Motion {
    static var isReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Small changes in place, such as swapping the sidebar's content.
    static var quick: Animation { .easeOut(duration: 0.12) }

    /// Things that appear, disappear or move: tabs, bars, sections.
    static var standard: Animation { isReduced ? quick : .snappy(duration: 0.2, extraBounce: 0) }

    /// A bar that slides in from one edge of its container.
    static func bar(from edge: Edge) -> AnyTransition {
        isReduced ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    /// A small item (a tab, a badge) that grows into place.
    static var item: AnyTransition {
        isReduced ? .opacity : .scale(scale: 0.9).combined(with: .opacity)
    }
}
