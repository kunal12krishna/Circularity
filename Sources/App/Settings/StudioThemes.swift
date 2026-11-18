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
        ]
        var out: [String: Any] = [:]
        for (studio, app) in names {
            guard var v = w[studio] else { continue }
            if let n = v as? Double { v = (n * 100).rounded() / 100 } // a slider may sit between steps
            if studio == "gap", let n = v as? Double { v = n.rounded() }
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
