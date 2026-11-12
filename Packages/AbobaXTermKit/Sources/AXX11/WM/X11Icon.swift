import AppKit

/// A program's own icon, from _NET_WM_ICON: a list of images, each
/// width, height and width*height ARGB pixels (not premultiplied).
struct X11Icon: Equatable, Sendable {
    var width: Int
    var height: Int
    var pixels: [UInt32]

    /// Larger images are not icons (and a broken size must not make us allocate much).
    static let maxSide = 1024

    /// The largest complete image in the property; nil when there is none.
    static func best(in longs: [UInt32]) -> X11Icon? {
        var best: (offset: Int, width: Int, height: Int)?
        var offset = 0
        while offset + 2 <= longs.count {
            let width = Int(longs[offset]), height = Int(longs[offset + 1])
            guard width > 0, height > 0, width <= maxSide, height <= maxSide else { break }
            let end = offset + 2 + width * height
            // A cut-off last image (the property was longer than we read) is skipped.
            guard end <= longs.count else { break }
            if width * height > (best.map { $0.width * $0.height } ?? 0) { best = (offset + 2, width, height) }
            offset = end
        }
        guard let best else { return nil }
        return X11Icon(width: best.width, height: best.height,
                       pixels: Array(longs[best.offset ..< best.offset + best.width * best.height]))
    }

    func makeImage() -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: pixels.count * 4)
        for (index, pixel) in pixels.enumerated() {
            let a = pixel >> 24
            // Core Graphics wants colour already multiplied by alpha.
            func channel(_ shift: UInt32) -> UInt8 { UInt8(((pixel >> shift) & 0xFF) * a / 255) }
            bytes[index * 4] = channel(0)
            bytes[index * 4 + 1] = channel(8)
            bytes[index * 4 + 2] = channel(16)
            bytes[index * 4 + 3] = UInt8(a)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// What the Dock shows for a minimized X window: its contents with the
/// program's icon in the corner (where AppKit would put the app's own icon).
final class X11DockTileView: NSView {
    private let contents: CGImage?
    private let icon: NSImage

    init(contents: CGImage?, icon: NSImage, size: CGSize) {
        self.contents = contents
        self.icon = icon
        super.init(frame: CGRect(origin: .zero, size: size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        guard let contents, contents.width > 0, contents.height > 0 else {
            icon.draw(in: bounds.insetBy(dx: bounds.width * 0.08, dy: bounds.height * 0.08))
            return
        }
        let fit = min(bounds.width / CGFloat(contents.width), bounds.height / CGFloat(contents.height))
        let size = CGSize(width: CGFloat(contents.width) * fit, height: CGFloat(contents.height) * fit)
        let rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        NSImage(cgImage: contents, size: size).draw(in: rect)
        let side = min(bounds.width, bounds.height) * 0.45
        icon.draw(in: CGRect(x: bounds.maxX - side, y: bounds.minY, width: side, height: side))
    }
}
