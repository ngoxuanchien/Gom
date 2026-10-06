import Foundation
import Synchronization

/// Token bucket shared by every download of a queue, kept as a GCRA reservation clock:
/// each caller reserves the next free slot for its bytes and waits until that slot ends, so the
/// bytes passed by time t never exceed `rate * t` plus a short burst.
public final class BandwidthLimiter: Sendable {
    private struct State {
        var bytesPerSecond = 0   // 0 = unlimited
        var nextFree = ContinuousClock.now
        var generation = 0
    }
    private let state = Mutex(State())
    static let burst = Duration.milliseconds(250)

    public init() {}

    /// Combined cap in bytes/s; 0 = unlimited. A new value applies to callers already waiting.
    public var bytesPerSecond: Int {
        get { state.withLock { $0.bytesPerSecond } }
        set {
            state.withLock { s in
                s.bytesPerSecond = max(0, newValue)
                s.nextFree = .now
                s.generation += 1
            }
        }
    }

    /// Waits until `bytes` may be transferred. Cancellation ends the wait with an error.
    func acquire(_ bytes: Int) async throws {
        while true {
            let slot: (end: ContinuousClock.Instant, generation: Int)? = state.withLock { s in
                guard s.bytesPerSecond > 0 else { return nil }
                s.nextFree = max(.now - Self.burst, s.nextFree) + .seconds(Double(bytes) / Double(s.bytesPerSecond))
                return (s.nextFree, s.generation)
            }
            guard let slot else { return }
            // Short sleeps so a changed limit is noticed: the reservation is then made again at the new rate.
            var changed = false
            while !changed, ContinuousClock.now < slot.end {
                try await Task.sleep(for: min(.milliseconds(100), slot.end - .now))
                changed = state.withLock { $0.generation } != slot.generation
            }
            if !changed { return }
        }
    }
}

/// How many bytes one paced range request asks for: about a quarter second of the whole budget.
func pieceSize(for bytesPerSecond: Int) -> Int {
    max(64 * 1024, bytesPerSecond / 4)
}
