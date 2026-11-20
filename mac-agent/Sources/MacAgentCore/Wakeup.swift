import Foundation

/// A coalescing wake-up signal: `signal()` wakes one pending `wait(timeout:)`, or is remembered for
/// the next call. Multiple signals before a wait collapse into one.
public actor Wakeup {
    private var pending = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var generation = 0

    public init() {}

    public func signal() {
        if let w = waiter {
            waiter = nil
            w.resume()
        } else {
            pending = true
        }
    }

    /// Clears a remembered signal (used after debouncing).
    public func drain() { pending = false }

    /// Returns when signalled or after `timeout` seconds, whichever comes first.
    public func wait(timeout: TimeInterval) async {
        if pending {
            pending = false
            return
        }
        generation += 1
        let gen = generation
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiter = c
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                await self?.fireTimeout(gen)
            }
        }
    }

    private func fireTimeout(_ gen: Int) {
        guard gen == generation, let w = waiter else { return }
        waiter = nil
        w.resume()
    }
}

/// Exponential backoff: 1, 2, 4 … seconds, capped.
public struct Backoff: Sendable {
    public var base: TimeInterval
    public var cap: TimeInterval
    public private(set) var attempt = 0

    public init(base: TimeInterval = 1, cap: TimeInterval = 300) {
        self.base = base
        self.cap = cap
    }

    public mutating func next() -> TimeInterval {
        let delay = min(cap, base * pow(2, Double(min(attempt, 20))))
        attempt += 1
        return delay
    }

    public mutating func reset() { attempt = 0 }
}

public func sleepSeconds(_ s: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000))
}
