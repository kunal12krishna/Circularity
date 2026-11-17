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
        RGB(hexString: settings.value(SettingsKeys.accentHex)) ?? RGB(hex: 0xC6FF3D)
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
        return style
    }

    static func geometry(_ settings: SettingsStore, layout: WheelLayoutKind) -> WheelGeometry {
        WheelGeometry.make(layout, scale: CGFloat(min(1.4, max(0.7, settings.value(SettingsKeys.wheelScale)))),
                           tweaks: WheelTweaks(thickness: CGFloat(settings.value(SettingsKeys.ringThickness)),
                                               gap: CGFloat(settings.value(SettingsKeys.segmentGap)),
                                               orbScale: CGFloat(settings.value(SettingsKeys.orbScale))))
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
