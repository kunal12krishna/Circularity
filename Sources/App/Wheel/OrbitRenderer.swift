import AppKit
import QuartzCore

/// Orbit (board B): six separate floating round buttons on a dashed guide,
/// a light orb with a thumbnail stack, pill-shaped More fan chips and a dark
/// pill near the cursor naming the action (PLAN.md §3.3).
final class OrbitRenderer: WheelRenderer {
    let layer = CALayer()
    let usesGlass = false
    var allowsTilt = true

    private var geometry = WheelGeometry.orbit()
    private var menu = WheelMenu(ring: Array(repeating: nil, count: 6), fan: [], notice: nil)
    private var accent: CGColor = .hex(0xFF8A00)
    private var look = WheelStyle.board(accent: 0xFF8A00, light: true)
    private var contentsScale: CGFloat = 2
    private var content = OrbContent(fileLine: "", title: "", detail: "", count: 1, thumbnail: nil, clickMode: false)
    private var state = WheelVisualState()
    private var center: CGPoint { CGPoint(x: geometry.size / 2, y: geometry.size / 2) }

    /// Board B is light; the dark scheme swaps the surfaces and the ink.
    private struct Palette {
        var ink: CGColor, secondary: CGColor, button: CGColor, buttonBorder: CGColor
        var pill: CGColor, orb: CGColor, cursorPill: CGColor, cursorInk: CGColor, guide: CGColor

        static let light = Palette(ink: .hex(0x1D1B18), secondary: .hex(0x5E574D), button: .white(0.72),
                                   buttonBorder: OrbitRenderer.warmColor(0.12), pill: .white(0.82), orb: .white(0.78),
                                   cursorPill: .hex(0x1D1B18), cursorInk: .white(1), guide: OrbitRenderer.warmColor(0.16))
        static let dark = Palette(ink: .hex(0xF4F1EC), secondary: .hex(0xB4AEA5), button: .hex(0x26262B, 0.88),
                                  buttonBorder: .white(0.12), pill: .hex(0x26262B, 0.9), orb: .hex(0x1E1E22, 0.88),
                                  cursorPill: .hex(0xF4F1EC), cursorInk: .hex(0x1D1B18), guide: .white(0.16))
    }
    private var palette = Palette.light
    private var ink: CGColor { palette.ink }
    private static let warm = (r: 60.0 / 255, g: 40.0 / 255, b: 20.0 / 255)
    private static func warmColor(_ a: CGFloat) -> CGColor { CGColor(srgbRed: warm.r, green: warm.g, blue: warm.b, alpha: a) }

    private let guide = CAShapeLayer()
    private let buttonsLayer = CALayer()
    private let fanLayer = CALayer()
    private let orb = CALayer()
    private let orbDisc = CAShapeLayer()
    private let cards = [CALayer(), CALayer(), CALayer()]
    private let badge = CALayer()
    private let badgeLabel = makeLabel()
    private let orbTitle = makeLabel()
    private let orbDetail = makeLabel()
    private let pill = CALayer()
    private let pillLabel = makeLabel()

    private struct Button {
        let group = CALayer()
        let disc = CALayer()
        let tint = CALayer()
        let icon = CALayer()
        let label = makeLabel()
        var hot = false
    }

    private struct Pill {
        let group = CALayer()
        let label = makeLabel()
        var hot = false
    }

    private var buttons: [Button] = []
    private var pills: [Pill] = []

    init() {
        for l in [guide, buttonsLayer, fanLayer, orb, pill] as [CALayer] { layer.addSublayer(l) }
        orb.addSublayer(orbDisc)
        for c in cards { orb.addSublayer(c) }
        orb.addSublayer(badge)
        badge.addSublayer(badgeLabel)
        orb.addSublayer(orbTitle)
        orb.addSublayer(orbDetail)
        pill.addSublayer(pillLabel)
        for _ in 0..<WheelGeometry.segmentCount {
            let b = Button()
            b.group.addSublayer(b.disc)
            b.group.addSublayer(b.tint)
            b.group.addSublayer(b.icon)
            b.group.addSublayer(b.label)
            buttonsLayer.addSublayer(b.group)
            buttons.append(b)
        }
    }

    /// Board B's per-category icon tints (background, glyph), or the user's tint.
    private func tint(for slot: WheelSlot) -> (CGColor, CGColor) {
        if let custom = look.tint(for: slot) {
            let glyph = ThemeCatalog.onAccent(RGB(cg: custom))
            return (custom, glyph.cgColor)
        }
        switch slot.category {
        case .more: return (.hex(0xE4E0DA), .hex(0x3D3831))
        case .tool: return (.hex(0xD7E5F5), .hex(0x1F4D80))
        case .format:
            if case let .convert(f) = slot.action, f.imageTypeIdentifier != nil { return (.hex(0xFFE2C2), .hex(0x8A4300)) }
            if case .pdfPages = slot.action { return (.hex(0xFFE2C2), .hex(0x8A4300)) }
            return (.hex(0xFAD4D0), .hex(0x8E2A1F))
        }
    }

    func configure(menu: WheelMenu, orb content: OrbContent, style look: WheelStyle, geometry g: WheelGeometry,
                   contentsScale: CGFloat) {
        transact(0, animated: false) {
            self.menu = menu
            self.look = look
            self.accent = look.accent
            palette = look.light ? .light : .dark
            self.content = content
            self.contentsScale = contentsScale
            geometry = g
            state = WheelVisualState()
            let s = g.scale
            layer.bounds = CGRect(x: 0, y: 0, width: g.size, height: g.size)
            for l in [layer, guide, buttonsLayer, fanLayer, orb, orbDisc, badge, badgeLabel, orbTitle, orbDetail, pill, pillLabel] as [CALayer] {
                l.contentsScale = contentsScale
            }
            for l in [guide, buttonsLayer, fanLayer] as [CALayer] { l.frame = layer.bounds }

            let r = g.buttonRadius * s
            guide.path = CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r), transform: nil)
            guide.fillColor = nil
            guide.strokeColor = palette.guide
            guide.lineWidth = 1.5 * s
            guide.lineDashPattern = [NSNumber(value: Double(5 * s)), NSNumber(value: Double(5 * s))]

            for i in buttons.indices { configureButton(i) }
            rebuildPills()
            configureOrb()
            configurePill()
            apply(state, animated: false)
        }
    }

    private func configureButton(_ i: Int) {
        let s = geometry.scale, d = geometry.buttonDiameter * s
        var b = buttons[i]
        b.hot = false
        for l in [b.group, b.disc, b.tint, b.icon, b.label] as [CALayer] { l.contentsScale = contentsScale }
        b.group.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        b.group.position = layerPoint(WheelGeometry.offset(radius: geometry.buttonRadius * s,
                                                           angle: WheelGeometry.midAngle(ofSlot: i)), center: center)
        b.group.transform = CATransform3DIdentity
        guard let slot = menu.ring[i] else {
            b.group.isHidden = true
            buttons[i] = b
            return
        }
        b.group.isHidden = false
        b.disc.frame = b.group.bounds
        b.disc.cornerRadius = d / 2
        b.disc.borderWidth = 1
        b.disc.shadowColor = Self.warmColor(1)
        b.disc.shadowPath = CGPath(ellipseIn: b.group.bounds, transform: nil)
        let t = 32 * s
        b.tint.bounds = CGRect(x: 0, y: 0, width: t, height: t)
        b.tint.cornerRadius = t / 2
        let (_, glyph) = tint(for: slot)
        if let image = SymbolCache.image(slot.symbol, pointSize: 14 * s, weight: .semibold, color: glyph, scale: contentsScale) {
            b.icon.contents = image
            b.icon.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / contentsScale, height: CGFloat(image.height) / contentsScale)
        }
        b.label.set(look.label(slot.label), font: look.labelFont(12 * s * look.labelScale, .bold), color: ink,
                    maxWidth: d - 8 * s, minScale: 0.7)
        // Column: tint disc 32, gap 5, label.
        let total = t + 5 * s + b.label.bounds.height
        b.tint.position = CGPoint(x: d / 2, y: d / 2 + total / 2 - t / 2)
        b.icon.position = b.tint.position
        b.label.position = CGPoint(x: d / 2, y: d / 2 - total / 2 + b.label.bounds.height / 2)
        buttons[i] = b
        styleButton(i, hot: false, animated: false)
    }

    private func styleButton(_ i: Int, hot: Bool, animated: Bool) {
        guard let slot = menu.ring[i] else { return }
        let b = buttons[i], s = geometry.scale
        b.label.set(look.label(slot.label), font: look.labelFont(12 * s * look.labelScale, .bold), color: hot ? look.onAccent : ink,
                    maxWidth: geometry.buttonDiameter * s - 8 * s, minScale: 0.7)
        transact(0.14, animated: animated) {
            b.disc.backgroundColor = hot ? accent : palette.button
            b.disc.borderColor = hot ? .white(0.9) : palette.buttonBorder
            b.disc.shadowColor = hot ? CGColor(srgbRed: 160 / 255, green: 80 / 255, blue: 0, alpha: 1) : Self.warmColor(1)
            b.disc.shadowOpacity = hot ? 0.35 : 0.14
            b.disc.shadowRadius = (hot ? 17 : 13) * s
            b.disc.shadowOffset = CGSize(width: 0, height: -(hot ? 16 : 10) * s)
            b.tint.backgroundColor = hot ? .white(0.85) : tint(for: slot).0
        }
        buttons[i].hot = hot
    }

    private func rebuildPills() {
        for p in pills { p.group.removeFromSuperlayer() }
        let s = geometry.scale
        pills = menu.fan.map { slot in
            let p = Pill()
            p.group.addSublayer(p.label)
            fanLayer.addSublayer(p.group)
            for l in [p.group, p.label] as [CALayer] { l.contentsScale = contentsScale }
            let text = slot.category == .tool ? "\(slot.label)…" : slot.label
            p.label.set(look.label(text), font: look.labelFont(12 * s * look.labelScale, .bold), color: ink)
            let h = 36 * s, w = p.label.bounds.width + 28 * s
            p.group.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            p.group.cornerRadius = h / 2
            p.group.borderWidth = 1
            p.group.borderColor = palette.buttonBorder
            p.group.backgroundColor = palette.pill
            p.group.shadowColor = Self.warmColor(1)
            p.group.shadowOpacity = 0.16
            p.group.shadowRadius = 10 * s
            p.group.shadowOffset = CGSize(width: 0, height: -8 * s)
            p.group.shadowPath = CGPath(roundedRect: p.group.bounds, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
            p.label.position = CGPoint(x: w / 2, y: h / 2)
            p.group.opacity = 0
            return p
        }
    }

    private func configureOrb() {
        let s = geometry.scale, d = geometry.orbDiameter * s
        orb.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        orb.position = center
        orbDisc.frame = orb.bounds
        orbDisc.path = CGPath(ellipseIn: orb.bounds.insetBy(dx: 0.75 * s, dy: 0.75 * s), transform: nil)
        orbDisc.fillColor = palette.orb
        orbDisc.strokeColor = palette.buttonBorder
        orbDisc.lineWidth = 1.5 * s
        orbDisc.shadowPath = CGPath(ellipseIn: orb.bounds, transform: nil)
        orbDisc.shadowColor = Self.warmColor(1)
        orbDisc.shadowOpacity = 0.18
        orbDisc.shadowRadius = 20 * s
        orbDisc.shadowOffset = CGSize(width: 0, height: -18 * s)

        // Thumbnail stack in a 70 × 56 box near the top (board B positions, y-down).
        let card = 46 * s
        let box = CGRect(x: d / 2 - 35 * s, y: 0, width: 70 * s, height: 56 * s)
        let titleH: CGFloat = 16 * s, detailH: CGFloat = 14 * s
        let total = box.height + 4 * s + titleH + 4 * s + detailH
        let boxTop = d / 2 + total / 2 // y-up
        func place(_ layer: CALayer, x: CGFloat, y: CGFloat, angle: CGFloat, color: CGColor) {
            layer.contentsScale = contentsScale
            layer.bounds = CGRect(x: 0, y: 0, width: card, height: card)
            layer.cornerRadius = 9 * s
            layer.masksToBounds = true
            layer.backgroundColor = color
            layer.position = CGPoint(x: box.minX + x + card / 2, y: boxTop - y - card / 2)
            layer.transform = CATransform3DMakeRotation(-angle * .pi / 180, 0, 0, 1)
            layer.contentsGravity = .resizeAspectFill
        }
        let multiple = content.count > 1
        place(cards[0], x: 14 * s, y: 0, angle: 10, color: .hex(0x7FB3E8))
        place(cards[1], x: 4 * s, y: 4 * s, angle: -8, color: .hex(0xC9DCC4))
        place(cards[2], x: 10 * s, y: 8 * s, angle: 0, color: .hex(0xF6C79B))
        cards[0].isHidden = !multiple
        cards[1].isHidden = !multiple
        cards[2].contents = content.thumbnail ?? samplePicture(size: card, scale: contentsScale)

        badge.isHidden = !multiple
        if multiple {
            badgeLabel.set("\(content.count)", font: WheelFont.rounded(12 * s, .heavy), color: look.onAccent)
            let h = 22 * s, w = max(h, badgeLabel.bounds.width + 10 * s)
            badge.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            badge.cornerRadius = h / 2
            badge.backgroundColor = accent
            badge.position = CGPoint(x: box.maxX + 6 * s - w / 2, y: boxTop + 6 * s - h / 2)
            badgeLabel.position = CGPoint(x: w / 2, y: h / 2)
        }
        orbTitle.position = CGPoint(x: d / 2, y: boxTop - box.height - 4 * s - titleH / 2)
        orbDetail.position = CGPoint(x: d / 2, y: boxTop - box.height - 8 * s - titleH - detailH / 2)
    }

    private func configurePill() {
        let s = geometry.scale
        pill.backgroundColor = palette.cursorPill
        pill.shadowColor = .black(1)
        pill.shadowOpacity = 0.22
        pill.shadowRadius = 10 * s
        pill.shadowOffset = CGSize(width: 0, height: -8 * s)
        pill.opacity = 0
    }

    func updateHints(_ newMenu: WheelMenu) { menu = newMenu }

    func setThumbnail(_ image: CGImage?) {
        transact(0.15, animated: true) { cards[2].contents = image ?? samplePicture(size: 46 * geometry.scale, scale: contentsScale) }
    }

    // MARK: State

    func apply(_ newState: WheelVisualState, animated: Bool) {
        let animate = animated && !Motion.reduceMotion
        let previous = state
        state = newState
        let s = geometry.scale
        let hotIndex: Int? = {
            if case let .segment(i) = newState.hover, menu.ring[i] != nil { return i }
            return nil
        }()
        let chipHot: Int? = {
            if case let .fanChip(k) = newState.hover, k < pills.count { return k }
            return nil
        }()
        let somethingHot = hotIndex != nil || chipHot != nil

        for i in buttons.indices where menu.ring[i] != nil {
            let hot = hotIndex == i || (i == menu.moreIndex && newState.fanOpen)
            if hot != buttons[i].hot {
                styleButton(i, hot: hot, animated: animate)
                let scale = hot ? geometry.buttonHoverScale : 1
                let t = CATransform3DMakeScale(scale, scale, 1)
                let g = buttons[i].group
                if animate {
                    g.add(Motion.spring("transform", from: NSValue(caTransform3D: g.presentation()?.transform ?? g.transform),
                                        to: NSValue(caTransform3D: t)), forKey: "transform")
                }
                transact(0, animated: false) { g.transform = t }
            }
            let opacity: Float = somethingHot && !hot ? 0.6 : 1
            transact(0.14, animated: animate) { buttons[i].group.opacity = opacity }
        }

        let fanChanged = previous.fanOpen != newState.fanOpen || previous.fanFlipped != newState.fanFlipped
        let angles = geometry.fanAngles(count: pills.count, flipped: newState.fanFlipped)
        for (k, p) in pills.enumerated() {
            if fanChanged {
                let o = WheelGeometry.offset(radius: geometry.fanRadius * s, angle: angles[k])
                transact(0, animated: false) { p.group.position = layerPoint(o, center: center) }
                transact(animate ? 0.12 : 0, animated: animate) { p.group.opacity = newState.fanOpen ? 1 : 0 }
            }
            let hot = chipHot == k
            if hot != p.hot {
                pills[k].hot = hot
                let scale = hot ? geometry.fanHoverScale : 1
                let slot = menu.fan[k]
                let text = slot.category == .tool ? "\(slot.label)…" : slot.label
                p.label.set(look.label(text), font: look.labelFont(12 * s * look.labelScale, .bold), color: hot ? look.onAccent : ink)
                transact(0.14, animated: animate) {
                    p.group.backgroundColor = hot ? accent : palette.pill
                    p.group.transform = CATransform3DMakeScale(scale, scale, 1)
                }
            }
        }

        // Orb text and Cancel border.
        let cancelHot = newState.hover == .centre
        let title: String, detail: String
        if cancelHot {
            (title, detail) = ("Cancel", "nothing is changed")
        } else if let notice = menu.notice {
            (title, detail) = (notice.big, notice.detail)
        } else {
            (title, detail) = (content.title, content.detail)
        }
        orbTitle.set(title, font: look.labelFont(12 * s * look.labelScale, .bold), color: ink, maxWidth: geometry.orbDiameter * s * 0.8, minScale: 0.75)
        orbDetail.set(detail, font: WheelFont.rounded(11 * s * look.labelScale, .regular), color: palette.secondary,
                      maxWidth: geometry.orbDiameter * s * 0.8, minScale: 0.75)
        transact(0.12, animated: animate) { orbDisc.strokeColor = cancelHot ? .hex(0xD9443A) : palette.buttonBorder }

        // Cursor pill with the action's verb.
        let verb: String? = cancelHot ? "Cancel" : menu.slot(for: newState.hover)?.verb
        if let verb, let cursor = newState.cursor {
            pillLabel.set(verb, font: WheelFont.rounded(13 * s, .semibold), color: palette.cursorInk)
            let w = pillLabel.bounds.width + 24 * s, h = pillLabel.bounds.height + 14 * s
            let below = cursor.y + 30 * s + h < geometry.size / 2
            let x = min(cursor.x - 4 * s + w / 2, geometry.size / 2 - w / 2)
            let y = below ? cursor.y + 30 * s + h / 2 : cursor.y - 44 * s + h / 2
            transact(0, animated: false) {
                pill.bounds = CGRect(x: 0, y: 0, width: w, height: h)
                pill.cornerRadius = h / 2
                pill.shadowPath = CGPath(roundedRect: pill.bounds, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
                pillLabel.position = CGPoint(x: w / 2, y: h / 2)
                pill.position = layerPoint(CGPoint(x: x, y: y), center: center)
            }
            transact(0.1, animated: animate) { pill.opacity = 1 }
        } else {
            transact(0.1, animated: animate) { pill.opacity = 0 }
        }
    }

    func popIn() {
        guard !Motion.reduceMotion else { return }
        let now = CACurrentMediaTime()
        for (i, b) in buttons.enumerated() where !b.group.isHidden {
            let grow = CASpringAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.6; grow.toValue = 1; grow.stiffness = 320 * Motion.speed * Motion.speed; grow.damping = 20 * Motion.speed
            grow.duration = grow.settlingDuration
            grow.beginTime = now + Motion.duration(Double(i) * 0.025); grow.fillMode = .backwards
            b.group.add(grow, forKey: "pop")
        }
    }

    func release(to target: WheelTarget, from offset: CGPoint?) {
        let g: CALayer?
        switch target {
        case let .segment(i): g = buttons[i].group
        case let .fanChip(k) where k < pills.count: g = pills[k].group
        default: g = nil
        }
        guard let g else { return }
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.16; pulse.toValue = 0.9; pulse.duration = 0.2
        g.add(pulse, forKey: "release")
    }
}
