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

    /// The ring's color at `degrees` (counterclockwise from 3 o'clock), sampled midway through its stroke.
    private func color(of image: NSImage, at degrees: Double) -> NSColor? {
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
        return rep.colorAt(x: Int(x), y: Int(side - y))
    }

    private func isGreen(_ image: NSImage, at degrees: Double) -> Bool {
        guard let color = color(of: image, at: degrees) else { return false }
        return color.alphaComponent > 0.5 && color.greenComponent - color.redComponent > 0.3
    }

    /// Only the faint track shows: neither the arc nor the pace tick, which are both drawn opaque.
    private func isTrack(_ image: NSImage, at degrees: Double) -> Bool {
        guard let color = color(of: image, at: degrees) else { return false }
        return color.alphaComponent > 0.1 && color.alphaComponent < 0.5
    }

    private let november = MonthWindow(
        containing: Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 16))!
    )
    /// Just counterclockwise of 12 o'clock, past the start cap: where the arc's end meets its start.
    private let closing = 104.0

    /// From about 94% the arc's round caps would meet and close the ring, which is what a reached goal looks like.
    @Test func aRingShortOfTheGoalStaysOpenWhereItCloses() {
        let early = november.start.addingTimeInterval(5 * 86_400)
        for count in [940, 990, 999] {
            let nearly = MenuBarGlyph.image(for: Pace(goal: 1000, count: count, window: november, at: early))
            #expect(isTrack(nearly, at: closing), "\(count) of 1,000")
            #expect(isGreen(nearly, at: 180), "\(count) of 1,000")
        }
        let reached = MenuBarGlyph.image(for: Pace(goal: 1000, count: 1000, window: november, at: early))
        #expect(isGreen(reached, at: closing))
    }

    /// Near the month's end a steady pace is most of the goal, which would put the tick where the ring closes.
    @Test func thePaceTickLeavesTheGapOpenLateInTheMonth() {
        for count in [930, 999] {
            for tenth in 270...298 {
                let at = november.start.addingTimeInterval(Double(tenth) / 10 * 86_400)
                let pace = Pace(goal: 1000, count: count, window: november, at: at)
                #expect(isTrack(MenuBarGlyph.image(for: pace), at: closing), "\(count) with \(pace.expected) expected")
            }
        }
    }

    /// The empty ring is all track, so it follows the menu bar from light to dark and back while the app runs.
    @Test func theTrackFollowsTheMenuBarsAppearance() {
        let ring = MenuBarGlyph.image(for: nil)
        #expect(brightness(ring, in: .aqua) < 0.5)
        #expect(brightness(ring, in: .darkAqua) > 0.5)
        #expect(brightness(ring, in: .aqua) < 0.5)
    }
}
