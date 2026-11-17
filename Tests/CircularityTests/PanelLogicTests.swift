import CircularityEngine
import Foundation
import XCTest

final class CommandParserTests: XCTestCase {
    func testFormats() {
        XCTAssertEqual(CommandParser.parse("webp").first, .convert(.webp))
        XCTAssertEqual(CommandParser.parse("JPEG").first, .convert(.jpg))
        XCTAssertEqual(CommandParser.parse("to png").first, .convert(.png))
    }

    func testSizes() {
        XCTAssertEqual(CommandParser.parse("< 2mb").first, .compressUnder(2_000_000))
        XCTAssertEqual(CommandParser.parse("<500kb").first, .compressUnder(500_000))
        XCTAssertEqual(CommandParser.parse("under 1.5 mb").first, .compressUnder(1_500_000))
        XCTAssertEqual(CommandParser.parse("1920w").first, .resizeWidth(1920))
    }

    func testWordsAndPrefixes() {
        XCTAssertEqual(CommandParser.parse("no gps").first, .stripGPS)
        XCTAssertEqual(CommandParser.parse("clipboard").first, .clipboard(nil))
        XCTAssertEqual(CommandParser.parse("clip jpg").first, .clipboard(.jpg))
        XCTAssertEqual(CommandParser.parse("pau").first, .pause)
        XCTAssertEqual(CommandParser.parse("watch").first, .watch)
        XCTAssertEqual(CommandParser.parse("merge").first, .combine)
        XCTAssertTrue(CommandParser.parse("").isEmpty)
        XCTAssertTrue(CommandParser.parse("zzz").isEmpty)
    }
}

final class FuzzyMatcherTests: XCTestCase {
    func testSubsequenceAndRanking() {
        XCTAssertNotNil(FuzzyMatcher.score("bch", in: "beach.png"))
        XCTAssertNil(FuzzyMatcher.score("xyz", in: "beach.png"))
        let ranked = FuzzyMatcher.rank(["portfolio (compressed).pdf", "beach.png", "hero (resized).jpg"], query: "png") { $0 }
        XCTAssertEqual(ranked.first, "beach.png")
        XCTAssertEqual(FuzzyMatcher.rank(["a", "b"], query: "") { $0 }.count, 2)
    }
}

final class StatsMathTests: XCTestCase {
    func testRecordAndWeek() {
        var days: [String: DayStats] = [:]
        let now = Date()
        StatsMath.record(&days, date: now, files: 2, bytesIn: 1_000, bytesOut: 400, format: "JPG")
        StatsMath.record(&days, date: now, files: 1, bytesIn: 500, bytesOut: 900, format: "PNG")
        let today = days[StatsMath.dayKey(now)]
        XCTAssertEqual(today?.files, 3)
        XCTAssertEqual(today?.byFormat["JPG"], 2)
        XCTAssertEqual(today?.saved, 200, "1500 in, 1300 out")
        StatsMath.record(&days, date: now.addingTimeInterval(-10 * 86_400), files: 1, bytesIn: 10_000, bytesOut: 0, format: "PDF")
        XCTAssertEqual(StatsMath.savedLast(days, days: 7, now: now), 200, "older days are outside the week")
        XCTAssertEqual(StatsMath.lastDays(days, count: 30, now: now).count, 30)
        XCTAssertEqual(StatsMath.lastDays(days, count: 30, now: now).last?.stats.files, 3)
    }

    func testCapsAt400Days() {
        var days: [String: DayStats] = [:]
        for i in 0..<420 {
            StatsMath.record(&days, date: Date().addingTimeInterval(-Double(i) * 86_400), files: 1, bytesIn: 1, bytesOut: 1, format: "JPG")
        }
        XCTAssertLessThanOrEqual(days.count, 400)
    }

    func testHistoryPercent() {
        let item = HistoryItem(id: "1", date: Date(), inputs: [], outputs: ["/a.jpg"], bytesIn: 1000, bytesOut: 220, label: "x", format: "JPG")
        XCTAssertEqual(item.percentChange, -78)
        XCTAssertEqual(item.name, "a.jpg")
    }
}

final class WatchRuleTests: XCTestCase {
    private let rule = WatchRule(folder: "/tmp/w", match: .images, format: .jpg)

    func testAcceptsNewImages() {
        XCTAssertTrue(rule.accepts(URL(fileURLWithPath: "/tmp/w/Screenshot.png"), kind: .image))
    }

    func testSkipsPartialHiddenAndAlreadyTargetFiles() {
        XCTAssertFalse(rule.accepts(URL(fileURLWithPath: "/tmp/w/.hidden.png"), kind: .image))
        XCTAssertFalse(rule.accepts(URL(fileURLWithPath: "/tmp/w/photo.png.download"), kind: .other))
        XCTAssertFalse(rule.accepts(URL(fileURLWithPath: "/tmp/w/photo.crdownload"), kind: .other))
        XCTAssertFalse(rule.accepts(URL(fileURLWithPath: "/tmp/w/photo.jpg"), kind: .image), "already JPG: no loop")
        XCTAssertFalse(rule.accepts(URL(fileURLWithPath: "/tmp/w/report.pdf"), kind: .pdf), "images only")
    }

    func testCodable() throws {
        var r = rule
        r.output = .subfolder("Converted")
        let data = try JSONEncoder().encode([r])
        XCTAssertEqual(try JSONDecoder().decode([WatchRule].self, from: data), [r])
    }
}
