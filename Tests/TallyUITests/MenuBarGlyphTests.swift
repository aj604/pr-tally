import AppKit
import Testing
import TallyCore
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

    /// Whether the ring is green at `degrees` (counterclockwise from 3 o'clock), sampled midway through its stroke.
    private func isGreen(_ image: NSImage, at degrees: Double) -> Bool {
        let scale = 4.0, side = 18 * scale
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        }
        NSGraphicsContext.restoreGraphicsState()
        // The ring's radius, as the glyph draws it.
        let radius = ((18 - 2.6) / 2 - 0.5) * scale
        let angle = degrees * .pi / 180
        let x = side / 2 + radius * cos(angle), y = side / 2 + radius * sin(angle)
        // Bitmap rows count down from the top.
        guard let color = rep.colorAt(x: Int(x), y: Int(side - y)) else { return false }
        return color.alphaComponent > 0.5 && color.greenComponent - color.redComponent > 0.3
    }

    /// From about 94% the arc's round caps would meet and close the ring, which is what a reached goal looks like.
    @Test func aRingShortOfTheGoalStaysOpenWhereItCloses() {
        let window = MonthWindow(containing: Date())
        let early = window.start.addingTimeInterval(5 * 86_400)
        // Just counterclockwise of 12 o'clock, past the start cap: where the arc's end meets its start.
        let closing = 104.0
        for count in [940, 990, 999] {
            let nearly = MenuBarGlyph.image(for: Pace(goal: 1000, count: count, window: window, at: early))
            #expect(!isGreen(nearly, at: closing), "\(count) of 1,000")
            #expect(isGreen(nearly, at: 180), "\(count) of 1,000")
        }
        let reached = MenuBarGlyph.image(for: Pace(goal: 1000, count: 1000, window: window, at: early))
        #expect(isGreen(reached, at: closing))
    }

    /// The empty ring is all track, so it follows the menu bar from light to dark and back while the app runs.
    @Test func theTrackFollowsTheMenuBarsAppearance() {
        let ring = MenuBarGlyph.image(for: nil)
        #expect(brightness(ring, in: .aqua) < 0.5)
        #expect(brightness(ring, in: .darkAqua) > 0.5)
        #expect(brightness(ring, in: .aqua) < 0.5)
    }
}
