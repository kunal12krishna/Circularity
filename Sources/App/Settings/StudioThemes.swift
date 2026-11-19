import Foundation

/// Themes from the website's Wheel Studio. "Copy for the app" puts the app's
/// own theme JSON on the clipboard; "Share" makes a link whose fragment
/// (`#w=`) holds the whole Studio wheel as base64url JSON. Paste theme
/// accepts both, and only the look settings the app has are taken.
enum StudioThemes {
    /// The theme JSON in `text`: the JSON itself, or a Studio share link turned into it.
    static func themeJSON(from text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return Data(trimmed.utf8) }
        guard let range = trimmed.range(of: "#w=") else { return nil }
        var b64 = String(trimmed[range.upperBound...]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if let end = b64.firstIndex(where: { $0.isWhitespace || $0 == "&" }) { b64 = String(b64[..<end]) }
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let wheel = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["app": AppIdentity.name, "schemaVersion": SettingsKeys.schemaVersion, "values": values(fromStudio: wheel)])
    }

    /// A Studio wheel's ◆ settings under the app's key names.
    static func values(fromStudio w: [String: Any]) -> [String: Any] {
        let names: [(String, String)] = [
            ("theme", SettingsKeys.theme.name), ("accent", SettingsKeys.accentHex.name), ("layout", SettingsKeys.wheelLayout.name),
            ("scheme", SettingsKeys.wheelScheme.name), ("panel", SettingsKeys.panelScheme.name), ("glass", SettingsKeys.glassStrength.name),
            ("scale", SettingsKeys.wheelScale.name), ("thick", SettingsKeys.ringThickness.name), ("gap", SettingsKeys.segmentGap.name),
            ("orb", SettingsKeys.orbScale.name), ("label", SettingsKeys.labelScale.name), ("font", SettingsKeys.fontStyle.name), ("case", SettingsKeys.labelCase.name),
            ("fill", SettingsKeys.fillStyle.name), ("accent2", SettingsKeys.accent2Hex.name), ("segAlpha", SettingsKeys.restOpacity.name),
            ("disc", SettingsKeys.discHex.name), ("ink", SettingsKeys.textHex.name), ("hotInk", SettingsKeys.hotTextHex.name),
            ("rimColor", SettingsKeys.rimHex.name), ("rimW", SettingsKeys.rimWidth.name), ("round", SettingsKeys.corners.name),
            ("bulge", SettingsKeys.hoverPop.name), ("captions", SettingsKeys.captions.name), ("dimOthers", SettingsKeys.dimOthers.name),
            ("labelWeight", SettingsKeys.labelWeight.name), ("track", SettingsKeys.tracking.name),
            ("fx.glow", SettingsKeys.glow.name), ("fx.glowColor", SettingsKeys.glowColor.name), ("fx.shadow", SettingsKeys.discShadow.name),
            ("fx.breathe", SettingsKeys.breathe.name), ("fx.dots", SettingsKeys.ringDots.name), ("fx.spin", SettingsKeys.ringSpin.name),
            ("fx.twirl", SettingsKeys.twirl.name), ("fx.sparks", SettingsKeys.sparks.name),
        ]
        var out: [String: Any] = [:]
        let fx = w["fx"] as? [String: Any] ?? [:]
        for (studio, app) in names {
            let found = studio.hasPrefix("fx.") ? fx[String(studio.dropFirst(3))] : w[studio]
            guard var v = found else { continue }
            // JSON true/false stay booleans; 0 and 1 are numbers (NSNumber bridges both ways).
            if CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() { out[app] = v as? Bool ?? false; continue }
            if let n = v as? Double { v = (n * 100).rounded() / 100 } // a slider may sit between steps
            if studio == "gap" || studio == "fx.dots", let n = v as? Double { v = Int(n.rounded()) }
            out[app] = v
        }
        if let tints = w["tints"] as? [String: Any] {
            out[SettingsKeys.tintImages.name] = tints["images"] as? String ?? ""
            out[SettingsKeys.tintDocuments.name] = tints["documents"] as? String ?? ""
            out[SettingsKeys.tintTools.name] = tints["tools"] as? String ?? ""
        }
        return out
    }

    /// What Paste theme says afterwards, in words: which theme, which layout, which accent.
    static func message(applied: Int, skipped: [String], store: SettingsStore) -> String {
        guard applied > 0 else { return "That theme had nothing this version of \(AppIdentity.name) understands." }
        let id = store.value(SettingsKeys.theme)
        let name = ThemeCatalog.theme(id: id)?.name ?? "Your"
        let layout = store.value(SettingsKeys.wheelLayout).capitalized
        var text = "\(name) theme applied: \(layout) wheel, accent \(store.value(SettingsKeys.accentHex))."
        if !skipped.isEmpty { text += " \(skipped.count) setting\(skipped.count == 1 ? "" : "s") this version doesn't know were left as they were." }
        return text
    }
}
