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

    /// The stored or default value of a key by name, untyped (preview cache keys).
    func raw(_ name: String) -> Any? { defaults.object(forKey: name) }

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
        let keep: Set<String> = [SettingsKeys.onboardingCompleted.name, SettingsKeys.schemaVersionKey, SettingsKeys.watchRulesJSON.name,
                                 SettingsKeys.milestones.name, SettingsKeys.updatesLastCheck.name]
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
    func importJSON(_ data: Data, only: Set<String>? = nil) throws -> (applied: Int, skipped: [String]) {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        var applied = 0
        var skipped: [String] = []
        for (name, value) in snapshot.values {
            guard only.map({ $0.contains(name) }) ?? true, let key = SettingsKeys.all.first(where: { $0.name == name }), !key.reserved,
                  !SettingsValidation.notImported.contains(name),
                  let object = value.matching(key.defaultValue), SettingsValidation.isValid(name, object) else {
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

/// What an imported settings file may contain (a typo or a hand-edited file
/// must not leave the app in a state its own controls can't produce).
enum SettingsValidation {
    /// State that lives outside our defaults (the Finder service, onboarding).
    /// Network use is only ever switched on by the user on this Mac, never by a file.
    static let notImported: Set<String> = [SettingsKeys.serviceShortcutInstalled.name, SettingsKeys.onboardingCompleted.name,
                                           SettingsKeys.schemaVersionKey, SettingsKeys.milestones.name,
                                           SettingsKeys.updatesLastCheck.name, SettingsKeys.updatesAutomatic.name]

    static let choices: [String: Set<String>] = [
        SettingsKeys.triggerKey.name: ["shift", "option", "control"],
        SettingsKeys.triggerMode.name: ["tap", "hold"],
        SettingsKeys.shakeSensitivity.name: ["low", "medium", "high"],
        SettingsKeys.wheelLayout.name: ["ring", "orbit", "halo"],
        SettingsKeys.soundPack.name: ["off", "soft", "click", "glass"],
        SettingsKeys.animationStyle.name: ["bloom", "pop", "fade", "instant"],
        SettingsKeys.destination.name: ["original", "folder"],
        SettingsKeys.collisionStyle.name: ["number", "time"],
        SettingsKeys.metadata.name: ["keep", "stripGPS", "stripAll"],
        SettingsKeys.theme.name: Set(ThemeCatalog.all.map(\.id) + ["custom"]),
        SettingsKeys.wheelScheme.name: ["auto", "system", "light", "dark"],
        SettingsKeys.panelScheme.name: ["auto", "system", "light", "dark"],
        SettingsKeys.fontStyle.name: ["rounded", "default", "mono"],
        SettingsKeys.labelCase.name: ["title", "upper"],
        SettingsKeys.panelLayout.name: ["stackPlus", "tabs", "mini"],
        SettingsKeys.panelWidth.name: ["s", "m", "l"],
        SettingsKeys.pinnedSize.name: ["s", "m", "l"],
        SettingsKeys.panelDensity.name: ["comfortable", "compact"],
        SettingsKeys.iconStyle.name: ["monochrome", "colour", "minimal"],
        SettingsKeys.presetGrid.name: ["3x1", "3x2", "4x2"],
    ]

    static let ranges: [String: ClosedRange<Double>] = [
        SettingsKeys.triggerDelayMs.name: 0...2000, SettingsKeys.moreHoverDelayMs.name: 0...2000,
        SettingsKeys.animationSpeed.name: 0.5...2, SettingsKeys.glassStrength.name: 0...1,
        SettingsKeys.wheelScale.name: 0.7...1.4, SettingsKeys.ringThickness.name: 0.8...1.2, SettingsKeys.segmentGap.name: 1...8,
        SettingsKeys.orbScale.name: 0.85...1.15, SettingsKeys.labelScale.name: 0.85...1.3,
        SettingsKeys.qualityJPG.name: 0.1...1, SettingsKeys.qualityHEIC.name: 0.1...1,
        SettingsKeys.qualityAVIF.name: 0.1...1, SettingsKeys.qualityWebP.name: 0.1...1,
    ]

    static func isValid(_ name: String, _ value: Any) -> Bool {
        if let allowed = choices[name] { return (value as? String).map(allowed.contains) ?? false }
        if let range = ranges[name] {
            let n = (value as? Double) ?? (value as? Int).map(Double.init)
            return n.map(range.contains) ?? false
        }
        switch name {
        case SettingsKeys.recentsCount.name:
            return [5, 10, 25].contains(value as? Int ?? 0)
        case SettingsKeys.hotkeyPanel.name, SettingsKeys.hotkeyClipboard.name:
            guard let s = value as? String else { return false }
            return s.isEmpty || HotkeySpec(s)?.isAllowed == true
        case SettingsKeys.imageSlots.name:
            guard let s = value as? String else { return false }
            return s.isEmpty || SlotProvider.parseSlots(s) != nil
        case SettingsKeys.accentHex.name:
            return (value as? String).flatMap(RGB.init(hexString:)) != nil
        case SettingsKeys.tintImages.name, SettingsKeys.tintDocuments.name, SettingsKeys.tintTools.name:
            guard let s = value as? String else { return false }
            return s.isEmpty || RGB(hexString: s) != nil
        default:
            return true
        }
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

    /// A whole number that fits comfortably in an Int, else nil (never traps).
    static func int(_ n: Double) -> Int? {
        guard n.isFinite, abs(n) < 1e12 else { return nil }
        return Int(n.rounded())
    }

    /// Converts to a plist object of the same type as `prototype`, or nil.
    func matching(_ prototype: Any) -> Any? {
        switch (self, prototype) {
        case let (.bool(b), _ as Bool): return b
        case let (.number(n), _ as Int): return Self.int(n)
        case let (.number(n), _ as Double): return n.isFinite ? n : nil
        case let (.string(s), _ as String): return s
        case let (.array(a), _ as [String]): return a.compactMap { if case let .string(s) = $0 { return s }; return nil }
        case let (.object(o), _ as [String: Int]): return o.compactMapValues { if case let .number(n) = $0 { return Self.int(n) }; return nil }
        case let (.object(o), _ as [String: String]): return o.compactMapValues { if case let .string(s) = $0 { return s }; return nil }
        default: return nil
        }
    }
}
