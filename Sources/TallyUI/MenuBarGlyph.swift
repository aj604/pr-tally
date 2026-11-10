import AppKit
import TallyCore

/// The menu bar's progress ring: colored by the month's pace status, with a tick where a steady pace would be.
public enum MenuBarGlyph {
    private static let size: CGFloat = 18
    private static let lineWidth: CGFloat = 2.6
    private static let titleSpacing: CGFloat = 4
    /// Track left showing between the arc's ends until the goal is reached: two pixels on a Retina menu bar.
    private static let closingGap: CGFloat = 1
    // The menu bar takes on the wallpaper's tint, so a fixed gray can vanish. These follow the text color.
    // Computed on every draw: `withAlphaComponent` fixes the label color to the appearance it's called in.
    private static var track: NSColor { NSColor.labelColor.withAlphaComponent(0.3) }
    private static let tick = NSColor.labelColor

    /// Pass a nil pace while there are no numbers yet to draw an empty ring.
    ///
    /// Menu bar labels ignore text colors, so a green number has to be part of the image. Any other number
    /// should stay a plain `Text`, which keeps the system's menu bar text color.
    public static func image(for pace: Pace?, greenTitle: String? = nil) -> NSImage {
        image(for: pace, title: greenTitle, color: .systemGreen, alpha: 1)
    }

    /// The ring and number faded together, the way the menu bar shows an item that isn't working, for numbers
    /// that have stopped updating. Labels ignore opacity too, so the number has to be part of this image as well.
    public static func fadedImage(for pace: Pace?, title: String) -> NSImage {
        image(for: pace, title: title, color: .labelColor, alpha: 0.4)
    }

    private static func image(for pace: Pace?, title: String?, color: NSColor, alpha: CGFloat) -> NSImage {
        let text = title.map {
            NSAttributedString(string: $0, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: color,
            ])
        }
        let textSize = text?.size() ?? .zero
        let width = text == nil ? size : size + titleSpacing + ceil(textSize.width)
        let image = NSImage(size: NSSize(width: width, height: size), flipped: false) { rect in
            // One layer for the lot, so the arc's round caps don't show darker where they overlap the track.
            let context = NSGraphicsContext.current?.cgContext
            context?.setAlpha(alpha)
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
            draw(pace, in: NSRect(x: 0, y: 0, width: size, height: size))
            text?.draw(at: NSPoint(x: size + titleSpacing, y: (rect.height - textSize.height) / 2))
            context?.endTransparencyLayer()
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
            var sweep = 360 * max(pace.fraction, 0.02)
            if pace.status != .goalHit {
                // The caps reach past both ends of the arc, so from about 94% a ring short of the goal would
                // close and look like the goal reached. Until it is, a gap stays open where the ring closes.
                let gap = (lineWidth + closingGap) / radius * 180 / .pi
                sweep = min(sweep, 360 - gap)
            }
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
