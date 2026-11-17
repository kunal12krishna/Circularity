import XCTest

final class SettingsKeysTests: XCTestCase {
    func testKeyNamesAreUnique() {
        let names = SettingsKeys.all.map(\.name)
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testV11KeysAreReservedAndOff() {
        let reserved = Set(SettingsKeys.all.filter(\.reserved).map(\.name))
        for name in ["media.packEnabled", "updates.channel", "cli.installed", "urlScheme.enabled",
                     "shortcuts.enabled", "office.automation", "gesture.advancedEventTap"] {
            XCTAssertTrue(reserved.contains(name), "\(name) should be reserved")
        }
        XCTAssertEqual(SettingsKeys.advancedEventTap.defaultValue, false)
    }

    func testAllThreeTriggersOnByDefault() {
        XCTAssertEqual(SettingsKeys.triggerKey.defaultValue, "shift")
        XCTAssertTrue(SettingsKeys.shakeEnabled.defaultValue)
    }
}

final class LaunchArgumentsTests: XCTestCase {
    private let files: Set<String> = ["/a/photo.png", "/a/scan.pdf"]

    func testFilesAndCocoaFlags() {
        let args = LaunchArguments(["Circularity", "-NSDocumentRevisionsDebugMode", "YES", "/a/photo.png",
                                    "/missing.png", "/a/scan.pdf"]) { self.files.contains($0) }
        XCTAssertEqual(args.files.map(\.path), ["/a/photo.png", "/a/scan.pdf"])
        XCTAssertNil(args.renderPreviewsDirectory)
    }

    func testDragTestFlag() {
        XCTAssertTrue(LaunchArguments(["Circularity", "--drag-test"]) { _ in false }.dragTest)
        XCTAssertFalse(LaunchArguments(["Circularity"]) { _ in false }.dragTest)
    }

    func testRenderPreviews() {
        let args = LaunchArguments(["Circularity", "--render-previews", "/tmp/previews"]) { _ in false }
        XCTAssertEqual(args.renderPreviewsDirectory?.path, "/tmp/previews")
        XCTAssertTrue(args.files.isEmpty)
    }

    func testAFlagFollowedByAFileKeepsTheFile() {
        let args = LaunchArguments(["Circularity", "-psn_0_1", "/a/photo.png"]) { self.files.contains($0) }
        XCTAssertEqual(args.files.map(\.path), ["/a/photo.png"])
    }
}
