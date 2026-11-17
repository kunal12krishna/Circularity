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

extension CATextLayer {
    /// Sets the text. `maxWidth` shrinks the font (down to `minScale`) to fit,
    /// or, with `wraps`, breaks it onto centred lines of that width.
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
            let factor = max(minScale, maxWidth / attributed.size().width)
            font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * factor) ?? font
            attributed = CATextLayer.attributed(text, font: font, color: color, kern: kern * factor)
        }
        string = attributed
        let size = attributed.size()
        bounds = CGRect(x: 0, y: 0, width: ceil(size.width) + 2, height: ceil(size.height))
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
    /// The spring used for the bulge and morphs.
    static func spring(_ keyPath: String, from: Any?, to: Any?, delay: CFTimeInterval = 0) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.mass = 1
        a.stiffness = 320
        a.damping = 22
        a.initialVelocity = 0
        a.duration = a.settlingDuration
        if delay > 0 {
            a.beginTime = CACurrentMediaTime() + delay
            a.fillMode = .backwards
        }
        return a
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    static var differentiateWithoutColor: Bool { NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor }
}
