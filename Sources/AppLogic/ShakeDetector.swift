import CoreGraphics
import Foundation

/// Detects a quick horizontal shake of the cursor during a file drag
/// (PLAN.md §3.2, A3). Pure value type; fed with sampled x positions.
nonisolated struct ShakeDetector: Sendable, Equatable {
    struct Thresholds: Sendable, Equatable {
        /// Direction changes needed.
        var reversals: Int
        /// Minimum travel (pt) of each swing before it counts.
        var minimumTravel: CGFloat
        /// All counted reversals must fall inside this window (s).
        var window: TimeInterval

        static let low = Thresholds(reversals: 4, minimumTravel: 60, window: 0.7)
        static let medium = Thresholds(reversals: 3, minimumTravel: 40, window: 0.6)
        static let high = Thresholds(reversals: 3, minimumTravel: 25, window: 0.7)

        static func named(_ name: String) -> Thresholds {
            switch name {
            case "low": .low
            case "high": .high
            default: .medium
            }
        }
    }

    var thresholds: Thresholds
    private var direction = 0           // +1 moving right, -1 moving left, 0 unknown
    private var extremeX: CGFloat?      // furthest x reached in the current direction
    private var reversalTimes: [TimeInterval] = []

    init(thresholds: Thresholds = .medium) {
        self.thresholds = thresholds
    }

    mutating func reset() {
        direction = 0
        extremeX = nil
        reversalTimes.removeAll()
    }

    /// Adds a sample; returns true when a shake has just completed.
    mutating func add(x: CGFloat, time: TimeInterval) -> Bool {
        guard let extreme = extremeX else {
            extremeX = x
            return false
        }
        let delta = x - extreme
        if direction == 0 {
            if abs(delta) >= thresholds.minimumTravel {
                direction = delta > 0 ? 1 : -1
                extremeX = x
            }
            return false
        }
        if delta != 0, (delta > 0) == (direction > 0) {
            extremeX = x // still travelling the same way: push the extreme out
            return false
        }
        guard abs(delta) >= thresholds.minimumTravel else { return false }
        direction = -direction
        extremeX = x
        reversalTimes.append(time)
        reversalTimes.removeAll { time - $0 > thresholds.window }
        if reversalTimes.count >= thresholds.reversals {
            reset()
            return true
        }
        return false
    }
}
