import AppKit
import QuartzCore

// Shared drawing helpers for the wheel renderers. Everything here is built
// once and cached; nothing redraws continuously (PLAN.md §5).

enum WheelFont {
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

extension CGColor {
    /// sRGB colour from 0xRRGGBB (design tokens in PLAN.md §9).
    static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    static func white(_ alpha: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }
    static func black(_ alpha: CGFloat) -> CGColor { CGColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha) }

    /// Parses "#RRGGBB"; nil when malformed.
    static func hexString(_ string: String) -> CGColor? {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return .hex(v)
    }
}

/// Centred, single-line text layers sized to their string.
typealias LabelLayer = CATextLayer

func makeLabel() -> CATextLayer {
    let label = CATextLayer()
    label.alignmentMode = .center
    label.truncationMode = .none
    label.isWrapped = false
    label.actions = ["contents": NSNull(), "bounds": NSNull()]
    return label
}

/// Words the wheel had to shorten (for --check-themes: a label should never be cut).
enum TextFit {
    static var cuts: [String] = []
}

extension CATextLayer {
    /// Sets the text. `maxWidth` shrinks the font (down to `minScale`) to fit,
    /// or, with `wraps`, breaks it onto centred lines of that width.
    /// The first of `candidates` that fits `maxWidth` at `minScale` or larger
    /// ("Compress", then "SQZ"), so a big Studio label size never cuts a word
    /// in the middle. If none fits, the text may shrink further (to `floor`)
    /// before the last one is shortened. An empty candidate means "leave it out".
    /// `wrap`: a two-word label that still doesn't fit goes onto two lines ("COPY / TO") before anything is cut.
    func setFitting(_ candidates: [String], font: NSFont, color: CGColor, kern: CGFloat = 0, maxWidth: CGFloat,
                    minScale: CGFloat = 0.7, floor: CGFloat = 0.5, wrap: Bool = false) {
        func fits(_ text: String, at scale: CGFloat) -> Bool {
            guard !text.isEmpty else { return true }
            let smaller = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font
            return CATextLayer.attributed(text, font: smaller, color: color, kern: kern * scale).size().width <= maxWidth
        }
        if let pick = candidates.first(where: { fits($0, at: minScale) }) {
            set(pick, font: font, color: color, kern: kern, maxWidth: maxWidth, minScale: minScale)
        } else if let pick = candidates.first(where: { fits($0, at: floor) }) {
            set(pick, font: font, color: color, kern: kern, maxWidth: maxWidth, minScale: floor)
        } else if wrap, let last = candidates.last, last.contains(" "),
                  last.split(separator: " ").allSatisfy({ fits(String($0), at: floor) }) {
            let small = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * floor) ?? font
            set(last.replacingOccurrences(of: " ", with: "\n"), font: small, color: color, kern: kern * floor)
        } else {
            set(candidates.last ?? "", font: font, color: color, kern: kern, maxWidth: maxWidth, minScale: floor)
        }
    }

    func set(_ text: String, font: NSFont, color: CGColor, kern: CGFloat = 0,
             maxWidth: CGFloat? = nil, minScale: CGFloat = 0.75, wraps: Bool = false) {
        var font = font
        var attributed = CATextLayer.attributed(text, font: font, color: color, kern: kern)
        if wraps, let maxWidth, attributed.size().width > maxWidth {
            let fitted = attributed.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin, .usesFontLeading])
            isWrapped = true
            string = attributed
            bounds = CGRect(x: 0, y: 0, width: maxWidth, height: ceil(fitted.height))
            return
        }
        isWrapped = false
        if let maxWidth, attributed.size().width > maxWidth {
            // Glyph widths don't scale exactly with the size: aim a little under,
            // and nudge smaller (still within minScale) if rounding leaves it wide.
            let base = font
            var factor = max(minScale, maxWidth / attributed.size().width * 0.98)
            font = NSFont(descriptor: base.fontDescriptor, size: base.pointSize * factor) ?? base
            attributed = CATextLayer.attributed(text, font: font, color: color, kern: kern * factor)
            while attributed.size().width > maxWidth, factor > minScale {
                factor = max(minScale, factor * 0.96)
                font = NSFont(descriptor: base.fontDescriptor, size: base.pointSize * factor) ?? base
                attributed = CATextLayer.attributed(text, font: font, color: color, kern: kern * factor)
            }
            // Still too wide at the smallest size: shorten in the middle, so a
            // long file name keeps its start, its extension and the size.
            if attributed.size().width > maxWidth {
                TextFit.cuts.append("\(text) [w\(Int(maxWidth)) f\(Int(font.pointSize))]")
                let fitted = CATextLayer.middleTruncated(text, toFit: maxWidth) { candidate in
                    CATextLayer.attributed(candidate, font: font, color: color, kern: kern * factor).size().width
                }
                attributed = CATextLayer.attributed(fitted, font: font, color: color, kern: kern * factor)
            }
        }
        string = attributed
        let size = attributed.size()
        bounds = CGRect(x: 0, y: 0, width: ceil(size.width) + 2, height: ceil(size.height))
    }

    /// The longest "start…end" form of `text` whose width fits.
    static func middleTruncated(_ text: String, toFit maxWidth: CGFloat, width: (String) -> CGFloat) -> String {
        let chars = Array(text)
        func candidate(_ keep: Int) -> String {
            let tail = keep / 2
            return String(chars.prefix(keep - tail)) + "…" + String(chars.suffix(tail))
        }
        var low = 0, high = chars.count - 1, best = "…"
        while low <= high {
            let mid = (low + high) / 2
            let c = candidate(mid)
            if width(c) <= maxWidth { best = c; low = mid + 1 } else { high = mid - 1 }
        }
        return best
    }

    fileprivate static func attributed(_ text: String, font: NSFont, color: CGColor, kern: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? .white,
            .kern: kern,
            .paragraphStyle: paragraph,
        ])
    }
}

enum SymbolCache {
    private static var cache: [String: CGImage] = [:]

    /// An SF Symbol rendered in one colour at the given scale.
    static func image(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: CGColor,
                      scale: CGFloat) -> CGImage? {
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(color)|\(scale)"
        if let hit = cache[key] { return hit }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let size = symbol.size
        let image = renderImage(size: size, scale: scale) { context in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            symbol.draw(in: CGRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            context.setBlendMode(.sourceAtop)
            context.setFillColor(color)
            context.fill(CGRect(origin: .zero, size: size))
        }
        cache[key] = image
        return image
    }
}

/// Draws into a bitmap of `size` points at `scale`, y-up.
func renderImage(size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
    let width = max(1, Int(ceil(size.width * scale))), height = max(1, Int(ceil(size.height * scale)))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.scaleBy(x: scale, y: scale)
    draw(context)
    return context.makeImage()
}

enum DiscImages {
    /// A drop shadow around a circle, with the circle itself cut out, so the
    /// shadow never darkens what shows through the translucent disc (CSS box-shadow).
    static func outerShadow(diameter: CGFloat, offsetY: CGFloat, blur: CGFloat, color: CGColor,
                            canvas: CGFloat, scale: CGFloat) -> CGImage? {
        renderImage(size: CGSize(width: canvas, height: canvas), scale: scale) { ctx in
            let disc = CGRect(x: (canvas - diameter) / 2, y: (canvas - diameter) / 2, width: diameter, height: diameter)
            ctx.saveGState()
            // CSS blur ≈ 2 × CG blur; CSS y-down offset → CG y-up.
            ctx.setShadow(offset: CGSize(width: 0, height: -offsetY), blur: blur / 2, color: color)
            ctx.setFillColor(.black(1))
            ctx.fillEllipse(in: disc)
            ctx.restoreGState()
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: disc)
        }
    }

    /// An inset glow from the top edge, clipped to the circle (CSS inset box-shadow).
    static func innerGlow(diameter: CGFloat, offsetY: CGFloat, blur: CGFloat, color: CGColor, scale: CGFloat) -> CGImage? {
        renderImage(size: CGSize(width: diameter, height: diameter), scale: scale) { ctx in
            let disc = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            ctx.addEllipse(in: disc)
            ctx.clip()
            let ring = CGMutablePath()
            ring.addRect(disc.insetBy(dx: -blur * 2, dy: -blur * 2))
            ring.addEllipse(in: disc)
            ctx.setShadow(offset: CGSize(width: 0, height: -offsetY), blur: blur / 2, color: color)
            ctx.setFillColor(.black(1))
            ctx.addPath(ring)
            ctx.fillPath(using: .evenOdd)
        }
    }
}

/// An annular sector in **y-up** layer space, centred on `center`.
/// Angles are clock angles (0 = 12 o'clock, clockwise).
func sectorPath(center: CGPoint, inner: CGFloat, outer: CGFloat, from a0: CGFloat, to a1: CGFloat) -> CGPath {
    func rad(_ clock: CGFloat) -> CGFloat { (90 - clock) * .pi / 180 }
    let path = CGMutablePath()
    path.addArc(center: center, radius: outer, startAngle: rad(a0), endAngle: rad(a1), clockwise: true)
    path.addArc(center: center, radius: inner, startAngle: rad(a1), endAngle: rad(a0), clockwise: false)
    path.closeSubpath()
    return path
}

/// `sectorPath` with rounded corners (`round` 0 … 1 of the largest radius that
/// fits), the Wheel Studio's "Corner rounding". Each corner is a true fillet:
/// a circle touching both the straight edge and the curved one (outer corners
/// sit inside the outer circle, inner corners outside the inner one). Built
/// y-down like the Studio's canvas, then flipped into y-up layer space; rest
/// and hover paths have the same elements, so the bulge still animates.
func roundedSectorPath(center: CGPoint, inner: CGFloat, outer: CGFloat, from c0: CGFloat, to c1: CGFloat, round: CGFloat) -> CGPath {
    guard round > 0.001 else { return sectorPath(center: center, inner: inner, outer: outer, from: c0, to: c1) }
    let rin = max(1, inner), rout = max(rin + 1, outer)
    let a0 = (c0 - 90) * .pi / 180, a1 = (c1 - 90) * .pi / 180
    let half = sin(min(.pi / 2 - 0.01, (a1 - a0) / 2))
    let rr = max(0.5, min(1, round) * min((rout - rin) / 2, rin * half / (1 - half)) * 0.98)
    func p(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: cos(a) * r, y: sin(a) * r) }
    let dOut = asin(rr / (rout - rr)), dIn = asin(rr / (rin + rr))
    let o0 = a0 + dOut, o1 = a1 - dOut, i0 = a0 + dIn, i1 = a1 - dIn
    let path = CGMutablePath()
    path.move(to: p((rin + rr) * cos(dIn), a0))
    path.addLine(to: p((rout - rr) * cos(dOut), a0))
    path.addArc(center: p(rout - rr, o0), radius: rr, startAngle: a0 - .pi / 2, endAngle: o0, clockwise: false)
    path.addArc(center: .zero, radius: rout, startAngle: o0, endAngle: o1, clockwise: false)
    path.addArc(center: p(rout - rr, o1), radius: rr, startAngle: o1, endAngle: a1 + .pi / 2, clockwise: false)
    path.addLine(to: p((rin + rr) * cos(dIn), a1))
    path.addArc(center: p(rin + rr, i1), radius: rr, startAngle: a1 + .pi / 2, endAngle: i1 + .pi, clockwise: false)
    path.addArc(center: .zero, radius: rin, startAngle: i1, endAngle: i0, clockwise: true)
    path.addArc(center: p(rin + rr, i0), radius: rr, startAngle: i0 + .pi, endAngle: a0 + .pi * 1.5, clockwise: false)
    path.closeSubpath()
    var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: center.x, ty: center.y)
    return path.copy(using: &flip) ?? path
}

/// Converts a y-down offset from the wheel centre to a y-up layer point.
func layerPoint(_ offset: CGPoint, center: CGPoint) -> CGPoint {
    CGPoint(x: center.x + offset.x, y: center.y - offset.y)
}

/// The placeholder picture from the boards (peach sky, orange sun, green hills),
/// used by previews and the tutorial when no real thumbnail exists.
func samplePicture(size: CGFloat, scale: CGFloat) -> CGImage? {
    renderImage(size: CGSize(width: size, height: size), scale: scale) { ctx in
        let k = size / 84
        ctx.setFillColor(.hex(0xF6C79B))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(.hex(0xFF8A00))
        ctx.fillEllipse(in: CGRect(x: (56 - 11) * k, y: size - (32 + 11) * k, width: 22 * k, height: 22 * k))
        let hills = CGMutablePath()
        let pts: [(CGFloat, CGFloat)] = [(0, 60), (26, 38), (46, 56), (62, 44), (84, 62), (84, 84), (0, 84)]
        hills.addLines(between: pts.map { CGPoint(x: $0.0 * k, y: size - $0.1 * k) })
        hills.closeSubpath()
        ctx.setFillColor(.hex(0x3E6B5A))
        ctx.addPath(hills)
        ctx.fillPath()
    }
}

enum Motion {
    /// Settings → Wheel → animation speed (0.5 … 2). Springs keep their
    /// shape and settle `speed` times faster; fixed durations divide by it.
    static var speed: Double = 1 {
        didSet { speed = min(2, max(0.5, speed)) }
    }

    static func duration(_ seconds: CFTimeInterval) -> CFTimeInterval { seconds / speed }

    /// The spring used for the bulge and morphs.
    static func spring(_ keyPath: String, from: Any?, to: Any?, delay: CFTimeInterval = 0) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.mass = 1
        a.stiffness = 320 * speed * speed
        a.damping = 22 * speed
        a.initialVelocity = 0
        a.duration = a.settlingDuration
        if delay > 0 {
            a.beginTime = CACurrentMediaTime() + delay / speed
            a.fillMode = .backwards
        }
        return a
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    static var differentiateWithoutColor: Bool { NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor }
}
