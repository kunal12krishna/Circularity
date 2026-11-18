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
        let perf = LaunchArguments(["Circularity", "--perf-report", "docs/PERF-REPORT.md"]) { _ in false }
        XCTAssertTrue(perf.perfReport)
        XCTAssertEqual(perf.perfReportFile?.lastPathComponent, "PERF-REPORT.md")
        XCTAssertNil(LaunchArguments(["Circularity", "--perf-report"]) { _ in false }.perfReportFile)
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

final class UpdateLogicTests: XCTestCase {
    func testVersionOrder() {
        XCTAssertTrue(VersionCompare.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(VersionCompare.isNewer("1.10", than: "1.9.9"))
        XCTAssertFalse(VersionCompare.isNewer("0.1.0", than: "0.1"))
        XCTAssertFalse(VersionCompare.isNewer("0.2.0-beta", than: "0.2.0"))
        XCTAssertTrue(VersionCompare.isNewer("0.2.0", than: "0.2.0-beta"))
        XCTAssertTrue(VersionCompare.isNewer("v1.0.0", than: "0.9"))
    }

    func testFeedDecodes() throws {
        let json = #"{"version":"0.2.0","url":"https://example.com/Circularity-0.2.0.dmg","notes":"Cut out"}"#
        let feed = try JSONDecoder().decode(UpdateFeed.self, from: Data(json.utf8))
        XCTAssertEqual(feed.version, "0.2.0")
        XCTAssertNil(feed.minimumSystem)
    }
}
