@testable import CircularityEngine
import XCTest

final class JobQueueTests: XCTestCase {
    private actor Gauge {
        var current = 0, peak = 0, finished = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1; finished += 1 }
    }

    func testNeverRunsMoreThanTheLimit() async throws {
        let queue = JobQueue(maxConcurrent: 2)
        let gauge = Gauge()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await queue.run {
                        await gauge.enter()
                        try await Task.sleep(nanoseconds: 10_000_000)
                        await gauge.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await gauge.peak
        let finished = await gauge.finished
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(finished, 10)
        let running = await queue.runningCount
        XCTAssertEqual(running, 0, "every slot is released")
    }

    func testAThrowingJobReleasesItsSlot() async {
        struct Boom: Error {}
        let queue = JobQueue(maxConcurrent: 1)
        do {
            _ = try await queue.run { () async throws -> Int in throw Boom() }
            XCTFail("expected a throw")
        } catch {}
        let value = try? await queue.run { 42 }
        XCTAssertEqual(value, 42)
    }
}
