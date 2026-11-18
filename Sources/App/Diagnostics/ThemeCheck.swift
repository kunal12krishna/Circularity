import Foundation

/// `--check-themes <file.json>`: proves that wheels from the website's Wheel
/// Studio come into the app intact. The file holds `themes` (what "Copy for
/// the app" copies) and `links` (Studio share links). Each one is pasted into
/// a scratch settings store exactly as Settings → Appearance → Paste theme
/// does; every value must read back unchanged, nothing may be skipped, and the
/// wheel's style and geometry must build from the result. Exit 0 = all good.
@MainActor
enum ThemeCheck {
    static func run(_ file: URL) -> Bool {
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
            if let problem = check(json) { failures += 1; print("FAIL \(label): \(problem)") }
        }
        print("check-themes: \(checked - failures) of \(checked) Studio wheels import cleanly")
        return failures == 0 && checked > 0
    }

    /// nil when the theme imports in full; otherwise what went wrong.
    private static func check(_ json: Data?) -> String? {
        guard let json, let theme = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let values = theme["values"] as? [String: Any] else { return "not a theme" }
        let suite = "\(AppIdentity.bundleID).themecheck.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return "no scratch defaults" }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults, suiteName: suite)
        guard let result = try? store.importJSON(json, only: SettingsModel.themeKeys) else { return "Paste theme refused it" }
        if !result.skipped.isEmpty { return "skipped \(result.skipped.joined(separator: ", "))" }
        if result.applied != values.count { return "applied \(result.applied) of \(values.count)" }
        for (name, sent) in values {
            let got = store.raw(name)
            let same: Bool
            if let a = sent as? Double, let b = (got as? Double) ?? (got as? Int).map(Double.init) { same = abs(a - b) < 0.0001 }
            else if let a = sent as? String, let b = got as? String { same = a.uppercased() == b.uppercased() }
            else { same = false }
            if !same { return "\(name): sent \(sent), stored \(String(describing: got))" }
        }
        guard let layout = WheelLayoutKind(rawValue: store.value(SettingsKeys.wheelLayout)) else { return "unknown layout" }
        let geometry = Appearance.geometry(store, layout: layout)
        let wanted = min(1.4, max(0.7, store.value(SettingsKeys.wheelScale)))
        if abs(Double(geometry.scale) - wanted) > 0.001 { return "the wheel's size came out \(geometry.scale), not \(wanted)" }
        _ = Appearance.wheelStyle(store, layout: layout)
        if Appearance.accentRGB(store).hexString != RGB(hexString: store.value(SettingsKeys.accentHex))?.hexString { return "the accent didn't reach the wheel" }
        return nil
    }
}
