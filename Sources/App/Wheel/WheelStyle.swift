import AppKit
import CircularityEngine

/// The look of one wheel, resolved from settings (PLAN.md §3.7): accent, text
/// on the accent, light or dark, glass strength, category tints, typography.
struct WheelStyle {
    var accent: CGColor
    var onAccent: CGColor
    var light = false
    var glassStrength: CGFloat = 0.55
    var tintImages: CGColor?
    var tintDocuments: CGColor?
    var tintTools: CGColor?
    var font = "rounded"         // rounded | default | mono
    var upperCase = false
    var labelScale: CGFloat = 1
    // Wheel Studio looks (0.3). The defaults draw the boards exactly.
    var fillStyle = "flat"       // flat | duo | shades | stickers | rainbow | outline
    var accent2: CGColor = .hex(0x2F5BFF)
    var restOpacity: CGFloat = 1
    var discColor: CGColor?
    var textColor: CGColor?
    var hotTextColor: CGColor?
    var rimColor: CGColor?
    var rimWidth: CGFloat = 1
    /// nil = the layout's own (Halo glows, Ring and Orbit don't).
    var glow: CGFloat?
    var glowColorName = "accent"
    var corners: CGFloat = 0
    var discShadow: CGFloat = 1
    var captions = true
    var dimOthers = true
    var weight: NSFont.Weight = .bold
    var tracking: CGFloat = 0
    var breathe: CGFloat = 0
    var ringDots = 0
    var ringSpin: CGFloat = 0
    var twirl = false
    var sparks = false

    /// The boards' own look for an accent (used by previews and tests).
    static func board(accent hex: UInt32, light: Bool = false) -> WheelStyle {
        let rgb = RGB(hex: hex)
        let on = ThemeCatalog.onAccent(rgb)
        return WheelStyle(accent: .hex(hex), onAccent: CGColor(srgbRed: on.r, green: on.g, blue: on.b, alpha: 1), light: light)
    }

    func labelFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        switch font {
        case "mono": WheelFont.mono(size, weight)
        case "default": NSFont.systemFont(ofSize: size, weight: weight)
        default: WheelFont.rounded(size, weight)
        }
    }

    func label(_ text: String) -> String { upperCase ? text.uppercased() : text }

    /// Glow strength under the lit button (0 = none) for a layout.
    func glowAmount(halo: Bool) -> CGFloat { glow ?? (halo ? 0.6 : 0) }

    /// The glow's colour; Stickers glow in the button's own colour.
    func glowColor(sticker: CGColor? = nil) -> CGColor {
        switch glowColorName {
        case "second": accent2
        case "white": .white(1)
        default: fillStyle == "stickers" ? (sticker ?? accent) : accent
        }
    }

    /// Fill styles whose buttons are bright, so their text is near-black.
    var brightFills: Bool { fillStyle == "stickers" || fillStyle == "rainbow" }

    /// A resting button's fill for a fill style (nil = the layout's own), before `restOpacity`.
    func restFill(slot: WheelSlot, index i: Int) -> CGColor? {
        let tint = tint(for: slot)
        switch fillStyle {
        case "duo": return (tint ?? (i % 2 == 1 ? accent2 : accent)).copy(alpha: 0.24)
        case "shades": return (tint ?? accent).copy(alpha: 0.08 + 0.34 * CGFloat(i) / 5)
        case "stickers": return Self.stickerColor(slot, index: i)
        case "rainbow": return Self.rainbow(i, lit: false)
        case "outline": return .clear
        default: return nil
        }
    }

    /// The lit button's fill: the accent, except Stickers and Rainbow keep their colour.
    func hotFill(slot: WheelSlot, index i: Int) -> CGColor {
        switch fillStyle {
        case "stickers": Self.stickerColor(slot, index: i)
        case "rainbow": Self.rainbow(i, lit: true)
        default: accent
        }
    }

    /// One sticker colour per format and tool (the website's sticker set).
    static func stickerColor(_ slot: WheelSlot, index i: Int) -> CGColor {
        let table: [String: UInt32] = ["PNG": 0x35D0E6, "JPG": 0xFF6FB5, "JPEG": 0xFF6FB5, "HEIC": 0xFF9A3D, "WEBP": 0x9B6BFF,
                                       "AVIF": 0xFFD23F, "TIFF": 0x3ECF8E, "PDF": 0xFF5E5B, "GIF": 0x5CE1FF, "BMP": 0xC9BFAE,
                                       "CUT": 0x3ECF8E, "CROP": 0xFF8AD8, "•••": 0xE8E8EE, "SQZ": 0xFFD23F, "SIZE": 0x9B6BFF]
        if let v = table[slot.monoLabel.uppercased()] { return .hex(v) }
        let fallback: [UInt32] = [0x35D0E6, 0xFF6FB5, 0x3ECF8E, 0xE8E8EE, 0xFFD23F, 0x9B6BFF]
        return .hex(fallback[i % fallback.count])
    }

    /// Rainbow: hue by position, the same HSL as the Studio.
    static func rainbow(_ i: Int, lit: Bool) -> CGColor {
        let rgb = hsl(CGFloat(i) / 6 * 360, lit ? 0.95 : 0.85, lit ? 0.66 : 0.60)
        return CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }

    static func hsl(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let a = s * min(l, 1 - l)
        func f(_ n: CGFloat) -> CGFloat {
            let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
            return l - a * max(-1, min(k - 3, min(9 - k, 1)))
        }
        return (f(0), f(8), f(4))
    }

    /// `color` at `restOpacity` (the resting buttons only).
    func resting(_ color: CGColor) -> CGColor { color.copy(alpha: color.alpha * restOpacity) ?? color }

    /// A More-fan chip's fill, in the same fill style as the ring's buttons.
    /// Ring buttons sit on the disc, but chips float over the desktop, so the
    /// style is laid over the chip's own `base` (the disc colour when one is
    /// set): Outline, Duo and a low resting opacity still give a solid chip
    /// that the theme's text colours read on.
    func fanFill(slot: WheelSlot, index k: Int, base: CGColor, hot: Bool, categoryTint: Bool) -> CGColor {
        let i = k % WheelGeometry.segmentCount
        if hot { return hotFill(slot: slot, index: i) }
        let base = discColor?.copy(alpha: max(base.alpha, 0.88)) ?? base
        guard let fill = restFill(slot: slot, index: i) ?? (categoryTint ? tint(for: slot)?.copy(alpha: 0.22) : nil) else { return base }
        return Self.over(resting(fill), base)
    }

    /// `top` composited over `base` (source-over, sRGB).
    static func over(_ top: CGColor, _ base: CGColor) -> CGColor {
        let t = RGB(cg: top), b = RGB(cg: base), ta = top.alpha, ba = base.alpha
        let a = ta + ba * (1 - ta)
        guard a > 0 else { return .clear }
        func mix(_ x: Double, _ y: Double) -> CGFloat { (CGFloat(x) * ta + CGFloat(y) * ba * (1 - ta)) / a }
        return CGColor(srgbRed: mix(t.r, b.r), green: mix(t.g, b.g), blue: mix(t.b, b.b), alpha: a)
    }

    /// The resting tint for a slot's category, if one is set.
    func tint(for slot: WheelSlot) -> CGColor? {
        switch slot.category {
        case .tool: return tintTools
        case .more: return nil
        case .format:
            if case let .convert(f) = slot.action, f.imageTypeIdentifier != nil { return tintImages }
            return tintDocuments
        }
    }

    /// Text on the accent, matched to the boards' near-black where it reads.
    var onAccentIsDark: Bool { RGB(cg: onAccent).luminance < 0.5 }

    /// The accent as text on a surface: the accent itself where it reads
    /// (≥ 3:1, large text), else the surface's ink.
    func accentText(on surface: RGB, ink: CGColor) -> CGColor {
        RGB(cg: accent).contrast(with: surface) >= 3 ? accent : ink
    }
}

extension RGB {
    init(cg: CGColor) {
        let c = cg.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        if c.count >= 3 { self.init(Double(c[0]), Double(c[1]), Double(c[2])) } else { self.init(Double(c[0]), Double(c[0]), Double(c[0])) }
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

/// Settings → resolved colours and styles, in one place (wheel, panel, dialogs).
enum Appearance {
    static func accentRGB(_ settings: SettingsStore) -> RGB {
        RGB(hexString: settings.value(SettingsKeys.accentHex)) ?? RGB(hex: 0xFF4FA0)
    }

    static func accent(_ settings: SettingsStore) -> CGColor {
        let c = accentRGB(settings)
        return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    static func accentNS(_ settings: SettingsStore) -> NSColor { NSColor(cgColor: accent(settings)) ?? .orange }

    static func onAccent(_ settings: SettingsStore) -> CGColor {
        let c = ThemeCatalog.onAccent(accentRGB(settings))
        return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Whether a scheme setting means light. `auto` = the layout's board look.
    static func isLight(_ scheme: String, auto: Bool) -> Bool {
        switch scheme {
        case "light": true
        case "dark": false
        case "system": !systemIsDark
        default: auto
        }
    }

    static func wheelStyle(_ settings: SettingsStore, layout: WheelLayoutKind) -> WheelStyle {
        var style = WheelStyle(accent: accent(settings), onAccent: onAccent(settings))
        let scheme = settings.value(SettingsKeys.wheelScheme)
        style.light = layout == .halo ? false : isLight(scheme, auto: layout == .orbit)
        style.glassStrength = CGFloat(settings.value(SettingsKeys.glassStrength))
        style.tintImages = CGColor.hexString(settings.value(SettingsKeys.tintImages))
        style.tintDocuments = CGColor.hexString(settings.value(SettingsKeys.tintDocuments))
        style.tintTools = CGColor.hexString(settings.value(SettingsKeys.tintTools))
        style.font = settings.value(SettingsKeys.fontStyle)
        style.upperCase = settings.value(SettingsKeys.labelCase) == "upper"
        style.labelScale = CGFloat(min(1.3, max(0.85, settings.value(SettingsKeys.labelScale))))
        let clamp = { (v: Double, lo: Double, hi: Double) in CGFloat(min(hi, max(lo, v))) }
        style.fillStyle = settings.value(SettingsKeys.fillStyle)
        style.accent2 = CGColor.hexString(settings.value(SettingsKeys.accent2Hex)) ?? .hex(0x2F5BFF)
        style.restOpacity = clamp(settings.value(SettingsKeys.restOpacity), 0.15, 1)
        style.discColor = CGColor.hexString(settings.value(SettingsKeys.discHex))
        style.textColor = CGColor.hexString(settings.value(SettingsKeys.textHex))
        style.hotTextColor = CGColor.hexString(settings.value(SettingsKeys.hotTextHex))
        style.rimColor = CGColor.hexString(settings.value(SettingsKeys.rimHex))
        style.rimWidth = clamp(settings.value(SettingsKeys.rimWidth), 0, 6)
        let glow = settings.value(SettingsKeys.glow)
        style.glow = glow < 0 ? nil : clamp(glow, 0, 1.5)
        style.glowColorName = settings.value(SettingsKeys.glowColor)
        style.corners = clamp(settings.value(SettingsKeys.corners), 0, 1)
        style.discShadow = clamp(settings.value(SettingsKeys.discShadow), 0, 1)
        style.captions = settings.value(SettingsKeys.captions)
        style.dimOthers = settings.value(SettingsKeys.dimOthers)
        style.weight = switch settings.value(SettingsKeys.labelWeight) {
        case "regular": .regular
        case "semibold": .semibold
        case "heavy": .heavy
        default: .bold
        }
        style.tracking = clamp(settings.value(SettingsKeys.tracking), -0.05, 0.3)
        style.breathe = clamp(settings.value(SettingsKeys.breathe), 0, 1)
        style.ringDots = min(36, max(0, settings.value(SettingsKeys.ringDots)))
        style.ringSpin = clamp(settings.value(SettingsKeys.ringSpin), 0, 20)
        style.twirl = settings.value(SettingsKeys.twirl)
        style.sparks = settings.value(SettingsKeys.sparks)
        return style
    }

    static func geometry(_ settings: SettingsStore, layout: WheelLayoutKind) -> WheelGeometry {
        WheelGeometry.make(layout, scale: CGFloat(min(1.4, max(0.7, settings.value(SettingsKeys.wheelScale)))),
                           tweaks: WheelTweaks(thickness: CGFloat(settings.value(SettingsKeys.ringThickness)),
                                               gap: CGFloat(settings.value(SettingsKeys.segmentGap)),
                                               orbScale: CGFloat(settings.value(SettingsKeys.orbScale)),
                                               pop: CGFloat(settings.value(SettingsKeys.hoverPop))))
    }

    /// Applies a theme's accent, glass and font (Settings → Appearance).
    static func apply(theme id: String, to settings: SettingsStore) {
        settings.set(id, for: SettingsKeys.theme)
        guard let theme = ThemeCatalog.theme(id: id) else { return }
        settings.set(theme.accent.hexString, for: SettingsKeys.accentHex)
        settings.set(Double(theme.glassStrength), for: SettingsKeys.glassStrength)
        settings.set(theme.font, for: SettingsKeys.fontStyle)
    }
}
