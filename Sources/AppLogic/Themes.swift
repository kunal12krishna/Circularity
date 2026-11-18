import Foundation

/// An sRGB colour with WCAG arithmetic (pure, unit-tested).
nonisolated struct RGB: Equatable, Sendable {
    var r: Double, g: Double, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }

    var hexString: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio (1 … 21).
    func contrast(with other: RGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This colour at `alpha` composited over `background`.
    func over(_ background: RGB, alpha: Double) -> RGB {
        RGB(r * alpha + background.r * (1 - alpha), g * alpha + background.g * (1 - alpha), b * alpha + background.b * (1 - alpha))
    }

    func mixed(with other: RGB, _ amount: Double) -> RGB { other.over(self, alpha: amount) }

    static let white = RGB(1, 1, 1)
    static let black = RGB(0, 0, 0)
}

nonisolated struct Theme: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let accent: RGB
    /// How dark the Ring's glass tint is (0 … 1).
    let glassStrength: Double
    let font: String
}

/// The built-in themes (Riso, the default since 0.3; BRIEF.md's Tangerine,
/// Glass, Graphite, Midnight, Mono and Neon; plus Custom) and the accent swatches.
nonisolated enum ThemeCatalog {
    static let all: [Theme] = [
        // Riso: fluorescent pink, as in risograph ink (the website's colours).
        Theme(id: "riso", name: "Riso", accent: RGB(hex: 0xFF4FA0), glassStrength: 0.55, font: "rounded"),
        Theme(id: "neon", name: "Neon", accent: RGB(hex: 0xC6FF3D), glassStrength: 0.55, font: "rounded"),
        Theme(id: "tangerine", name: "Tangerine", accent: RGB(hex: 0xFF8A00), glassStrength: 0.55, font: "rounded"),
        Theme(id: "glass", name: "Glass", accent: RGB(hex: 0x7C8CFF), glassStrength: 0.3, font: "rounded"),
        Theme(id: "graphite", name: "Graphite", accent: RGB(hex: 0x9BA3AF), glassStrength: 0.75, font: "default"),
        Theme(id: "midnight", name: "Midnight", accent: RGB(hex: 0x5C7CFA), glassStrength: 0.8, font: "rounded"),
        Theme(id: "mono", name: "Mono", accent: RGB(hex: 0xF2F2F2), glassStrength: 0.6, font: "default"),
    ]

    /// Eight swatches for Custom (the riso inks, board accents, Halo accents).
    static let swatches: [String] = ["#FF4FA0", "#2F5BFF", "#FF8A00", "#FFB020", "#7C8CFF", "#C6FF3D", "#5CE1FF", "#9BA3AF"]
    /// What a fresh install looks like.
    static let defaultAccentHex = "#FF4FA0"

    static func theme(id: String) -> Theme? { all.first { $0.id == id } }
    static func theme(forAccent hex: String) -> Theme? {
        guard let rgb = RGB(hexString: hex) else { return nil }
        return all.first { $0.accent.hexString == rgb.hexString }
    }

    static let darkText = RGB(hex: 0x1A1206)

    /// Text on an accent fill: the board's near-black where it reads, else white.
    static func onAccent(_ accent: RGB) -> RGB {
        accent.contrast(with: darkText) >= accent.contrast(with: .white) ? darkText : .white
    }

    // Surfaces used by the contrast test. The HUD glass is modelled as
    // rgba(30,30,30,0.7) — what NSVisualEffectView's .hudWindow does to a backdrop.
    static let hudGlass = RGB(hex: 0x1E1E1E)
    static let lightGlass = RGB(hex: 0xF0F0F0)

    /// The Ring's disc over a backdrop, at a glass strength.
    static func ringDisc(over backdrop: RGB, strength: Double, light: Bool) -> RGB {
        if light {
            let glass = lightGlass.over(backdrop, alpha: 0.7)
            return RGB.white.over(glass, alpha: strength)
        }
        let glass = hudGlass.over(backdrop, alpha: 0.7)
        return RGB(hex: 0x18181C).over(glass, alpha: strength)
    }

    /// The panel's background over a backdrop (board I: rgba(30,30,34,0.74) on HUD glass).
    static func panelBackground(over backdrop: RGB) -> RGB {
        RGB(hex: 0x1E1E22).over(hudGlass.over(backdrop, alpha: 0.7), alpha: 0.74)
    }
}
