import CoreGraphics
import Foundation

/// Maps between the X root window (pixels, origin top-left, y down) and the
/// Mac desktop (points, origin bottom-left of the primary screen, y up).
struct X11Desktop: Equatable, Sendable {
    /// Bounding box of all screens in Cocoa coordinates.
    var frame: CGRect
    /// X pixels per point (1 = classic, 2 = Retina-sharp clients).
    var scale: CGFloat = 1

    var pixelWidth: Int { Int((frame.width * scale).rounded()) }
    var pixelHeight: Int { Int((frame.height * scale).rounded()) }

    /// Cocoa rectangle covered by an X window's contents.
    func contentRect(for g: XGeometry) -> CGRect {
        let width = CGFloat(g.width) / scale, height = CGFloat(g.height) / scale
        return CGRect(x: frame.minX + CGFloat(g.x) / scale,
                      y: frame.maxY - CGFloat(g.y) / scale - height,
                      width: width, height: height)
    }

    /// X position and size of a window whose contents cover `rect`.
    func geometry(forContentRect rect: CGRect) -> XGeometry {
        XGeometry(x: Int(((rect.minX - frame.minX) * scale).rounded()),
                  y: Int(((frame.maxY - rect.maxY) * scale).rounded()),
                  width: max(1, Int((rect.width * scale).rounded())),
                  height: max(1, Int((rect.height * scale).rounded())))
    }

    /// The same root window laid over another part of the Mac desktop, so that
    /// it covers `rect` (centred on it; top-left aligned where `rect` is larger).
    /// The root cannot grow while the server runs, but where it lies is only
    /// this app's convention.
    func recentered(on rect: CGRect) -> X11Desktop {
        var moved = self
        moved.frame.origin.x = rect.width > frame.width ? rect.minX : (rect.midX - frame.width / 2).rounded()
        moved.frame.origin.y = rect.height > frame.height ? rect.maxY - frame.height : (rect.midY - frame.height / 2).rounded()
        return moved
    }

    /// Whether the root lies under the whole of `rect` (as far as it can: a
    /// rectangle larger than the root counts when its top-left part is covered).
    func reaches(_ rect: CGRect) -> Bool {
        let needed = CGRect(x: rect.minX, y: rect.maxY - min(rect.height, frame.height),
                            width: min(rect.width, frame.width), height: min(rect.height, frame.height))
        return frame.insetBy(dx: -0.5, dy: -0.5).contains(needed)
    }

    /// X rectangle (x, y, width, height) of a Cocoa rectangle, e.g. the area free of menu bar and Dock.
    func xRect(for rect: CGRect) -> XRect {
        let g = geometry(forContentRect: rect)
        return XRect(x: g.x, y: g.y, width: g.width, height: g.height)
    }
}
