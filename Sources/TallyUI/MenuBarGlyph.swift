import AppKit
import TallyCore

/// The menu bar's progress ring: colored by pace status, with a tick where a steady pace would be.
public enum MenuBarGlyph {
    private static let size: CGFloat = 18
    private static let lineWidth: CGFloat = 2.6
    // The menu bar takes on the wallpaper's tint, so a fixed gray can vanish. These follow the text color.
    private static let track = NSColor.labelColor.withAlphaComponent(0.3)
    private static let tick = NSColor.labelColor

    /// Pass nil while there are no numbers yet to draw an empty ring.
    public static func image(for pace: Pace?) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(pace, in: rect)
            return true
        }
        // Not a template: macOS would otherwise flatten the ring to a single color.
        image.isTemplate = false
        image.accessibilityDescription = pace.map { "\($0.count) of \($0.goal)" } ?? "Loading"
        return image
    }

    private static func draw(_ pace: Pace?, in rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = (rect.width - lineWidth) / 2 - 0.5

        let ring = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2
        ))
        ring.lineWidth = lineWidth
        track.setStroke()
        ring.stroke()

        guard let pace else { return }

        if pace.fraction > 0 {
            // A floor keeps a small count visible; the round caps do the rest.
            let sweep = 360 * max(pace.fraction, 0.02)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = pace.status == .goalHit ? .butt : .round
            color(for: pace.status).setStroke()
            arc.stroke()
        }

        if pace.status != .goalHit, pace.goal > 0 {
            let angle = (90 - 360 * min(Double(pace.expected) / Double(pace.goal), 1)) * .pi / 180
            let inner = radius - lineWidth / 2 - 0.5
            let outer = radius + lineWidth / 2 + 0.5
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
            mark.line(to: NSPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
            mark.lineWidth = 1.5
            tick.setStroke()
            mark.stroke()
        }
    }

    static func color(for status: Pace.Status) -> NSColor {
        switch status {
        case .goalHit, .ahead, .onPace: .systemGreen
        case .behind: .systemOrange
        }
    }
}
