import CircularityEngine
import Foundation

// EngineSmokeTest (PLAN.md §4): drives the real engine end to end and exits
// non-zero on any failure. Milestone (a) checks naming, name reservation and
// the concurrency limit; (d) and (f) add generated fixtures and every
// conversion, resize, crop and compress.

var failures = 0
@MainActor func check(_ condition: Bool, _ label: String) {
    print(condition ? "PASS  \(label)" : "FAIL  \(label)")
    if !condition { failures += 1 }
}

let workDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("EngineSmokeTest-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDir) }

// Naming against a real directory.
let source = workDir.appendingPathComponent("photo.heic")
try Data().write(to: source)
try Data().write(to: workDir.appendingPathComponent("photo.png"))

let planner = OutputPlanner()
let png = await planner.reserve(in: workDir, context: NamingContext(sourceURL: source, format: .png, operation: .convert))
check(png.lastPathComponent == "photo (1).png", "collision with an existing file gets (1): \(png.lastPathComponent)")
let png2 = await planner.reserve(in: workDir, context: NamingContext(sourceURL: source, format: .png, operation: .convert))
check(png2.lastPathComponent == "photo (2).png", "a reserved name is skipped: \(png2.lastPathComponent)")
let resized = await planner.reserve(in: workDir, context: NamingContext(sourceURL: source, format: .jpg, operation: .resize))
check(resized.lastPathComponent == "photo (resized).jpg", "resize suffix: \(resized.lastPathComponent)")

// Concurrency limit through the real queue.
actor Gauge {
    var current = 0, peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}
let queue = JobQueue()
let gauge = Gauge()
await withTaskGroup(of: Void.self) { group in
    for _ in 0..<8 {
        group.addTask {
            _ = try? await queue.run {
                await gauge.enter()
                try await Task.sleep(nanoseconds: 20_000_000)
                await gauge.leave()
            }
        }
    }
}
let peak = await gauge.peak
check(peak == 2, "at most 2 jobs run at once (peak \(peak))")

print(failures == 0 ? "EngineSmokeTest: all checks passed" : "EngineSmokeTest: \(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
