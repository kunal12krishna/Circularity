import Foundation

/// Runs conversion work with a fixed concurrency limit (2 by default,
/// PLAN.md §3.1). Milestone (d) layers job specs, progress events, atomic
/// output and cancellation on top of this limiter.
public actor JobQueue {
    public nonisolated let maxConcurrent: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(maxConcurrent: Int = 2) {
        precondition(maxConcurrent > 0, "JobQueue needs at least one slot")
        self.maxConcurrent = maxConcurrent
    }

    /// Waits for a free slot, runs `work`, then frees the slot.
    public func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await work()
    }

    public var runningCount: Int { running }
    public var waitingCount: Int { waiters.count }

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        // The slot is handed over directly by `release()`, so `running` stays
        // unchanged when a waiter resumes.
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
