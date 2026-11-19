import AppKit
import QuartzCore

/// Motion around any wheel, designed in the website's Wheel Studio (0.3):
/// the wheel breathes, a ring of dots orbits it, it twirls into place as it
/// opens, and sparks fly when a button lights up. It sits between the panel's
/// layer view and the renderer's layer, so every layout gets it for free.
///
/// The six buttons themselves never move: you aim at them, so they stay
/// where your hand expects them. Everything is off by default, stops when the
/// wheel hides, and stays off with Reduce Motion.
final class WheelEffects {
    /// Holds the renderer's layer; breathing and the twirl move this.
    let root = CALayer()
    private let dots = CAReplicatorLayer()
    private let dot = CALayer()
    private let sparks = CAEmitterLayer()
    private var style = WheelStyle.board(accent: 0xFF4FA0)
    private var geometry = WheelGeometry.halo()
    private var sparkGeneration = 0

    /// One breath, in seconds (the Studio's sin(t · 2.2)).
    static let breathPeriod: CFTimeInterval = 2 * .pi / 2.2
    /// How much a full breath swells the wheel.
    static let breathDepth: CGFloat = 0.035
    /// The twirl starts this far round and springs to rest.
    static let twirlDegrees: CGFloat = 60

    init() {
        root.addSublayer(dots)
        dots.addSublayer(dot)
        root.addSublayer(sparks)
        sparks.emitterShape = .point
        sparks.birthRate = 0
        for l in [root, dots, dot, sparks] as [CALayer] { l.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull()] }
    }

    /// Puts the renderer's layer above the dots and below the sparks.
    func attach(_ rendererLayer: CALayer) {
        rendererLayer.removeFromSuperlayer()
        root.insertSublayer(rendererLayer, above: dots)
    }

    func configure(style: WheelStyle, geometry g: WheelGeometry, bounds: CGRect, contentsScale: CGFloat) {
        self.style = style
        geometry = g
        transact(0, animated: false) {
            stop()
            root.frame = bounds
            for l in [root, dots, dot, sparks] as [CALayer] { l.contentsScale = contentsScale }
            dots.frame = root.bounds
            sparks.frame = root.bounds
            configureDots()
            configureSparks(contentsScale: contentsScale)
        }
    }

    /// The ring of dots: radius just outside the wheel, glowing like the lit button.
    private func configureDots() {
        let n = style.ringDots, s = geometry.scale
        dots.isHidden = n == 0
        guard n > 0 else { return }
        let reach = geometry.kind == .orbit
            ? geometry.buttonRadius + geometry.buttonDiameter / 2 * geometry.buttonHoverScale
            : geometry.discDiameter / 2
        let radius = (reach + 18) * s, d = 7 * s
        dot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        dot.cornerRadius = d / 2
        dot.backgroundColor = style.accent
        dot.position = CGPoint(x: dots.bounds.midX, y: dots.bounds.midY + radius)
        let glow = style.glowAmount(halo: geometry.kind == .halo)
        dot.shadowColor = style.glowColor()
        dot.shadowOffset = .zero
        dot.shadowRadius = 6 * s
        dot.shadowOpacity = glow > 0 ? 0.9 : 0
        dots.instanceCount = n
        dots.instanceTransform = CATransform3DMakeRotation(2 * .pi / CGFloat(n), 0, 0, 1)
    }

    private func configureSparks(contentsScale: CGFloat) {
        let s = geometry.scale
        let image = Self.dotImage(scale: contentsScale)
        let colours: [CGColor] = style.brightFills ? [.white(1), style.accent] : [style.accent, style.accent2, .white(1)]
        sparks.emitterCells = colours.map { colour in
            let c = CAEmitterCell()
            c.contents = image
            c.color = colour
            c.birthRate = 160 / Float(colours.count)
            c.lifetime = 0.95
            c.lifetimeRange = 0.3
            c.velocity = 130 * s
            c.velocityRange = 60 * s
            c.emissionRange = 2 * .pi
            c.yAcceleration = -260 * s // gravity (layers are y-up)
            c.scale = 0.45 * s / contentsScale * 2
            c.scaleRange = 0.15 * s / contentsScale * 2
            c.scaleSpeed = -0.35 * s / contentsScale * 2
            c.alphaSpeed = -1.0
            return c
        }
    }

    /// The wheel is on screen: start breathing and orbiting, and twirl in.
    /// `glass` is Ring's frosted disc, which breathes along with it.
    func opened(glass: CALayer?) {
        guard !Motion.reduceMotion else { return }
        let now = CACurrentMediaTime()
        if style.breathe > 0 {
            let k = 1 + Self.breathDepth * style.breathe
            for layer in [root, glass].compactMap({ $0 }) {
                let breath = CAKeyframeAnimation(keyPath: "transform")
                breath.values = [1, k, 1].map { NSValue(caTransform3D: Self.centred(layer, scale: $0)) }
                breath.keyTimes = [0, 0.5, 1]
                breath.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
                breath.duration = Self.breathPeriod
                breath.repeatCount = .infinity
                breath.beginTime = now
                layer.add(breath, forKey: "breathe")
            }
        }
        if style.ringDots > 0, style.ringSpin > 0 {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * CGFloat.pi // clockwise on screen (layers are y-up)
            spin.duration = 60 / Double(style.ringSpin)
            spin.repeatCount = .infinity
            dots.add(spin, forKey: "spin")
        }
        if style.twirl {
            // Starts a sixth of a turn back and springs clockwise into place.
            let twirl = CASpringAnimation(keyPath: "transform.rotation.z")
            twirl.fromValue = Self.twirlDegrees * .pi / 180
            twirl.toValue = 0
            twirl.stiffness = 170 * Motion.speed * Motion.speed
            twirl.damping = 15 * Motion.speed
            twirl.duration = twirl.settlingDuration
            twirl.isAdditive = true
            root.add(twirl, forKey: "twirl")
        }
    }

    /// A button lit up: a short burst of sparks from `point` (layer space).
    func spark(at point: CGPoint) {
        guard style.sparks, !Motion.reduceMotion else { return }
        sparkGeneration += 1
        let generation = sparkGeneration
        transact(0, animated: false) {
            sparks.emitterPosition = point
            sparks.beginTime = CACurrentMediaTime()
            sparks.birthRate = 1
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard let self, self.sparkGeneration == generation else { return }
            self.sparks.birthRate = 0
        }
    }

    /// The wheel hid: nothing keeps animating off screen.
    func stop(glass: CALayer? = nil) {
        root.removeAnimation(forKey: "breathe")
        root.removeAnimation(forKey: "twirl")
        glass?.removeAnimation(forKey: "breathe")
        dots.removeAnimation(forKey: "spin")
        sparks.birthRate = 0
    }

    /// A scale about the layer's centre, whatever its anchor point (AppKit
    /// views' layers anchor at the corner).
    static func centred(_ layer: CALayer, scale k: CGFloat) -> CATransform3D {
        let b = layer.bounds
        let anchor = CGPoint(x: layer.anchorPoint.x * b.width, y: layer.anchorPoint.y * b.height)
        let c = CGPoint(x: b.midX, y: b.midY)
        var t = CATransform3DMakeTranslation(c.x - anchor.x, c.y - anchor.y, 0)
        t = CATransform3DScale(t, k, k, 1)
        return CATransform3DTranslate(t, anchor.x - c.x, anchor.y - c.y, 0)
    }

    private static func dotImage(scale: CGFloat) -> CGImage? {
        renderImage(size: CGSize(width: 12, height: 12), scale: scale) { ctx in
            ctx.setFillColor(.white(1))
            ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: 12, height: 12))
        }
    }
}
