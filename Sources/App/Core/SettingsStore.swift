import Combine
import Foundation

/// Typed settings backed by UserDefaults (PLAN.md §3.7). Every change is
/// published on `changes` so open windows, the wheel and the panel apply it
/// instantly. JSON export/import and versioned migrations live here.
final class SettingsStore {
    private let defaults: UserDefaults
    /// The name of each key as it changes ("" after a bulk change).
    let changes = PassthroughSubject<String, Never>()

    /// What was actually stored (not registered defaults, which are shared by
    /// every UserDefaults in the process).
    private let storedDomain: () -> [String: Any]

    /// `suiteName`: the suite `defaults` was made with (nil = the app's own domain).
    init(defaults: UserDefaults = .standard, suiteName: String? = nil) {
        self.defaults = defaults
        let domain = suiteName ?? Bundle.main.bundleIdentifier ?? AppIdentity.bundleID
        storedDomain = { defaults.persistentDomain(forName: domain) ?? [:] }
        migrate()
        var registered: [String: Any] = [:]
        for key in SettingsKeys.all { registered[key.name] = key.defaultValue }
        defaults.register(defaults: registered)
    }

    func value<Value>(_ key: SettingsKey<Value>) -> Value {
        defaults.object(forKey: key.name) as? Value ?? key.defaultValue
    }

    func set<Value>(_ value: Value, for key: SettingsKey<Value>) {
        defaults.set(value, forKey: key.name)
        changes.send(key.name)
    }

    func remove(_ name: String) {
        defaults.removeObject(forKey: name)
        changes.send(name)
    }

    /// "Reset all settings" (Settings → General). Keeps onboarding done,
    /// history/stats files and watch rules are separate and not touched here.
    func resetAll() {
        let keep: Set<String> = [SettingsKeys.onboardingCompleted.name, SettingsKeys.schemaVersionKey, SettingsKeys.watchRulesJSON.name]
        for key in SettingsKeys.all where !keep.contains(key.name) { defaults.removeObject(forKey: key.name) }
        changes.send("")
    }

    // MARK: Migrations

    private func migrate() {
        let domain = storedDomain()
        let stored = domain[SettingsKeys.schemaVersionKey] as? Int ?? 0
        if stored == 0 {
            // A brand-new install, or a v1 install that never wrote the version.
            if domain[SettingsKeys.wheelLayout.name] == nil {
                defaults.set(SettingsKeys.schemaVersion, forKey: SettingsKeys.schemaVersionKey)
                return
            }
        }
        if stored < 2 {
            // v1 had a separate Halo accent; v2 has one accent for everything.
            if domain[SettingsKeys.accentHex.name] == nil {
                let layout = domain[SettingsKeys.wheelLayout.name] as? String ?? "halo"
                if layout == "halo" {
                    let neon = domain[SettingsKeys.haloAccentHex.name] as? String ?? "#C6FF3D"
                    defaults.set(neon, forKey: SettingsKeys.accentHex.name)
                    defaults.set(ThemeCatalog.theme(forAccent: neon)?.id ?? "custom", forKey: SettingsKeys.theme.name)
                } else {
                    defaults.set("#FF8A00", forKey: SettingsKeys.accentHex.name)
                    defaults.set("tangerine", forKey: SettingsKeys.theme.name)
                }
            }
        }
        defaults.set(SettingsKeys.schemaVersion, forKey: SettingsKeys.schemaVersionKey)
    }

    // MARK: Export / import (Settings → Advanced)

    struct Snapshot: Codable {
        var app: String
        var schemaVersion: Int
        var values: [String: JSONValue]
    }

    /// `only`: export just these key names (a theme file); nil = everything.
    func exportJSON(only: Set<String>? = nil) throws -> Data {
        var values: [String: JSONValue] = [:]
        for key in SettingsKeys.all where !key.reserved && only.map({ $0.contains(key.name) }) ?? true {
            if let v = JSONValue(defaults.object(forKey: key.name) ?? key.defaultValue) { values[key.name] = v }
        }
        let snapshot = Snapshot(app: AppIdentity.name, schemaVersion: SettingsKeys.schemaVersion, values: values)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    /// Applies known keys whose type matches the default; returns how many
    /// were applied and the names that were skipped.
    @discardableResult
    func importJSON(_ data: Data) throws -> (applied: Int, skipped: [String]) {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        var applied = 0
        var skipped: [String] = []
        for (name, value) in snapshot.values {
            guard let key = SettingsKeys.all.first(where: { $0.name == name }), let object = value.matching(key.defaultValue) else {
                skipped.append(name)
                continue
            }
            defaults.set(object, forKey: name)
            applied += 1
        }
        changes.send("")
        return (applied, skipped.sorted())
    }
}

/// Property-list values as JSON (for settings export/import).
enum JSONValue: Codable, Equatable {
    case bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init?(_ any: Any) {
        if let n = any as? NSNumber {
            // CFBoolean is the only reliable way to tell true/false from 1/0.
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
            return
        }
        switch any {
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.compactMap(JSONValue.init))
        case let d as [String: Any]: self = .object(d.compactMapValues(JSONValue.init))
        default: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .bool(b): try c.encode(b)
        case let .number(n): try c.encode(n)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    /// Converts to a plist object of the same type as `prototype`, or nil.
    func matching(_ prototype: Any) -> Any? {
        switch (self, prototype) {
        case let (.bool(b), _ as Bool): return b
        case let (.number(n), _ as Int): return Int(n)
        case let (.number(n), _ as Double): return n
        case let (.string(s), _ as String): return s
        case let (.array(a), _ as [String]): return a.compactMap { if case let .string(s) = $0 { return s }; return nil }
        case let (.object(o), _ as [String: Int]): return o.compactMapValues { if case let .number(n) = $0 { return Int(n) }; return nil }
        case let (.object(o), _ as [String: String]): return o.compactMapValues { if case let .string(s) = $0 { return s }; return nil }
        default: return nil
        }
    }
}
