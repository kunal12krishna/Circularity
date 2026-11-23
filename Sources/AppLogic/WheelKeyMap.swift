import Foundation

/// Which modifier opens which wheel (Settings → Gesture). Each key opens at
/// most one wheel: if two wheels name the same key, Convert keeps it, then
/// Tools; the other wheel is off until it gets a key of its own.
nonisolated struct WheelKeyMap: Sendable, Equatable {
    static let keyNames = ["shift", "option", "control", "command"]

    /// Resolved: wheel → key name ("shift", "command"…). Missing = off.
    private(set) var keys: [WheelKind: String] = [:]

    init(convert: String, tools: String, actions: String) {
        var used: Set<String> = []
        for (kind, name) in [(WheelKind.convert, convert), (.tools, tools), (.actions, actions)] {
            let name = Self.keyNames.contains(name) ? name : (kind == .convert ? "shift" : "off")
            guard name != "off", !used.contains(name) else { continue }
            used.insert(name)
            keys[kind] = name
        }
    }

    func key(for kind: WheelKind) -> String? { keys[kind] }

    /// The wheels whose keys are in `down` (key names).
    func kinds(down: Set<String>) -> Set<WheelKind> {
        Set(keys.compactMap { down.contains($0.value) ? $0.key : nil })
    }

    static func symbol(_ name: String) -> String {
        switch name {
        case "shift": "⇧"
        case "option": "⌥"
        case "control": "⌃"
        case "command": "⌘"
        default: ""
        }
    }

    static func displayName(_ name: String) -> String {
        switch name {
        case "command": "Command"
        case "off": "Off"
        default: name.capitalized
        }
    }

    /// The centre's line at rest: how to reach the other wheels ("⌘ tools · ⌃ actions").
    func restHint(for kind: WheelKind) -> String? {
        let parts = WheelKind.allCases.filter { $0 != kind }.compactMap { other -> String? in
            keys[other].map { "\(Self.symbol($0)) \(other.title.lowercased())" }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A wheel that names a key another wheel already has ("Tools is off: Control opens Actions").
    func conflict(for kind: WheelKind, wanted: String) -> String? {
        guard wanted != "off", keys[kind] == nil,
              let owner = keys.first(where: { $0.value == wanted })?.key else { return nil }
        return "\(Self.displayName(wanted)) already opens \(owner.title), so \(kind.title) is off. Pick another key."
    }
}
