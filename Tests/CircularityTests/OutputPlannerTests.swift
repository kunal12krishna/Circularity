@testable import CircularityEngine
import XCTest

final class OutputPlannerTests: XCTestCase {
    private let dir = URL(fileURLWithPath: "/tmp/out", isDirectory: true)
    private let source = URL(fileURLWithPath: "/tmp/in/scan.pdf")

    func testConcurrentReservationsNeverCollide() async {
        let planner = OutputPlanner(fileExists: { _ in false })
        let context = NamingContext(sourceURL: source, format: .png, operation: .convert)
        let dir = self.dir
        let urls = await withTaskGroup(of: URL.self, returning: [URL].self) { group in
            for _ in 0..<20 { group.addTask { await planner.reserve(in: dir, context: context) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(Set(urls).count, 20)
        XCTAssertTrue(urls.contains(dir.appendingPathComponent("scan.png")))
    }

    func testReleaseFreesTheName() async {
        let planner = OutputPlanner(fileExists: { _ in false })
        let context = NamingContext(sourceURL: source, format: .pdf, operation: .combine)
        let first = await planner.reserve(in: dir, context: context)
        XCTAssertEqual(first.lastPathComponent, "scan (combined).pdf")
        await planner.release(first)
        let again = await planner.reserve(in: dir, context: context)
        XCTAssertEqual(again, first)
        let count = await planner.reservedCount
        XCTAssertEqual(count, 1)
    }

    func testExistingFilesAreSkipped() async {
        let existing = dir.appendingPathComponent("scan.png").path
        let planner = OutputPlanner(fileExists: { $0 == existing })
        let url = await planner.reserve(in: dir, context: NamingContext(sourceURL: source, format: .png, operation: .convert))
        XCTAssertEqual(url.lastPathComponent, "scan (1).png")
    }
}
