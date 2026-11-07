import AppKit
import Testing
@testable import TallyUI

@MainActor
struct MenuBarGlyphTests {
    /// The average brightness of the ring's drawn pixels, drawn as a menu bar with `appearance` would draw it.
    private func brightness(_ image: NSImage, in appearance: NSAppearance.Name) -> Double {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
        }
        NSGraphicsContext.restoreGraphicsState()
        var total = 0.0, count = 0.0
        for x in 0..<36 {
            for y in 0..<36 {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.1 else { continue }
                total += (color.redComponent + color.greenComponent + color.blueComponent) / 3 / color.alphaComponent
                count += 1
            }
        }
        return total / count
    }

    /// The empty ring is all track, so it follows the menu bar from light to dark and back while the app runs.
    @Test func theTrackFollowsTheMenuBarsAppearance() {
        let ring = MenuBarGlyph.image(for: nil)
        #expect(brightness(ring, in: .aqua) < 0.5)
        #expect(brightness(ring, in: .darkAqua) > 0.5)
        #expect(brightness(ring, in: .aqua) < 0.5)
    }
}
