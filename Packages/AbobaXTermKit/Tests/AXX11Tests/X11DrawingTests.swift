@testable import AXX11
import AppKit
import Testing

@Suite struct X11DrawingTests {
    private func rect(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> XRect {
        XRect(x: x, y: y, width: width, height: height)
    }

    @Test func damageKeepsDistantRectanglesApart() {
        var region = X11DamageRegion()
        region.add(rect(0, 0, 20, 20))
        region.add(rect(900, 700, 20, 20))
        #expect(region.rects.count == 2)
        // Overlapping and adjacent damage becomes one fetch.
        region.add(rect(10, 10, 20, 20))
        region.add(rect(920, 700, 20, 20))
        #expect(region.rects.count == 2)
        #expect(region.rects.contains(rect(0, 0, 30, 30)) && region.rects.contains(rect(900, 700, 40, 20)))
        // A rectangle covering everything swallows the rest.
        region.add(rect(0, 0, 1000, 800))
        #expect(region.rects == [rect(0, 0, 1000, 800)])
    }

    @Test func damageFallsBackToOneBoxAndClips() {
        var region = X11DamageRegion()
        for index in 0...X11DamageRegion.limit { region.add(rect(index * 100, index * 100, 10, 10)) }
        #expect(region.rects == [rect(0, 0, X11DamageRegion.limit * 100 + 10, X11DamageRegion.limit * 100 + 10)])
        #expect(region.take(clippedTo: rect(0, 0, 50, 40)) == [rect(0, 0, 50, 40)])
        #expect(region.isEmpty)
        region.add(rect(500, 500, 10, 10))
        region.add(rect(0, 0, 0, 10))
        #expect(region.take(clippedTo: rect(0, 0, 50, 40)).isEmpty)
    }

    /// The two surfaces take turns on screen: each must also receive the changes
    /// that were shown while it was the back one.
    @MainActor @Test func everyFrameShowsAllEarlierChanges() {
        let view = X11SurfaceView(windowID: 1)
        view.resizeBuffer(width: 8, height: 4)
        func fill(_ area: XRect, _ value: UInt8) {
            view.blit(area, [UInt8](repeating: value, count: 32 + area.width * area.height * 4), offset: 32)
            view.present()
        }
        func word(_ value: UInt8) -> UInt32 { 0xFF00_0000 | UInt32(value) << 16 | UInt32(value) << 8 | UInt32(value) }

        fill(rect(0, 0, 8, 4), 0x10)
        fill(rect(0, 0, 2, 2), 0x20)
        fill(rect(6, 2, 2, 2), 0x30)
        fill(rect(3, 1, 1, 1), 0x40)
        for _ in 0..<2 {
            #expect(view.shownPixel(x: 0, y: 0) == word(0x20))
            #expect(view.shownPixel(x: 7, y: 3) == word(0x30))
            #expect(view.shownPixel(x: 3, y: 1) == word(0x40))
            #expect(view.shownPixel(x: 4, y: 2) == word(0x10))
            // The same must hold on the other surface after one more frame.
            fill(rect(5, 0, 1, 1), 0x50)
            #expect(view.shownPixel(x: 5, y: 0) == word(0x50))
        }
        // The unused byte of depth-24 pixels must not make the window transparent.
        view.blit(rect(0, 3, 1, 1), [1, 2, 3, 0])
        view.present()
        #expect(view.shownPixel(x: 0, y: 3) == 0xFF03_0201)

        // A resize keeps what was drawn and shows it on fresh surfaces.
        view.resizeBuffer(width: 10, height: 6)
        view.present()
        #expect(view.shownPixel(x: 7, y: 3) == word(0x30))
    }
}
