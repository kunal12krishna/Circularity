import AppKit

/// The board-H status glyph (PLAN.md §9.3): three arcs of radius 9 with
/// deliberately uneven gaps plus a centre dot, in a 24 × 24 box.
/// Milestone (a) draws the idle state only; (h) adds the other six states.
enum StatusGlyph {
    static let box: CGFloat = 24
    static let center = CGPoint(x: 12, y: 12)
    static let radius: CGFloat = 9
    static let strokeWidth: CGFloat = 2.4
    static let dotRadius: CGFloat = 2.2

    /// Segment start/end points copied from the board's SVG paths
    /// (`M12 3 a9 9 0 0 1 8.5 6`, `M20.8 13.5 A9 9 0 0 1 12 21`,
    /// `M8.5 20.3 A9 9 0 0 1 3.4 9.5`), in the SVG's y-down space.
    static let segments: [(start: CGPoint, end: CGPoint)] = [
        (CGPoint(x: 12, y: 3), CGPoint(x: 20.5, y: 9)),
        (CGPoint(x: 20.8, y: 13.5), CGPoint(x: 12, y: 21)),
        (CGPoint(x: 8.5, y: 20.3), CGPoint(x: 3.4, y: 9.5)),
    ]

    /// Angle of a point around the centre in the boards' convention:
    /// degrees, 0 = 12 o'clock, increasing clockwise (y-down space).
    static func clockAngle(of p: CGPoint) -> CGFloat {
        var degrees = atan2(p.x - center.x, center.y - p.y) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    /// Draws the glyph into the current context, which must be flipped (y-down)
    /// and scaled so the glyph's 24-unit box fills the target.
    static func draw(color: NSColor) {
        color.setStroke()
        color.setFill()
        for segment in segments {
            let path = NSBezierPath()
            // In y-down space an increasing angle sweeps visually clockwise,
            // and a clock angle θ is the math angle θ − 90°.
            path.appendArc(withCenter: center, radius: radius,
                           startAngle: clockAngle(of: segment.start) - 90,
                           endAngle: clockAngle(of: segment.end) - 90,
                           clockwise: false)
            path.lineWidth = strokeWidth
            path.lineCapStyle = .round
            path.stroke()
        }
        NSBezierPath(ovalIn: CGRect(x: center.x - dotRadius, y: center.y - dotRadius,
                                    width: dotRadius * 2, height: dotRadius * 2)).fill()
    }

    /// The idle glyph as an image. Template images take the menu bar's tint.
    static func image(pointSize: CGFloat = 16, color: NSColor = .black, template: Bool = true) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.scaleBy(x: rect.width / box, y: rect.height / box)
            draw(color: color)
            context.restoreGState()
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = AppIdentity.name
        return image
    }
}
