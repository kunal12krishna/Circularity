import Foundation

/// `--check-themes <file.json>`: proves that wheels from the website's Wheel
/// Studio come into the app intact. The file holds `themes` (what "Copy for
/// the app" copies) and `links` (Studio share links). Each one is pasted into
/// a scratch settings store exactly as Settings → Appearance → Paste theme
/// does; every value must read back unchanged, nothing may be skipped, and the
/// wheel's style and geometry must build from the result. Each one is also
/// pasted on top of a loud, different look (whole, and with half its keys
/// left out) and must come out exactly as on a fresh Mac: nothing from the
/// previous theme may linger. Exit 0 = all good.
@MainActor
enum ThemeCheck {
    static func run(_ file: URL, renderInto directory: URL? = nil) -> Bool {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("check-themes: can't read \(file.path)")
            return false
        }
        let themes = (root["themes"] as? [Any] ?? []).compactMap { try? JSONSerialization.data(withJSONObject: $0) }
        let links = root["links"] as? [String] ?? []
        var failures = 0, checked = 0
        for (label, json) in themes.enumerated().map({ ("theme \($0.offset)", Optional($0.element)) })
            + links.enumerated().map({ ("link \($0.offset)", StudioThemes.themeJSON(from: $0.element)) }) {
            checked += 1
            if let problem = check(json, render: directory.map { $0.appendingPathComponent(label.replacingOccurrences(of: " ", with: "-") + ".png") })
                ?? checkOverwrite(json) {
                failures += 1; print("FAIL \(label): \(problem)")
            }
        }
        print("check-themes: \(checked - failures) of \(checked) Studio wheels import cleanly")
        return failures == 0 && checked > 0
    }

    /// nil when the theme imports in full; otherwise what went wrong.
    private static func check(_ json: Data?, render: URL? = nil) -> String? {
        guard let json, let theme = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let values = theme["values"] as? [String: Any] else { return "not a theme" }
        let suite = "\(AppIdentity.bundleID).themecheck.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return "no scratch defaults" }
        defer { discard(defaults, suite) }
        let store = SettingsStore(defaults: defaults, suiteName: suite)
        guard let result = try? store.importJSON(json, only: SettingsModel.themeKeys, wholeLook: SettingsModel.lookKeys) else { return "Paste theme refused it" }
        if !result.skipped.isEmpty { return "skipped \(result.skipped.joined(separator: ", "))" }
        if result.applied != values.count { return "applied \(result.applied) of \(values.count)" }
        for (name, sent) in values {
            let got = store.raw(name)
            let same: Bool
            if let a = sent as? Bool, CFGetTypeID(sent as CFTypeRef) == CFBooleanGetTypeID() { same = (got as? Bool) == a }
            else if let a = sent as? Double, let b = (got as? Double) ?? (got as? Int).map(Double.init) { same = abs(a - b) < 0.0001 }
            else if let a = sent as? String, let b = got as? String { same = a.uppercased() == b.uppercased() }
            else { same = false }
            if !same { return "\(name): sent \(sent), stored \(String(describing: got))" }
        }
        guard let layout = WheelLayoutKind(rawValue: store.value(SettingsKeys.wheelLayout)) else { return "unknown layout" }
        let geometry = Appearance.geometry(store, layout: layout)
        let wanted = min(1.4, max(0.7, store.value(SettingsKeys.wheelScale)))
        if abs(Double(geometry.scale) - wanted) > 0.001 { return "the wheel's size came out \(geometry.scale), not \(wanted)" }
        _ = Appearance.wheelStyle(store, layout: layout)
        if let render {
            try? FileManager.default.createDirectory(at: render.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try RenderPreviews.renderTheme(store, to: render)
                try RenderPreviews.renderTheme(store, fanOpen: true, to: render.deletingPathExtension().appendingPathExtension("fan.png"))
            } catch { return "couldn't render: \(error)" }
        }
        if Appearance.accentRGB(store).hexString != RGB(hexString: store.value(SettingsKeys.accentHex))?.hexString { return "the accent didn't reach the wheel" }
        return nil
    }

    /// A look that differs from the defaults in every setting a theme carries.
    private static let loud: [String: Any] = [
        SettingsKeys.theme.name: "custom", SettingsKeys.accentHex.name: "#12AB34", SettingsKeys.glassStrength.name: 0.95,
        SettingsKeys.wheelScheme.name: "light", SettingsKeys.panelScheme.name: "light", SettingsKeys.tintImages.name: "#123456",
        SettingsKeys.tintDocuments.name: "#654321", SettingsKeys.tintTools.name: "#ABCDEF", SettingsKeys.wheelScale.name: 1.33,
        SettingsKeys.ringThickness.name: 1.17, SettingsKeys.segmentGap.name: 7, SettingsKeys.orbScale.name: 1.13,
        SettingsKeys.labelScale.name: 1.21, SettingsKeys.fontStyle.name: "mono", SettingsKeys.labelCase.name: "upper",
        SettingsKeys.fillStyle.name: "stickers", SettingsKeys.accent2Hex.name: "#FEDCBA", SettingsKeys.restOpacity.name: 0.37,
        SettingsKeys.discHex.name: "#0A0B0C", SettingsKeys.textHex.name: "#010203", SettingsKeys.hotTextHex.name: "#FAFBFC",
        SettingsKeys.rimHex.name: "#FF0000", SettingsKeys.rimWidth.name: 4.5, SettingsKeys.glow.name: 1.3,
        SettingsKeys.glowColor.name: "white", SettingsKeys.corners.name: 0.9, SettingsKeys.hoverPop.name: 2.1,
        SettingsKeys.discShadow.name: 0.11, SettingsKeys.captions.name: false, SettingsKeys.dimOthers.name: false,
        SettingsKeys.labelWeight.name: "regular", SettingsKeys.tracking.name: 0.27, SettingsKeys.breathe.name: 0.77,
        SettingsKeys.ringDots.name: 31, SettingsKeys.ringSpin.name: 17.0, SettingsKeys.twirl.name: true, SettingsKeys.sparks.name: true,
        SettingsKeys.wheelLayout.name: "orbit",
    ]

    /// nil when pasting `json` over another look leaves exactly what pasting it on a fresh Mac does.
    private static func checkOverwrite(_ json: Data?) -> String? {
        guard let json, var theme = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let values = theme["values"] as? [String: Any] else { return "not a theme" }
        let missing = SettingsModel.themeKeys.subtracting(loud.keys)
        if !missing.isEmpty { return "the loud look misses \(missing.sorted())" }
        // Whole, and with every other look setting left out (an older export, a short link).
        let names = values.keys.sorted()
        let partial = Dictionary(uniqueKeysWithValues: names.enumerated().filter { $0.offset % 2 == 0 || $0.element == SettingsKeys.wheelLayout.name }
            .map { ($0.element, values[$0.element]!) })
        for (variant, vals) in [("whole", values), ("half", partial)] {
            theme["values"] = vals
            guard let data = try? JSONSerialization.data(withJSONObject: theme) else { return "\(variant): not JSON" }
            let fresh = scratch(), dirty = scratch()
            defer { fresh.drop(); dirty.drop() }
            for (k, v) in loud { dirty.defaults.set(v, forKey: k) }
            for store in [fresh.store, dirty.store] {
                guard (try? store.importJSON(data, only: SettingsModel.themeKeys, wholeLook: SettingsModel.lookKeys)) != nil else { return "\(variant): refused" }
            }
            for name in SettingsModel.lookKeys.sorted() {
                let a = fresh.store.raw(name).map { "\($0)" } ?? "default", b = dirty.store.raw(name).map { "\($0)" } ?? "default"
                if a != b { return "\(variant) pasted over another look: \(name) kept \(b), a fresh paste gives \(a)" }
            }
        }
        return nil
    }

    /// Empties a scratch settings store and deletes its file: emptying alone
    /// leaves ~/Library/Preferences/<suite>.plist behind, one per wheel checked.
    static func discard(_ defaults: UserDefaults, _ suite: String) {
        defaults.removePersistentDomain(forName: suite)
        defaults.synchronize()
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist")
        try? FileManager.default.removeItem(at: file)
    }

    private struct Scratch {
        let suite: String, defaults: UserDefaults, store: SettingsStore
        func drop() { ThemeCheck.discard(defaults, suite) }
    }

    private static func scratch() -> Scratch {
        let suite = "\(AppIdentity.bundleID).themecheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return Scratch(suite: suite, defaults: defaults, store: SettingsStore(defaults: defaults, suiteName: suite))
    }
}
