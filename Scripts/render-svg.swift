// Renders an SVG to PNGs of exact pixel sizes (no extra tools needed, AppKit reads SVG):
//   swift Scripts/render-svg.swift in.svg out1.png 1024 out2.png 660x420 ...
import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3, args.count % 2 == 1 else {
    fail("usage: render-svg.swift in.svg out.png SIZE|WxH [out.png SIZE|WxH ...]")
}
guard let image = NSImage(contentsOfFile: args[0]) else { fail("cannot read \(args[0])") }

for index in stride(from: 1, to: args.count, by: 2) {
    let parts = args[index + 1].split(separator: "x").compactMap { Int($0) }
    guard let width = parts.first, width > 0 else { fail("bad size \(args[index + 1])") }
    let height = parts.count > 1 ? parts[1] : width
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { fail("cannot allocate \(width)x\(height)") }
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fail("cannot encode PNG") }
    do { try png.write(to: URL(fileURLWithPath: args[index])) } catch { fail("cannot write \(args[index]): \(error)") }
}
