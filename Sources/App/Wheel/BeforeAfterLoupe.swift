import AppKit
import CircularityEngine
import QuartzCore

/// The before/after close-up shown beside the hovered segment for lossy
/// formats and Compress (Settings → Wheel). Built once, re-used.
final class BeforeAfterLoupe {
    let layer = CALayer()
    private let image = CALayer()
    private let before = makeLabel()
    private let after = makeLabel()
    private var cache: [String: CGImage] = [:]
    private var wanted = ""

    init() {
        layer.opacity = 0
        layer.shadowColor = .black(1)
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: -8)
        image.masksToBounds = true
        image.contentsGravity = .resizeAspectFill
        image.magnificationFilter = .nearest // show the real pixels, artefacts and all
        layer.addSublayer(image)
        layer.addSublayer(before)
        layer.addSublayer(after)
    }

    /// What a hovered action would look like, or nil for no loupe.
    static func spec(for action: WheelAction?, url: URL, settings: SettingsStore) -> (format: OutputFormat, quality: Double, label: String)? {
        switch action {
        case .convert(.jpg)?: let q = settings.value(SettingsKeys.qualityJPG); return (.jpg, q, "JPG \(Int(q * 100))")
        case .convert(.heic)?: let q = settings.value(SettingsKeys.qualityHEIC); return (.heic, q, "HEIC \(Int(q * 100))")
        case .compress?:
            let format = ConversionEngine.compressedFormat(for: url)
            guard format == .jpg || format == .heic else { return nil }
            return (format, 0.6, "\(format.displayName) 60")
        default: return nil
        }
    }

    func reset() {
        cache.removeAll()
        wanted = ""
        hide()
    }

    func hide() {
        wanted = ""
        transact(0.1, animated: true) { layer.opacity = 0 }
    }

    /// Shows the loupe centred at `center` (host coordinates), drawing the
    /// image in the background the first time.
    func show(url: URL, spec: (format: OutputFormat, quality: Double, label: String), at center: CGPoint, scale s: CGFloat,
              accent: CGColor, contentsScale: CGFloat) {
        let key = "\(url.path)|\(spec.format.rawValue)|\(spec.quality)"
        wanted = key
        let side = 136 * s
        transact(0, animated: false) {
            layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            layer.position = center
            layer.shadowPath = CGPath(roundedRect: layer.bounds, cornerWidth: 16 * s, cornerHeight: 16 * s, transform: nil)
            image.frame = layer.bounds
            image.cornerRadius = 16 * s
            image.borderWidth = 1.5
            image.borderColor = accent.copy(alpha: 0.8)
            for l in [layer, image, before, after] as [CALayer] { l.contentsScale = contentsScale }
            before.set("BEFORE", font: WheelFont.mono(9 * s, .bold), color: .white(1), kern: 0.6 * s)
            after.set("AFTER · \(spec.label)", font: WheelFont.mono(9 * s, .bold), color: .white(1), kern: 0.6 * s,
                      maxWidth: side / 2 - 8 * s, minScale: 0.7)
            for (label, x) in [(before, side / 4), (after, side * 3 / 4)] {
                label.backgroundColor = .black(0.6)
                label.cornerRadius = 4 * s
                label.bounds.size.width += 8 * s
                label.bounds.size.height += 3 * s
                label.position = CGPoint(x: x, y: 12 * s)
            }
        }
        if let cached = cache[key] {
            present(cached)
            return
        }
        Task.detached(priority: .userInitiated) {
            let made = BeforeAfter.image(url, format: spec.format, quality: spec.quality)
            await MainActor.run { [weak self] in
                guard let self, let made else { return }
                self.cache[key] = made
                if self.wanted == key { self.present(made) }
            }
        }
    }

    private func present(_ cg: CGImage) {
        transact(0, animated: false) { image.contents = cg }
        transact(0.14, animated: !Motion.reduceMotion) { layer.opacity = 1 }
    }
}
