import Foundation

/// Typed settings backed by UserDefaults (PLAN.md §3.7). Milestone (i) adds
/// observation for the live-preview settings window, JSON export/import and
/// migrations; the schema itself lives in `SettingsKeys` (Shared).
final class SettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var registered: [String: Any] = [:]
        for key in SettingsKeys.all { registered[key.name] = key.defaultValue }
        defaults.register(defaults: registered)
        if defaults.integer(forKey: SettingsKeys.schemaVersionKey) == 0 {
            defaults.set(SettingsKeys.schemaVersion, forKey: SettingsKeys.schemaVersionKey)
        }
    }

    func value<Value>(_ key: SettingsKey<Value>) -> Value {
        defaults.object(forKey: key.name) as? Value ?? key.defaultValue
    }

    func set<Value>(_ value: Value, for key: SettingsKey<Value>) {
        defaults.set(value, forKey: key.name)
    }

    /// "Reset all settings" (Settings → General).
    func resetAll() {
        for key in SettingsKeys.all { defaults.removeObject(forKey: key.name) }
    }
}
