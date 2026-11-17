import AppKit
import QuartzCore

/// The centre orb used by Ring (board D) and Halo (board C): thumbnail,
/// kicker, morphing big label, detail line, file line and batch badge.
final class OrbLayer {
    enum Style { case ring, halo }

    let layer = CALayer()

    private struct Tokens {
        var diameter: CGFloat, fill: CGColor, border: CGColor, borderWidth: CGFloat
        var thumbOpacity: Float, gap: CGFloat
        var kickerFont: NSFont, kickerKern: CGFloat, kickerColor: CGColor
        var bigFont: NSFont, bigKern: CGFloat, bigMaxWidth: CGFloat
        var detailColor: CGColor, fileColor: CGColor
        var dropShadow: Bool
    }

    private var style: Style = .ring
    private var tokens: Tokens!
    private var accent: CGColor = .hex(0xFF8A00)
    private var scaleFactor: CGFloat = 1

    private let disc = CAShapeLayer()
    private let thumb = CALayer()
    private let highlight = CALayer()
    private let kicker = makeLabel()
    private let big = makeLabel()
    private let detail = makeLabel()
    private let file = makeLabel()
    private let badge = CALayer()
    private let badgeLabel = makeLabel()
    private var current = OrbText(kicker: "", big: "", detail: "", cancelHot: false)

    init() {
        for l in [disc, thumb, highlight, kicker, big, detail, file, badge] as [CALayer] { layer.addSublayer(l) }
        badge.addSublayer(badgeLabel)
        thumb.masksToBounds = true
        thumb.contentsGravity = .resizeAspectFill
        badge.isHidden = true
    }

    func configure(style: Style, scale s: CGFloat, accent: CGColor, contentsScale: CGFloat,
                   fileLine: String, count: Int, thumbnail: CGImage?) {
        self.style = style
        self.accent = accent
        scaleFactor = s
        tokens = style == .ring
            ? Tokens(diameter: 180 * s, fill: .hex(0x0E0E10, 0.78), border: .white(0.18), borderWidth: 1.5 * s,
                     thumbOpacity: 0.22, gap: 3 * s,
                     kickerFont: WheelFont.rounded(10 * s, .bold), kickerKern: 0.8 * s, kickerColor: .hex(0xC9C3B9),
                     bigFont: WheelFont.rounded(32 * s, .heavy), bigKern: 0.64 * s, bigMaxWidth: 160 * s,
                     detailColor: .hex(0xE6E1D8), fileColor: .hex(0xC9C3B9), dropShadow: true)
            : Tokens(diameter: 230 * s, fill: .hex(0x1A1D24), border: .white(0.08), borderWidth: 1 * s,
                     thumbOpacity: 0.35, gap: 4 * s,
                     kickerFont: WheelFont.rounded(11 * s, .semibold), kickerKern: 0.66 * s, kickerColor: .hex(0xA9AFBC),
                     bigFont: WheelFont.mono(38 * s, .heavy), bigKern: 1.52 * s, bigMaxWidth: 200 * s,
                     detailColor: .hex(0xD5D9E1), fileColor: .hex(0xA9AFBC), dropShadow: false)
        let d = tokens.diameter
        let bounds = CGRect(x: 0, y: 0, width: d, height: d)
        layer.bounds = bounds
        for l in [layer, disc, thumb, highlight, kicker, big, detail, file, badge, badgeLabel] as [CALayer] {
            l.contentsScale = contentsScale
        }

        disc.frame = bounds
        disc.path = CGPath(ellipseIn: bounds.insetBy(dx: tokens.borderWidth / 2, dy: tokens.borderWidth / 2), transform: nil)
        disc.fillColor = tokens.fill
        disc.strokeColor = tokens.border
        disc.lineWidth = tokens.borderWidth
        if tokens.dropShadow {
            disc.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
            disc.shadowColor = .black(1)
            disc.shadowOpacity = 0.35
            disc.shadowRadius = 15 * s
            disc.shadowOffset = CGSize(width: 0, height: -10 * s)
        } else {
            disc.shadowOpacity = 0
        }

        thumb.frame = bounds.insetBy(dx: tokens.borderWidth, dy: tokens.borderWidth)
        thumb.cornerRadius = thumb.bounds.width / 2
        thumb.opacity = tokens.thumbOpacity
        setThumbnail(thumbnail)

        highlight.frame = bounds
        highlight.contents = style == .ring
            ? DiscImages.innerGlow(diameter: d, offsetY: 1 * s, blur: 1 * s, color: .white(0.12), scale: contentsScale)
            : nil

        file.set(fileLine, font: WheelFont.rounded(11 * s, .regular), color: tokens.fileColor, maxWidth: d * 0.78, minScale: 0.7)

        badge.isHidden = count < 2
        if count > 1 {
            badgeLabel.set("\(count)", font: WheelFont.rounded(12 * s, .heavy), color: .hex(0x1A1206))
            let w = max(24 * s, badgeLabel.bounds.width + 10 * s), h = 24 * s
            badge.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            badge.cornerRadius = h / 2
            badge.backgroundColor = accent
            let corner = WheelGeometry.offset(radius: d / 2 - 6 * s, angle: 45)
            badge.position = layerPoint(corner, center: CGPoint(x: d / 2, y: d / 2))
            badgeLabel.position = CGPoint(x: w / 2, y: h / 2)
        }
        current = OrbText(kicker: "", big: "", detail: "", cancelHot: false)
    }

    func setThumbnail(_ image: CGImage?) {
        transact(0.15, animated: true) { thumb.contents = image }
    }

    func show(_ text: OrbText, animated: Bool) {
        guard text != current else { return }
        let previous = current
        current = text
        let s = scaleFactor
        kicker.set(text.kicker, font: tokens.kickerFont, color: tokens.kickerColor, kern: tokens.kickerKern)
        big.set(text.big, font: tokens.bigFont, color: text.cancelHot ? .hex(0xFF8A80) : accent,
                kern: tokens.bigKern, maxWidth: tokens.bigMaxWidth)
        detail.set(text.detail, font: WheelFont.rounded(12 * s, .semibold), color: tokens.detailColor,
                   maxWidth: tokens.diameter * 0.74, minScale: 0.9, wraps: true)
        let cancelBorder: CGColor = style == .ring ? .hex(0xFF7A6E) : tokens.border
        transact(0.12, animated: animated) { disc.strokeColor = text.cancelHot ? cancelBorder : tokens.border }
        layoutText()
        if animated, previous.big != text.big, !previous.big.isEmpty, !Motion.reduceMotion {
            morphBigLabel(from: previous)
        }
    }

    /// Stack: kicker, big, detail, (6 pt) file line — vertically centred.
    private func layoutText() {
        let gap = tokens.gap, extra = 6 * scaleFactor
        let items: [CALayer] = [kicker, big, detail, file]
        let total = items.reduce(0) { $0 + $1.bounds.height } + gap * 3 + extra
        var top = tokens.diameter / 2 + total / 2
        for (i, item) in items.enumerated() {
            if i == 3 { top -= extra }
            let h = item.bounds.height
            transact(0, animated: false) { item.position = CGPoint(x: tokens.diameter / 2, y: top - h / 2) }
            top -= h + gap
        }
    }

    /// Crossfade plus a slight vertical slide (PLAN.md §9.4).
    private func morphBigLabel(from previous: OrbText) {
        let ghost = makeLabel()
        ghost.contentsScale = big.contentsScale
        ghost.set(previous.big, font: tokens.bigFont, color: previous.cancelHot ? .hex(0xFF8A80) : accent,
                  kern: tokens.bigKern, maxWidth: tokens.bigMaxWidth)
        ghost.position = big.position
        layer.addSublayer(ghost)
        let slide = 6 * scaleFactor, duration = 0.16
        CATransaction.begin()
        CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
        let out = CABasicAnimation(keyPath: "opacity"); out.fromValue = 1; out.toValue = 0
        let up = CABasicAnimation(keyPath: "position.y"); up.byValue = slide
        let group = CAAnimationGroup(); group.animations = [out, up]; group.duration = duration
        group.fillMode = .forwards; group.isRemovedOnCompletion = false
        ghost.add(group, forKey: "out")
        let fadeIn = CABasicAnimation(keyPath: "opacity"); fadeIn.fromValue = 0; fadeIn.toValue = 1
        let rise = CABasicAnimation(keyPath: "position.y"); rise.fromValue = big.position.y - slide; rise.toValue = big.position.y
        let enter = CAAnimationGroup(); enter.animations = [fadeIn, rise]; enter.duration = duration
        enter.timingFunction = CAMediaTimingFunction(name: .easeOut)
        big.add(enter, forKey: "in")
        CATransaction.commit()
    }
}
