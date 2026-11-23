import AppKit
import QuartzCore

/// Ring (board D, default) and Halo (board C) — both are six annular sectors
/// around a centre orb with a More fan; they differ in tokens (PLAN.md §9.1).
final class SectorRenderer: WheelRenderer {
    enum Style { case ring, halo }

    private struct Tokens {
        var segRest: CGColor, segEmpty: CGColor, segStroke: CGColor?, segHotStroke: CGColor?
        var fgRest: CGColor, fgHot: CGColor, captionRest: CGColor
        var dimOthers: Bool
        var chipFill: CGColor, chipBorder: CGColor, chipFont: NSFont, chipKern: CGFloat, chipCorner: CGFloat?
    }

    let style: Style
    let layer = CALayer()
    var usesGlass: Bool { style == .ring }
    var allowsTilt = true

    private var tokens: Tokens
    private var geometry: WheelGeometry
    private var menu = WheelMenu(ring: Array(repeating: nil, count: 6), fan: [], notice: nil)
    private var accent: CGColor = .hex(0xFF8A00)
    private var look = WheelStyle.board(accent: 0xFF8A00)
    private var contentsScale: CGFloat = 2
    private var clickMode = false
    private var thumbnail: CGImage?
    private var state = WheelVisualState()
    private var center: CGPoint { CGPoint(x: geometry.size / 2, y: geometry.size / 2) }

    private let shadow = CALayer()
    private let disc = CAShapeLayer()
    private let glow = CALayer()
    private let band = CAShapeLayer()
    private let hairline = CAShapeLayer()
    private let segmentsLayer = CALayer()
    private let fanLayer = CALayer()
    private let orb = OrbLayer()

    private struct Segment {
        let group = CALayer()
        let shape = CAShapeLayer()
        let icon = CALayer()
        let label = makeLabel()
        let caption = makeLabel()
        var restIcon: CGImage?
        var hotIcon: CGImage?
        var hot = false
    }

    private struct Chip {
        let group = CALayer()
        let shape = CAShapeLayer()
        let label = makeLabel()
        var hot = false
    }

    private var segments: [Segment] = []
    private var chips: [Chip] = []

    init(style: Style) {
        self.style = style
        geometry = style == .ring ? .ring() : .halo()
        tokens = Self.tokens(style, look: look)

        for l in [shadow, disc, glow, band, hairline, segmentsLayer, fanLayer, orb.layer] as [CALayer] { layer.addSublayer(l) }
        // Perspective for the hovered segment's tilt.
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 900
        segmentsLayer.sublayerTransform = perspective
        for _ in 0..<WheelGeometry.segmentCount {
            let s = Segment()
            s.group.addSublayer(s.shape)
            s.group.addSublayer(s.icon)
            s.group.addSublayer(s.label)
            s.group.addSublayer(s.caption)
            segmentsLayer.addSublayer(s.group)
            segments.append(s)
        }
    }

    private static func tokens(_ style: Style, look: WheelStyle) -> Tokens {
        var t = boardTokens(style, look: look)
        // Wheel Studio looks: bright fills want near-black text; custom inks win.
        if look.brightFills { t.fgRest = .hex(0x0B0D10); t.captionRest = .black(0.55); t.fgHot = .hex(0x0B0D10) }
        if let ink = look.textColor { t.fgRest = ink; t.captionRest = ink.copy(alpha: 0.62) ?? ink }
        if let hot = look.hotTextColor { t.fgHot = hot }
        t.dimOthers = t.dimOthers && look.dimOthers
        return t
    }

    private static func boardTokens(_ style: Style, look: WheelStyle) -> Tokens {
        switch (style, look.light) {
        case (.ring, false):
            Tokens(segRest: .white(0.07), segEmpty: .white(0.03), segStroke: .white(0.10), segHotStroke: .white(0.35),
                   fgRest: .hex(0xF4F1EC), fgHot: look.onAccent, captionRest: .hex(0xC9C3B9), dimOthers: true,
                   chipFill: .hex(0x1C1C20, 0.72), chipBorder: .white(0.16),
                   chipFont: look.labelFont(12, .bold), chipKern: 0, chipCorner: nil)
        case (.ring, true):
            Tokens(segRest: .black(0.06), segEmpty: .black(0.03), segStroke: .black(0.10), segHotStroke: .black(0.25),
                   fgRest: .hex(0x1D1B18), fgHot: look.onAccent, captionRest: .hex(0x4A453E), dimOthers: true,
                   chipFill: .hex(0xFFFFFF, 0.86), chipBorder: .black(0.12),
                   chipFont: look.labelFont(12, .bold), chipKern: 0, chipCorner: nil)
        case (.halo, _):
            Tokens(segRest: .hex(0x1B1D23), segEmpty: .hex(0x15171C), segStroke: nil, segHotStroke: nil,
                   fgRest: .hex(0xECEEF2), fgHot: look.onAccent, captionRest: .hex(0x9097A6), dimOthers: false,
                   chipFill: .hex(0x1B1D23), chipBorder: .white(0.10),
                   chipFont: WheelFont.mono(12, .bold), chipKern: 0.72, chipCorner: 8)
        }
    }

    /// The resting fill of a segment: the fill style's, else its category tint, at the resting opacity.
    private func restFill(_ i: Int) -> CGColor {
        guard let slot = menu.ring[i] else { return tokens.segRest }
        if let fill = look.restFill(slot: slot, index: i) { return look.resting(fill) }
        guard let tint = look.tint(for: slot) else { return look.resting(tokens.segRest) }
        return look.resting(tint.copy(alpha: style == .ring ? 0.22 : 0.2) ?? tokens.segRest)
    }

    // MARK: Configure

    func configure(menu: WheelMenu, orb content: OrbContent, style look: WheelStyle, geometry g: WheelGeometry,
                   contentsScale: CGFloat) {
        transact(0, animated: false) {
            self.menu = menu
            self.look = look
            self.accent = look.accent
            tokens = Self.tokens(style, look: look)
            self.contentsScale = contentsScale
            clickMode = content.clickMode
            thumbnail = content.thumbnail
            geometry = g
            state = WheelVisualState()
            let s = g.scale, size = g.size
            layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            for l in [layer, shadow, disc, glow, band, hairline, segmentsLayer, fanLayer] { l.contentsScale = contentsScale }
            for l in [shadow, segmentsLayer, fanLayer, disc, band, hairline] as [CALayer] { l.frame = layer.bounds }

            let d = g.discDiameter * s
            let discRect = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
            // Soft shadows and glows are pure blur: a quarter-resolution bitmap
            // looks identical once scaled up and costs 1/16 of the memory.
            let blurScale: CGFloat = 0.5
            shadow.contents = style == .ring
                ? DiscImages.outerShadow(diameter: d, offsetY: 40 * s, blur: 90 * s, color: .black(0.5), canvas: size, scale: blurScale)
                : DiscImages.outerShadow(diameter: d, offsetY: 30 * s, blur: 80 * s, color: .black(0.7), canvas: size, scale: blurScale)
            shadow.opacity = Float(look.discShadow)
            disc.path = CGPath(ellipseIn: discRect, transform: nil)
            if style == .ring {
                let strength = min(1, max(0, look.glassStrength))
                disc.fillColor = look.discColor?.copy(alpha: strength) ?? (look.light ? .hex(0xFFFFFF, strength) : .hex(0x18181C, strength))
                disc.strokeColor = nil
                glow.frame = discRect
                glow.contents = DiscImages.innerGlow(diameter: d, offsetY: 2 * s, blur: 34 * s,
                                                     color: look.light ? .white(0.5) : .white(0.07), scale: blurScale)
                hairline.path = CGPath(ellipseIn: discRect.insetBy(dx: 0.5, dy: 0.5), transform: nil)
                hairline.strokeColor = look.rimColor ?? (look.light ? .black(0.10) : .white(0.12))
                hairline.lineWidth = look.rimWidth
                hairline.isHidden = look.rimWidth <= 0
                band.isHidden = true
            } else {
                // Board C: solid graphite disc, 1 pt white 5 % outline, accent
                // hairline at r 208 (22 %), dark band r 118…190.
                disc.fillColor = look.discColor ?? .hex(0x0D0F14)
                disc.strokeColor = .white(0.05)
                disc.lineWidth = 1
                glow.contents = nil
                let r = 208 * s
                hairline.path = CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r), transform: nil)
                hairline.strokeColor = look.rimColor ?? accent.copy(alpha: 0.22)
                hairline.lineWidth = look.rimWidth
                hairline.isHidden = look.rimWidth <= 0
                band.isHidden = false
                let rb = 154 * s
                band.path = CGPath(ellipseIn: CGRect(x: center.x - rb, y: center.y - rb, width: 2 * rb, height: 2 * rb), transform: nil)
                band.fillColor = nil
                // A custom disc keeps the band as a slightly lifted ring of the same colour.
                band.strokeColor = look.discColor.map { c in
                    let k: CGFloat = RGB(cg: c).luminance < 0.4 ? 0.04 : -0.04
                    let rgb = RGB(cg: c)
                    return CGColor(srgbRed: min(1, max(0, rgb.r + k)), green: min(1, max(0, rgb.g + k)), blue: min(1, max(0, rgb.b + k)), alpha: 1)
                } ?? .hex(0x141519)
                band.lineWidth = 72 * s
            }
            hairline.fillColor = nil

            for i in segments.indices { configureSegment(i) }
            rebuildChips()

            orb.configure(style: style == .ring ? .ring : .halo, scale: s, diameter: g.orbDiameter, look: look, contentsScale: contentsScale,
                          fileLine: content.fileLine, count: content.count, thumbnail: content.thumbnail)
            orb.layer.position = center
            apply(state, animated: false)
        }
    }

    func updateHints(_ newMenu: WheelMenu) {
        menu = newMenu
        orb.show(OrbText.make(menu: menu, state: state, clickMode: clickMode), animated: false)
    }

    func setThumbnail(_ image: CGImage?) {
        thumbnail = image
        orb.setThumbnail(image)
    }

    func playThumbnail(_ frames: [CGImage]?) { orb.playThumbnail(frames) }

    private func configureSegment(_ i: Int) {
        let s = geometry.scale
        var seg = segments[i]
        seg.group.frame = layer.bounds
        seg.shape.frame = layer.bounds
        for l in [seg.group, seg.shape, seg.icon, seg.label, seg.caption] as [CALayer] { l.contentsScale = contentsScale }
        seg.group.transform = CATransform3DIdentity
        seg.hot = false
        guard let slot = menu.ring[i] else {
            seg.icon.contents = nil
            seg.label.set("", font: look.labelFont(15 * s, .bold), color: tokens.fgRest)
            seg.caption.set("", font: WheelFont.rounded(10 * s, .semibold), color: tokens.captionRest)
            segments[i] = seg
            return
        }
        if style == .ring {
            seg.restIcon = SymbolCache.image(slot.symbol, pointSize: 22 * s, weight: .medium, color: tokens.fgRest, scale: contentsScale)
            seg.hotIcon = SymbolCache.image(slot.symbol, pointSize: 22 * s, weight: .medium, color: tokens.fgHot, scale: contentsScale)
            seg.icon.isHidden = !look.captions
            seg.caption.isHidden = true
        } else {
            seg.restIcon = nil
            seg.hotIcon = nil
            seg.icon.isHidden = true
            seg.caption.isHidden = !look.captions
        }
        segments[i] = seg
        styleSegmentContent(i, hot: false)
    }

    private func styleSegmentContent(_ i: Int, hot: Bool) {
        guard let slot = menu.ring[i] else { return }
        let s = geometry.scale
        let seg = segments[i]
        let fg = hot ? tokens.fgHot : tokens.fgRest
        let ls = look.labelScale
        if style == .ring {
            seg.label.setFitting([look.label(slot.label), look.label(slot.monoLabel)], font: look.labelFont(15 * s * ls, look.weight), color: fg,
                                 kern: 0.3 * s + look.tracking * 15 * s * ls, maxWidth: 96 * s, minScale: 0.7)
            if let image = hot ? seg.hotIcon : seg.restIcon {
                seg.icon.contents = image
                seg.icon.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / contentsScale,
                                         height: CGFloat(image.height) / contentsScale)
            }
        } else {
            seg.label.setFitting([slot.monoLabel], font: WheelFont.mono(15 * s * ls, look.weight), color: fg,
                                 kern: 1.2 * s + look.tracking * 15 * s * ls, maxWidth: 80 * s, minScale: 0.7, floor: 0.5)
            let caption: CGColor = hot ? hotCaptionColor : tokens.captionRest
            // A caption that can't fit is left out rather than cut.
            seg.caption.setFitting([slot.caption, ""], font: WheelFont.rounded(10 * s * ls, .semibold), color: caption,
                                   kern: 0.4 * s + look.tracking * 10 * s * ls, maxWidth: 80 * s, minScale: 0.7)
        }
    }

    /// Board C uses #2A3300 under its neon accent; other accents get the
    /// on-accent colour at 75 % (dark or white, whichever reads).
    private var hotCaptionColor: CGColor {
        if RGB(cg: accent).hexString == "#C6FF3D" { return .hex(0x2A3300) }
        return tokens.fgHot.copy(alpha: look.onAccentIsDark ? 0.75 : 0.85) ?? tokens.fgHot
    }

    private func rebuildChips() {
        for c in chips { c.group.removeFromSuperlayer() }
        chips = menu.fan.map { slot in
            let c = Chip()
            c.group.addSublayer(c.shape)
            c.group.addSublayer(c.label)
            fanLayer.addSublayer(c.group)
            for l in [c.group, c.shape, c.label] as [CALayer] { l.contentsScale = contentsScale }
            let s = geometry.scale
            let size = CGSize(width: geometry.fanChipSize.width * s, height: geometry.fanChipSize.height * s)
            c.group.bounds = CGRect(origin: .zero, size: size)
            c.shape.frame = c.group.bounds
            let corner = tokens.chipCorner.map { $0 * s } ?? size.height / 2
            c.shape.path = CGPath(roundedRect: c.group.bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: corner,
                                  cornerHeight: corner, transform: nil)
            c.shape.lineWidth = 1
            c.shape.shadowPath = c.shape.path
            c.group.opacity = 0
            _ = slot
            return c
        }
        for k in chips.indices { styleChip(k, hot: false, animated: false) }
    }

    /// A More chip in the theme's look: the ring buttons' fill style, inks,
    /// outline, glow, weight and tracking (the defaults draw the boards exactly).
    private func styleChip(_ k: Int, hot: Bool, animated: Bool) {
        let c = chips[k], slot = menu.fan[k], s = geometry.scale
        let text = style == .ring ? look.label(slot.label) : slot.monoLabel
        let size = tokens.chipFont.pointSize * s * look.labelScale
        let font = style == .ring ? look.labelFont(size, look.weight) : WheelFont.mono(size, look.weight)
        c.label.setFitting(style == .ring ? [text, look.label(slot.monoLabel)] : [text], font: font, color: hot ? tokens.fgHot : tokens.fgRest,
                           kern: tokens.chipKern * s + look.tracking * size, maxWidth: c.group.bounds.width - 6 * s, minScale: 0.6, wrap: true)
        c.label.position = CGPoint(x: c.group.bounds.midX, y: c.group.bounds.midY)
        let outline = look.fillStyle == "outline" && !hot
        let bright = look.brightFills && hot
        let glow = look.glowAmount(halo: style == .halo)
        transact(0.12, animated: animated) {
            c.shape.fillColor = look.fanFill(slot: slot, index: k, base: tokens.chipFill, hot: hot, categoryTint: true)
            c.shape.strokeColor = outline ? (look.tint(for: slot) ?? accent).copy(alpha: 0.7) : bright ? .white(1) : tokens.chipBorder
            c.shape.lineWidth = outline ? 2 : bright ? 3 : 1
            if hot && glow > 0 {
                c.shape.shadowColor = look.glowColor(sticker: WheelStyle.stickerColor(slot, index: k % WheelGeometry.segmentCount))
                c.shape.shadowRadius = 10 * s * glow / 0.6
                c.shape.shadowOffset = .zero
                c.shape.shadowOpacity = Float(min(0.95, 0.5 * glow / 0.6))
            } else if style == .ring {
                c.shape.shadowColor = .black(1)
                c.shape.shadowRadius = 12 * s
                c.shape.shadowOffset = CGSize(width: 0, height: -10 * s)
                c.shape.shadowOpacity = Float(0.4 * look.discShadow)
            } else {
                c.shape.shadowOpacity = 0
            }
        }
        chips[k].hot = hot
    }

    // MARK: State

    func apply(_ newState: WheelVisualState, animated: Bool) {
        let animate = animated && !Motion.reduceMotion
        let previous = state
        state = newState
        let hotIndex: Int? = {
            if case let .segment(i) = newState.hover, menu.ring[i] != nil { return i }
            return nil
        }()
        let chipHot: Int? = {
            if case let .fanChip(k) = newState.hover, k < chips.count { return k }
            return nil
        }()
        let moreIndex = menu.moreIndex
        let somethingHot = hotIndex != nil || chipHot != nil
        let rippleOrigin = hotIndex ?? (chipHot != nil ? moreIndex : nil)

        for i in segments.indices {
            let hot = menu.ring[i] != nil && (hotIndex == i || (i == moreIndex && newState.fanOpen))
            updateSegment(i, hot: hot, animated: animate)
            let dim = tokens.dimOthers && somethingHot && !hot
            let distance = rippleOrigin.map { min(abs($0 - i), 6 - abs($0 - i)) } ?? 0
            let opacity: Float = menu.ring[i] == nil ? 1 : (dim ? 0.55 : 1)
            if segments[i].group.opacity != opacity {
                if animate {
                    let a = CABasicAnimation(keyPath: "opacity")
                    a.fromValue = segments[i].group.presentation()?.opacity ?? segments[i].group.opacity
                    a.toValue = opacity
                    a.duration = 0.14
                    a.beginTime = CACurrentMediaTime() + Double(distance) * 0.03 // ripple outward
                    a.fillMode = .backwards
                    segments[i].group.add(a, forKey: "dim")
                }
                transact(0, animated: false) { segments[i].group.opacity = opacity }
            }
        }

        // Fan
        let fanChanged = previous.fanOpen != newState.fanOpen || previous.fanFlipped != newState.fanFlipped
        let offsets = geometry.fanOffsets(count: chips.count, flipped: newState.fanFlipped)
        for (k, chip) in chips.enumerated() {
            let target = layerPoint(offsets[k], center: center)
            if fanChanged || chip.group.position == .zero {
                transact(0, animated: false) { chip.group.position = target }
            }
            if fanChanged {
                let show = newState.fanOpen
                if animate && show {
                    let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
                    fade.duration = 0.14; fade.beginTime = CACurrentMediaTime() + Double(k) * 0.025; fade.fillMode = .backwards
                    chip.group.add(fade, forKey: "fan")
                    let more = moreIndex.map { WheelGeometry.offset(radius: geometry.contentRadius(hovered: true),
                                                                    angle: WheelGeometry.midAngle(ofSlot: $0)) } ?? .zero
                    let from = layerPoint(more, center: center)
                    chip.group.add(Motion.spring("position", from: NSValue(point: from), to: NSValue(point: target),
                                                 delay: Double(k) * 0.025), forKey: "position")
                }
                transact(animate ? 0.1 : 0, animated: animate) { chip.group.opacity = show ? 1 : 0 }
            }
            let hot = chipHot == k
            if hot != chip.hot {
                styleChip(k, hot: hot, animated: animate)
                let scale = hot ? geometry.fanHoverScale : 1
                let t = CATransform3DMakeScale(scale, scale, 1)
                if animate {
                    chip.group.add(Motion.spring("transform", from: NSValue(caTransform3D: chip.group.presentation()?.transform ?? chip.group.transform),
                                                 to: NSValue(caTransform3D: t)), forKey: "transform")
                }
                transact(0, animated: false) { chip.group.transform = t }
            }
        }

        orb.show(OrbText.make(menu: menu, state: newState, clickMode: clickMode), animated: animate)
    }

    private func updateSegment(_ i: Int, hot: Bool, animated: Bool) {
        let seg = segments[i]
        let mid = WheelGeometry.midAngle(ofSlot: i), half = geometry.segmentSpan / 2
        let path = roundedSectorPath(center: center, inner: geometry.inner(hovered: hot), outer: geometry.outer(hovered: hot),
                                     from: mid - half, to: mid + half, round: look.corners)
        let changed = seg.hot != hot || seg.shape.path == nil
        if changed {
            let from = seg.shape.presentation()?.path ?? seg.shape.path
            transact(0, animated: false) { seg.shape.path = path }
            if animated, let from { seg.shape.add(Motion.spring("path", from: from, to: path), forKey: "path") }
            segments[i].hot = hot
            styleSegmentContent(i, hot: hot)
        }
        let empty = menu.ring[i] == nil
        let dwc = Motion.differentiateWithoutColor && hot
        transact(0.12, animated: animated) {
            // A soft glow under the lit segment (Halo's neon by default; any layout can have one).
            let glow = look.glowAmount(halo: style == .halo)
            let slot = menu.ring[i]
            seg.shape.shadowColor = look.glowColor(sticker: slot.map { WheelStyle.stickerColor($0, index: i) })
            seg.shape.shadowRadius = 14 * geometry.scale * max(glow, 0.01) / 0.6
            seg.shape.shadowOffset = .zero
            seg.shape.shadowOpacity = hot && glow > 0 ? Float(min(0.95, 0.55 * glow / 0.6)) : 0
            seg.shape.fillColor = empty ? tokens.segEmpty : (hot ? (slot.map { look.hotFill(slot: $0, index: i) } ?? accent) : restFill(i))
            let outline = look.fillStyle == "outline" && !hot && slot != nil
            let bright = look.brightFills && hot
            let stroke: CGColor? = outline ? (slot.flatMap { look.tint(for: $0) } ?? accent).copy(alpha: 0.7)
                : bright ? .white(1) : (hot ? tokens.segHotStroke : tokens.segStroke)
            seg.shape.strokeColor = dwc ? .white(0.9) : stroke
            seg.shape.lineWidth = dwc ? 2.5 : (outline ? 2 : bright ? 3 : 1)
            seg.shape.lineDashPattern = dwc ? [5, 3] : nil
        }
        placeContent(i, hot: hot, animated: animated && changed)

        // Slight tilt of the hovered segment (outer edge lifts toward the viewer).
        let tilt: CATransform3D = {
            guard hot, allowsTilt, !Motion.reduceMotion, style == .ring else { return CATransform3DIdentity }
            let t = mid * .pi / 180
            return CATransform3DMakeRotation(4 * .pi / 180, -cos(t), -sin(t), 0)
        }()
        if !CATransform3DEqualToTransform(seg.group.transform, tilt) {
            transact(animated ? 0.18 : 0, animated: animated) { seg.group.transform = tilt }
        }
    }

    private func placeContent(_ i: Int, hot: Bool, animated: Bool) {
        let seg = segments[i], s = geometry.scale
        let mid = layerPoint(WheelGeometry.offset(radius: geometry.contentRadius(hovered: hot),
                                                  angle: WheelGeometry.midAngle(ofSlot: i)), center: center)
        let top: CALayer = style == .ring ? seg.icon : seg.label
        let bottom: CALayer = style == .ring ? seg.label : seg.caption
        // Captions or icons off: the label alone, centred.
        if top.isHidden || bottom.isHidden {
            move(top.isHidden ? bottom : top, to: mid, animated: animated)
            return
        }
        let gap = (style == .ring ? 6 : 2) * s
        let h = top.bounds.height + gap + bottom.bounds.height
        move(top, to: CGPoint(x: mid.x, y: mid.y + h / 2 - top.bounds.height / 2), animated: animated)
        move(bottom, to: CGPoint(x: mid.x, y: mid.y - h / 2 + bottom.bounds.height / 2), animated: animated)
    }

    // MARK: Motion

    func popIn() {
        guard !Motion.reduceMotion else { return }
        let now = CACurrentMediaTime()
        for (i, seg) in segments.enumerated() {
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = seg.group.opacity
            let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 0.9; grow.toValue = 1
            let g = CAAnimationGroup(); g.animations = [fade, grow]; g.duration = Motion.duration(0.18)
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            g.beginTime = now + Motion.duration(Double(i) * 0.025); g.fillMode = .backwards
            seg.group.add(g, forKey: "pop")
        }
    }

    func release(to target: WheelTarget, from offset: CGPoint?) {
        let s = geometry.scale
        let destination: CGPoint
        switch target {
        case let .segment(i):
            destination = layerPoint(WheelGeometry.offset(radius: geometry.contentRadius(hovered: true),
                                                          angle: WheelGeometry.midAngle(ofSlot: i)), center: center)
        case let .fanChip(k) where k < chips.count:
            destination = chips[k].group.position
        default:
            return
        }
        let flyer = CALayer()
        flyer.contentsScale = contentsScale
        flyer.bounds = CGRect(x: 0, y: 0, width: 40 * s, height: 40 * s)
        flyer.cornerRadius = 8 * s
        flyer.masksToBounds = true
        flyer.contentsGravity = .resizeAspectFill
        flyer.contents = thumbnail ?? samplePicture(size: 40 * s, scale: contentsScale)
        let start = offset.map { layerPoint($0, center: center) } ?? center
        flyer.position = destination
        flyer.opacity = 0
        layer.addSublayer(flyer)
        let path = CABasicAnimation(keyPath: "position")
        path.fromValue = NSValue(point: start); path.toValue = NSValue(point: destination)
        let shrink = CABasicAnimation(keyPath: "transform.scale"); shrink.fromValue = 1; shrink.toValue = 0.35
        let fade = CAKeyframeAnimation(keyPath: "opacity"); fade.values = [0.9, 0.9, 0]; fade.keyTimes = [0, 0.7, 1]
        let g = CAAnimationGroup(); g.animations = [path, shrink, fade]; g.duration = 0.22
        g.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setCompletionBlock { flyer.removeFromSuperlayer() }
        flyer.add(g, forKey: "release")
        CATransaction.commit()
    }
}
