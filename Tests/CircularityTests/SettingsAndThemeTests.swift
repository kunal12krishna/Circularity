@testable import CircularityEngine
import XCTest

final class ThemeContrastTests: XCTestCase {
    /// BRIEF.md: "a minimum 4.5:1 text contrast in every theme".
    func testTextOnAccentIsReadableInEveryThemeAndSwatch() {
        let accents = ThemeCatalog.all.map(\.accent) + ThemeCatalog.swatches.compactMap { RGB(hexString: $0) }
        for accent in accents {
            let ratio = accent.contrast(with: ThemeCatalog.onAccent(accent))
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "text on \(accent.hexString) is \(ratio)")
        }
    }

    func testCustomDarkAccentsGetWhiteText() {
        XCTAssertEqual(ThemeCatalog.onAccent(RGB(hex: 0x1A237E)), .white)
        XCTAssertEqual(ThemeCatalog.onAccent(RGB(hex: 0xC6FF3D)), ThemeCatalog.darkText)
    }

    func testRingLabelsOverAnyBackdropAndGlassStrength() {
        for backdrop in [RGB.white, .black, RGB(hex: 0x3B6FD8)] {
            for strength in stride(from: 0.0, through: 1.0, by: 0.25) {
                let dark = ThemeCatalog.ringDisc(over: backdrop, strength: strength, light: false)
                XCTAssertGreaterThanOrEqual(RGB(hex: 0xF4F1EC).contrast(with: dark), 4.5, "dark ring over \(backdrop.hexString) at \(strength)")
                let light = ThemeCatalog.ringDisc(over: backdrop, strength: strength, light: true)
                XCTAssertGreaterThanOrEqual(RGB(hex: 0x1D1B18).contrast(with: light), 4.5, "light ring over \(backdrop.hexString) at \(strength)")
            }
        }
    }

    func testHaloAndPanelText() {
        XCTAssertGreaterThanOrEqual(RGB(hex: 0xECEEF2).contrast(with: RGB(hex: 0x1B1D23)), 4.5, "Halo labels")
        XCTAssertGreaterThanOrEqual(RGB(hex: 0x9097A6).contrast(with: RGB(hex: 0x1B1D23)), 4.5, "Halo captions")
        for backdrop in [RGB.white, .black] {
            let panel = ThemeCatalog.panelBackground(over: backdrop)
            for token: UInt32 in [0xF4F1EC, 0xC9C3B9, 0xB4AEA5, 0xA9A39A] {
                XCTAssertGreaterThanOrEqual(RGB(hex: token).contrast(with: panel), 4.5, "panel text \(String(token, radix: 16)) over \(backdrop.hexString)")
            }
            for theme in ThemeCatalog.all {
                // Links use the accent mixed 40 % toward white; big numbers use the accent (large text: 3:1).
                XCTAssertGreaterThanOrEqual(theme.accent.mixed(with: .white, 0.4).contrast(with: panel), 4.5, "\(theme.name) links")
                XCTAssertGreaterThanOrEqual(theme.accent.contrast(with: panel), 3.0, "\(theme.name) large accent text")
            }
        }
    }

    func testThemeLookup() {
        XCTAssertEqual(ThemeCatalog.theme(forAccent: "#c6ff3d")?.id, "neon")
        XCTAssertEqual(ThemeCatalog.theme(forAccent: "#ff4fa0")?.id, "riso")
        XCTAssertNil(ThemeCatalog.theme(forAccent: "#123456"))
        XCTAssertEqual(RGB(hexString: "#FF8A00")?.hexString, "#FF8A00")
    }
}

final class CollisionStyleTests: XCTestCase {
    func testTimestampThenNumbers() {
        let date = Date(timeIntervalSince1970: 1_763_421_005) // 2025-11-17 23:10:05 UTC
        let utc = TimeZone(identifier: "UTC")!
        var taken: Set<String> = ["photo.jpg"]
        let first = OutputNaming.uniqueFileName(base: "photo", fileExtension: "jpg", collision: .timestamp, date: date, timeZone: utc) { taken.contains($0) }
        XCTAssertEqual(first, "photo 2025-11-17 at 23.10.05.jpg")
        taken.insert(first)
        let second = OutputNaming.uniqueFileName(base: "photo", fileExtension: "jpg", collision: .timestamp, date: date, timeZone: utc) { taken.contains($0) }
        XCTAssertEqual(second, "photo (1).jpg")
    }
}

final class SettingsSchemaTests: XCTestCase {
    /// Every `static let … = SettingsKey(` in SettingsKeys.swift must be in `all`
    /// (otherwise it would not be exported, imported or reset).
    func testEveryDeclaredKeyIsListed() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Shared/SettingsKeys.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let declared = try NSRegularExpression(pattern: #"static let (\w+) = SettingsKey\("#)
            .matches(in: text, range: NSRange(text.startIndex..., in: text)).count
        XCTAssertEqual(declared, SettingsKeys.all.count)
    }
}

final class HotkeySpecTests: XCTestCase {
    func testDefaultsParse() {
        let panel = HotkeySpec(SettingsKeys.hotkeyPanel.defaultValue)
        XCTAssertEqual(panel?.display, "⌃⌥Space")
        XCTAssertEqual(HotkeySpec(SettingsKeys.hotkeyClipboard.defaultValue)?.display, "⌃⌥V")
        XCTAssertEqual(panel?.stored, "49:6144")
    }

    func testOffAndMalformed() {
        XCTAssertNil(HotkeySpec(""))
        XCTAssertNil(HotkeySpec("abc"))
        XCTAssertNil(HotkeySpec("400:256"))
    }

    func testNeedsARealModifier() {
        XCTAssertFalse(HotkeySpec(keyCode: 0, modifiers: HotkeySpec.shift).isAllowed)
        XCTAssertTrue(HotkeySpec(keyCode: 0, modifiers: HotkeySpec.command | HotkeySpec.shift).isAllowed)
        XCTAssertEqual(HotkeySpec(keyCode: 122, modifiers: HotkeySpec.command | HotkeySpec.shift).display, "⇧⌘F1")
    }
}

final class SettingsMigrationTests: XCTestCase {
    /// The settings daemon can write a scratch file back after it was deleted: sweep earlier runs' leftovers too.
    override class func tearDown() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences", isDirectory: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("circularity.tests.") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        super.tearDown()
    }

    /// A fixed domain per test, emptied before and after: never a new name per run (the settings
    /// daemon keeps a handle open for every domain it has seen, and thousands run it out).
    private func freshDefaults(_ name: String) -> UserDefaults {
        let suite = "circularity.tests.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return d
    }

    /// The migration logic lives in the app target; this mirrors its rules on
    /// raw defaults so the v1 → v2 mapping is pinned down.
    private func migrate(_ d: UserDefaults) {
        let stored = d.integer(forKey: SettingsKeys.schemaVersionKey)
        if stored == 0, d.object(forKey: SettingsKeys.wheelLayout.name) == nil { d.set(2, forKey: SettingsKeys.schemaVersionKey); return }
        if stored < 2, d.object(forKey: SettingsKeys.accentHex.name) == nil {
            let layout = d.string(forKey: SettingsKeys.wheelLayout.name) ?? "halo"
            d.set(layout == "halo" ? (d.string(forKey: SettingsKeys.haloAccentHex.name) ?? "#C6FF3D") : "#FF8A00",
                  forKey: SettingsKeys.accentHex.name)
        }
        d.set(2, forKey: SettingsKeys.schemaVersionKey)
    }

    func testV1HaloUserKeepsTheirAccent() {
        let d = freshDefaults("halo")
        d.set(1, forKey: SettingsKeys.schemaVersionKey)
        d.set("halo", forKey: SettingsKeys.wheelLayout.name)
        d.set("#5CE1FF", forKey: SettingsKeys.haloAccentHex.name)
        migrate(d)
        XCTAssertEqual(d.string(forKey: SettingsKeys.accentHex.name), "#5CE1FF")
    }

    func testV1RingUserKeepsTangerine() {
        let d = freshDefaults("ring")
        d.set(1, forKey: SettingsKeys.schemaVersionKey)
        d.set("ring", forKey: SettingsKeys.wheelLayout.name)
        migrate(d)
        XCTAssertEqual(d.string(forKey: SettingsKeys.accentHex.name), "#FF8A00")
    }

    func testFreshInstallGetsRisoDefault() {
        let d = freshDefaults("fresh")
        migrate(d)
        XCTAssertNil(d.object(forKey: SettingsKeys.accentHex.name), "nothing stored: the registered default (riso) applies")
        XCTAssertEqual(SettingsKeys.accentHex.defaultValue, "#FF4FA0")
        XCTAssertEqual(SettingsKeys.accentHex.defaultValue, ThemeCatalog.defaultAccentHex)
        XCTAssertEqual(ThemeCatalog.theme(id: SettingsKeys.theme.defaultValue)?.accent.hexString, ThemeCatalog.defaultAccentHex)
    }
}
