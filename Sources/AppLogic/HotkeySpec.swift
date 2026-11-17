import Foundation

/// A global shortcut stored as "keyCode:carbonModifiers" (Settings → General).
/// Pure, unit-tested; Carbon's constants are spelled out so this file has no
/// framework dependency.
nonisolated struct HotkeySpec: Equatable, Sendable {
    var keyCode: Int
    var modifiers: Int

    static let command = 256, shift = 512, option = 2048, control = 4096

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// nil for "" (shortcut off) or anything malformed.
    init?(_ stored: String) {
        let parts = stored.split(separator: ":")
        guard parts.count == 2, let k = Int(parts[0]), let m = Int(parts[1]), k >= 0, k < 128 else { return nil }
        keyCode = k
        modifiers = m
    }

    var stored: String { "\(keyCode):\(modifiers)" }

    /// Needs ⌘, ⌃ or ⌥ — a bare letter or Shift+letter would steal typing.
    var isAllowed: Bool { modifiers & (Self.command | Self.control | Self.option) != 0 }

    /// "⌃⌥Space", in the macOS order ⌃⌥⇧⌘.
    var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    /// US-layout names for the virtual key codes (kVK_*).
    static let keyNames: [Int: String] = {
        var names: [Int: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
            45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
        ]
        let fKeys = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (i, code) in fKeys.enumerated() { names[code] = "F\(i + 1)" }
        return names
    }()
}
