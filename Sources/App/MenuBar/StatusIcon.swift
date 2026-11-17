import AppKit

enum StatusIconState: Equatable {
    case idle, dragOver, converting(Double), done, error, paused
}

enum StatusIconStyle: String {
    case monochrome, colour, minimal
}

/// Board H's icon states (PLAN.md §9.3), drawn at display time so monochrome
/// follows the menu bar's appearance (labelColor), while the error badge stays red.
enum StatusIcon {
    static let size = CGSize(width: 26, height: 22)

    static func image(_ state: StatusIconState, style: StatusIconStyle, accent: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let fg = NSColor.labelColor
            let ac = style == .colour ? accent : fg
            if state == .dragOver {
                (style == .colour ? accent : fg.withAlphaComponent(0.16)).setFill()
                NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: 5, yRadius: 5).fill()
            }
            ctx.saveGState()
            // The 24-unit glyph box at 16 pt, centred.
            ctx.translateBy(x: (size.width - 16) / 2, y: (size.height - 16) / 2)
            ctx.scaleBy(x: 16 / 24, y: 16 / 24)
            let glyph = state == .dragOver && style == .colour ? NSColor(srgbRed: 0x1A / 255, green: 0x12 / 255, blue: 0x06 / 255, alpha: 1) : fg
            draw(state, style: style, fg: glyph, ac: ac)
            ctx.restoreGState()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "\(AppIdentity.name), \(description(state))"
        return image
    }

    static func description(_ state: StatusIconState) -> String {
        switch state {
        case .idle: "ready"
        case .dragOver: "drop to convert"
        case let .converting(p): "converting, \(Int(p * 100)) percent"
        case .done: "done"
        case .error: "something went wrong"
        case .paused: "paused"
        }
    }

    private static let center = CGPoint(x: 12, y: 12)

    private static func arc(_ from: CGFloat, _ to: CGFloat, radius: CGFloat = 9) -> NSBezierPath {
        let p = NSBezierPath()
        p.appendArc(withCenter: center, radius: radius, startAngle: from - 90, endAngle: to - 90, clockwise: false)
        p.lineWidth = 2.4
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        return p
    }

    private static func dot(_ color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: 12 - 2.2, y: 12 - 2.2, width: 4.4, height: 4.4)).fill()
    }

    private static func segments(_ color: NSColor, shortenFirst: Bool = false) {
        color.setStroke()
        for (i, seg) in StatusGlyph.segments.enumerated() {
            var end = StatusGlyph.clockAngle(of: seg.end)
            if i == 0, shortenFirst { end = StatusGlyph.clockAngle(of: CGPoint(x: 16, y: 4)) } // board H: "M12 3 a9 9 0 0 1 4 1"
            arc(StatusGlyph.clockAngle(of: seg.start), end).stroke()
        }
    }

    private static func draw(_ state: StatusIconState, style: StatusIconStyle, fg: NSColor, ac: NSColor) {
        if style == .minimal {
            switch state {
            case let .converting(p):
                fg.withAlphaComponent(0.3).setStroke(); arc(0, 360, radius: 5).stroke()
                ac.setStroke(); arc(0, 360 * max(0.02, p), radius: 5).stroke()
            case .error: badge()
            default: break
            }
            dot(state == .paused ? fg.withAlphaComponent(0.4) : fg)
            return
        }
        switch state {
        case .idle, .dragOver:
            segments(fg)
            dot(fg)
        case let .converting(p):
            fg.withAlphaComponent(0.3).setStroke()
            arc(0, 360).stroke()
            ac.setStroke()
            arc(0, 360 * max(0.02, min(1, p))).stroke()
            dot(fg)
        case .done:
            ac.setStroke()
            arc(0, 360).stroke()
            let check = NSBezierPath()
            check.move(to: CGPoint(x: 8, y: 12.5)); check.line(to: CGPoint(x: 10.7, y: 15.2)); check.line(to: CGPoint(x: 16, y: 9.8))
            check.lineWidth = 2.4; check.lineCapStyle = .round; check.lineJoinStyle = .round
            check.stroke()
        case .error:
            segments(fg, shortenFirst: true)
            dot(fg)
            badge()
        case .paused:
            segments(fg.withAlphaComponent(0.4))
            fg.setFill()
            NSBezierPath(roundedRect: CGRect(x: 9.2, y: 8.5, width: 2, height: 7), xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: CGRect(x: 12.8, y: 8.5, width: 2, height: 7), xRadius: 1, yRadius: 1).fill()
        }
    }

    private static func badge() {
        NSColor(srgbRed: 0xE5 / 255, green: 0x48 / 255, blue: 0x3D / 255, alpha: 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: 19 - 4.2, y: 5 - 4.2, width: 8.4, height: 8.4)).fill()
        NSColor.white.setStroke()
        let mark = NSBezierPath()
        mark.move(to: CGPoint(x: 19, y: 3.2)); mark.line(to: CGPoint(x: 19, y: 5.4))
        mark.move(to: CGPoint(x: 19, y: 6.9)); mark.line(to: CGPoint(x: 19, y: 7.0))
        mark.lineWidth = 1.6; mark.lineCapStyle = .round
        mark.stroke()
    }
}
