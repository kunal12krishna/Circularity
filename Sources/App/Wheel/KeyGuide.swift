import AppKit

/// The key guide: a row of keycaps floating just above the wheel —
/// `⇧ CONVERT  ⌘ TOOLS  ⌃ ACTIONS` — with the wheel you're on lit up, so it's
/// always clear which key does what and that another tap switches. It takes
/// its colours, font, case and tracking from the wheel's own style, so the
/// three layouts and every Wheel Studio theme draw it in their own look.
/// Drawn above the wheel, or below it when the More fan opens upwards.
final class KeyGuideLayer {
    /// Added once above the renderer; everything is drawn inside it.
    let layer = CALayer()
    private struct Pill {
        let group = CALayer()
        let cap = CAShapeLayer()
        let symbol = makeLabel()
        let name = makeLabel()
    }

    private var pills: [WheelKind: Pill] = [:]
    private var order: [WheelKind] = []
    private var current: WheelKind = .convert
    private var look: WheelStyle?
    private var s: CGFloat = 1

    init() {
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
    }

    var isHidden: Bool {
        get { layer.isHidden }
        set { layer.isHidden = newValue }
    }

    /// Lays out the guide for the wheels that have a key. Hidden when fewer than two do.
    /// `anchor`: the point (host coordinates, y up) the guide centres on.
    func configure(keys: WheelKeyMap, current: WheelKind, style: WheelStyle, scale: CGFloat, contentsScale: CGFloat) {
        look = style
        s = scale
        self.current = current
        order = WheelKind.allCases.filter { keys.key(for: $0) != nil }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        pills = [:]
        guard order.count >= 2 else {
            isHidden = true
            return
        }
        isHidden = false
        let height = 26 * s, gap = 8 * s
        var x: CGFloat = 0
        for kind in order {
            let pill = Pill()
                for part in [pill.group, pill.cap, pill.symbol, pill.name] as [CALayer] {
                part.contentsScale = contentsScale
                part.actions = ["position": NSNull(), "bounds": NSNull()]
            }
            pill.group.addSublayer(pill.cap)
            pill.group.addSublayer(pill.symbol)
            pill.group.addSublayer(pill.name)
            layer.addSublayer(pill.group)
            pills[kind] = pill
            let key = keys.key(for: kind) ?? ""
            let width = layoutPill(pill, kind: kind, key: key, height: height)
            pill.group.frame = CGRect(x: x, y: 0, width: width, height: height)
            x += width + gap
        }
        layer.bounds = CGRect(x: 0, y: 0, width: x - gap, height: height)
        setAccessibilityLabelText()
    }

    /// The wheel you're on changed: relight the caps (a short cross-fade).
    func select(_ kind: WheelKind, animated: Bool) {
        guard kind != current, pills[kind] != nil else { return }
        current = kind
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || Motion.reduceMotion)
        CATransaction.setAnimationDuration(Motion.duration(0.16))
        for (k, pill) in pills { paint(pill, hot: k == kind) }
        CATransaction.commit()
        if animated, !Motion.reduceMotion, let pill = pills[kind] {
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.86
            pop.toValue = 1
            pop.stiffness = 420
            pop.damping = 18
            pop.duration = min(pop.settlingDuration, 0.35)
            pill.group.add(pop, forKey: "pop")
        }
        setAccessibilityLabelText()
    }

    /// How far the wheel really reaches from its centre, as drawn: a quick
    /// quarter-size render of `layer`, ignoring soft glow and shadow. Studio
    /// looks change this a lot (pop, rims, stickers, dots, scale), so the guide
    /// measures instead of trusting the layout's nominal size.
    static func drawnRadius(of layer: CALayer, canvas: CGFloat) -> CGFloat? {
        let k: CGFloat = 0.5 // half size: thin outlines (Studio's outline style) still count
        let n = Int(canvas * k)
        guard n > 8, let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { return nil }
        ctx.scaleBy(x: k, y: k)
        layer.render(in: ctx)
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var first: Int?, last: Int?
        for y in 0..<n {
            for x in 0..<n where pixels[(y * n + x) * 4 + 3] > 150 { // paint, not the softer drop shadows and glow
                if first == nil { first = y }
                last = y
                break
            }
        }
        guard let first, let last else { return nil }
        let c = CGFloat(n) / 2
        return max(c - CGFloat(first), CGFloat(last + 1) - c) / k
    }

    /// How far the wheel reaches, for placing the guide: as drawn, plus room for
    /// a hovered button's pop; Ring's behind-window glass disc counts too.
    static func reach(of layer: CALayer, renderer: WheelRenderer, geometry: WheelGeometry) -> CGFloat {
        var drawn = drawnRadius(of: layer, canvas: geometry.size).map { $0 + 6 * geometry.scale }
        if renderer.usesGlass { drawn = max(drawn ?? 0, geometry.discDiameter / 2 * geometry.scale) }
        return drawn ?? geometry.outerExtent
    }

    /// Centred on `center` (host space, y up), just outside `radius`; below when `below`.
    func place(center: CGPoint, radius: CGFloat, below: Bool, canvas: CGFloat) {
        guard !isHidden else { return }
        let margin = 12 * s
        let h = layer.bounds.height
        let above = center.y + radius + margin + h / 2, under = center.y - radius - margin - h / 2
        let fitsAbove = above + h / 2 <= canvas - 2, fitsBelow = under - h / 2 >= 2
        // A big wheel (a Studio look with lots of pop) leaves no room on one side: use the other.
        var y = below ? (fitsBelow || !fitsAbove ? under : above) : (fitsAbove || !fitsBelow ? above : under)
        y = min(max(y, h / 2 + 2), canvas - h / 2 - 2)
        layer.position = CGPoint(x: center.x, y: y)
    }

    // MARK: Drawing

    private func layoutPill(_ pill: Pill, kind: WheelKind, key: String, height: CGFloat) -> CGFloat {
        guard let look else { return 0 }
        let pad = 10 * s, inner = 6 * s
        let symbolFont = NSFont.systemFont(ofSize: 12 * s * look.labelScale, weight: .semibold)
        let nameText = look.upperCase || look.font == "mono" ? kind.title.uppercased() : kind.title
        let nameFont = look.labelFont(11 * s * look.labelScale, look.weight == .regular ? .semibold : look.weight)
        pill.symbol.set(WheelKeyMap.symbol(key), font: symbolFont, color: .white)
        pill.name.set(nameText, font: nameFont, color: .white, kern: 0.6 * s + look.tracking * 11 * s)
        let width = pad + pill.symbol.bounds.width + inner + pill.name.bounds.width + pad
        pill.cap.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                               cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
        pill.cap.lineWidth = max(1, look.rimWidth) * s * 0.75
        pill.symbol.position = CGPoint(x: pad + pill.symbol.bounds.width / 2, y: height / 2)
        pill.name.position = CGPoint(x: pad + pill.symbol.bounds.width + inner + pill.name.bounds.width / 2, y: height / 2)
        paint(pill, hot: kind == current)
        return width
    }

    private func paint(_ pill: Pill, hot: Bool) {
        guard let look else { return }
        let disc = look.discColor ?? (look.light ? CGColor.hex(0xFFFFFF) : .hex(0x14161C))
        let ink = look.textColor ?? (look.light ? CGColor.hex(0x1D1B18) : .hex(0xECEEF2))
        let rest = disc.copy(alpha: 0.94) ?? disc
        pill.cap.fillColor = hot ? look.accent : rest
        pill.cap.strokeColor = hot ? look.accent : (look.rimColor ?? (look.light ? .black(0.12) : .white(0.14)))
        pill.cap.shadowColor = look.accent
        pill.cap.shadowRadius = 8 * s
        pill.cap.shadowOffset = .zero
        pill.cap.shadowOpacity = hot ? Float(min(0.6, max(0.2, look.glowAmount(halo: true)))) : 0
        let fg = hot ? (look.hotTextColor ?? look.onAccent) : ink
        pill.symbol.foregroundColor = fg
        recolour(pill.symbol, fg)
        recolour(pill.name, fg)
        pill.name.opacity = hot ? 1 : 0.78
        pill.symbol.opacity = hot ? 1 : 0.78
    }

    private func recolour(_ label: CATextLayer, _ color: CGColor) {
        guard let current = label.string as? NSAttributedString else { return }
        let text = NSMutableAttributedString(attributedString: current)
        text.addAttribute(.foregroundColor, value: NSColor(cgColor: color) ?? .white, range: NSRange(location: 0, length: text.length))
        label.string = text
    }

    private func setAccessibilityLabelText() {
        layer.name = order.map { "\($0.title)\($0 == current ? " (this wheel)" : "")" }.joined(separator: ", ")
    }

    /// For VoiceOver and tests: "Tools", which wheel is lit.
    var lit: WheelKind { current }
    var spoken: String { "Keys: " + (layer.name ?? "") }
}
