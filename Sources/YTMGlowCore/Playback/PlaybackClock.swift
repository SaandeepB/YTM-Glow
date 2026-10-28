import Foundation

/// Monotonic seconds, unaffected by wall-clock changes.
public typealias MonotonicClock = @Sendable () -> TimeInterval

public let systemMonotonicClock: MonotonicClock = { ProcessInfo.processInfo.systemUptime }

/// The last playback report from the browser, extrapolated forward in time
/// between reports.
public struct PlaybackClock: Equatable, Sendable {
    public var position: Double
    public var duration: Double?
    public var paused: Bool
    public var rate: Double
    public var ended: Bool
    /// Buffering: still "playing" for the glow, but the position holds.
    public var waiting: Bool
    /// Monotonic time the report was received.
    public var receivedAt: TimeInterval

    public init(position: Double, duration: Double?, paused: Bool, rate: Double = 1, ended: Bool = false, waiting: Bool = false, receivedAt: TimeInterval) {
        self.position = position.isFinite ? max(0, position) : 0
        if let duration, duration.isFinite, duration > 0 {
            self.duration = duration
        } else {
            self.duration = nil
        }
        self.paused = paused
        self.rate = rate.isFinite && rate > 0 ? rate : 1
        self.ended = ended
        self.waiting = waiting
        self.receivedAt = receivedAt
    }

    public init(_ payload: PlaybackPayload, receivedAt: TimeInterval) {
        self.init(
            position: payload.position,
            duration: payload.duration,
            paused: payload.paused,
            rate: payload.rate ?? 1,
            ended: payload.ended ?? false,
            waiting: payload.waiting ?? false,
            receivedAt: receivedAt
        )
    }

    public var isPlaying: Bool { !paused && !ended }

    /// Estimated playback position at monotonic time `now`.
    public func position(at now: TimeInterval) -> Double {
        guard isPlaying, !waiting else { return position }
        let elapsed = max(0, now - receivedAt)
        let estimate = position + elapsed * rate
        if let duration { return min(estimate, duration) }
        return estimate
    }
}
