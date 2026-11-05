import AppKit
import TallyCore

/// The menu bar's progress ring: colored by the month's pace status, with a tick where a steady pace would be.
public enum MenuBarGlyph {
    private static let size: CGFloat = 18
    private static let lineWidth: CGFloat = 2.6
    private static let titleSpacing: CGFloat = 4
    // The menu bar takes on the wallpaper's tint, so a fixed gray can vanish. These follow the text color.
    private static let track = NSColor.labelColor.withAlphaComponent(0.3)
    private static let tick = NSColor.labelColor

    /// Pass a nil pace while there are no numbers yet to draw an empty ring.
    ///
    /// Menu bar labels ignore text colors, so a green number has to be part of the image. Any other number
    /// should stay a plain `Text`, which keeps the system's menu bar text color.
    public static func image(for pace: Pace?, greenTitle: String? = nil) -> NSImage {
        let text = greenTitle.map {
            NSAttributedString(string: $0, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.systemGreen,
            ])
        }
        let textSize = text?.size() ?? .zero
        let width = text == nil ? size : size + titleSpacing + ceil(textSize.width)
        let image = NSImage(size: NSSize(width: width, height: size), flipped: false) { rect in
            draw(pace, in: NSRect(x: 0, y: 0, width: size, height: size))
            text?.draw(at: NSPoint(x: size + titleSpacing, y: (rect.height - textSize.height) / 2))
            return true
        }
        // Not a template: macOS would otherwise flatten the image to a single color.
        image.isTemplate = false
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
