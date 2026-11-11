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

    /// X rectangle (x, y, width, height) of a Cocoa rectangle, e.g. the area free of menu bar and Dock.
    func xRect(for rect: CGRect) -> XRect {
        let g = geometry(forContentRect: rect)
        return XRect(x: g.x, y: g.y, width: g.width, height: g.height)
    }
}
