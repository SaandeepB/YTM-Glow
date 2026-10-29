import Foundation

/// A snapshot of the music's energy for visualizers.
public struct BeatState: Equatable, Sendable {
    /// 0…1 beat pulse.
    public var pulse: Double
    /// 0…1 band levels, auto-gained so quiet and loud songs both fill the range.
    public var bass: Double
    public var mid: Double
    public var high: Double
    /// False when no levels have arrived recently (tap waiting for a click,
    /// failed, or levels not requested): values are a gentle breathing motion.
    public var live: Bool

    public static let silent = BeatState(pulse: 0, bass: 0, mid: 0, high: 0, live: false)
}

/// Turns the ~30 Hz levels stream into smoothed, normalized values that any
/// number of views can sample whenever they redraw. Nothing is published, so
/// feeding it costs nothing when no visualizer is on screen.
@MainActor
public final class BeatMeter {
    /// Levels older than this count as "not live".
    public static let staleAfter: TimeInterval = 0.6
    /// Breathing tempo when there are no levels.
    public nonisolated static let breathingHz = 0.45

    private let now: MonotonicClock
    private var envelope = BeatEnvelope()
    private var bands = [0.0, 0.0, 0.0]
    private var peaks = [0.2, 0.2, 0.2]
    private var lastFeed: TimeInterval?

    public init(now: @escaping MonotonicClock = systemMonotonicClock) {
        self.now = now
    }

    public func feed(_ levels: LevelsMessage) {
        let time = now()
        let dt = min(0.25, max(0.001, lastFeed.map { time - $0 } ?? (1.0 / 30)))
        lastFeed = time
        envelope.update(bass: levels.bass, mid: levels.mid, high: levels.high, dt: dt)

        let inputs = [levels.bass, levels.mid, levels.high].map { $0.isFinite ? min(1, max(0, $0)) : 0 }
        for index in 0..<3 {
            // Slowly decaying peak per band = automatic gain.
            peaks[index] = max(inputs[index], peaks[index] * exp(-dt / 5), 0.12)
            let target = inputs[index] / peaks[index]
            // Fast attack, slower release, like a VU meter.
            let tau = target > bands[index] ? 0.04 : 0.22
            bands[index] += (target - bands[index]) * (1 - exp(-dt / tau))
        }
    }

    /// The state to draw at this moment.
    public func current() -> BeatState {
        let time = now()
        guard let lastFeed, time - lastFeed < Self.staleAfter else {
            return Self.breathing(at: time)
        }
        return BeatState(pulse: envelope.value, bass: bands[0], mid: bands[1], high: bands[2], live: true)
    }

    /// A slow, calm pulse used when the music's levels aren't available.
    public nonisolated static func breathing(at time: TimeInterval) -> BeatState {
        let wave = 0.5 + 0.5 * sin(2 * .pi * breathingHz * time)
        return BeatState(pulse: 0.18 + 0.22 * wave, bass: 0.3 + 0.25 * wave, mid: 0.22 + 0.18 * wave, high: 0.15 + 0.12 * wave, live: false)
    }
}

/// Bar heights for the mirrored equalizer shown when a song has no lyrics:
/// bass in the middle, highs toward the edges, a little per-bar motion so it
/// never looks frozen, and an extra lift on each beat.
public enum VisualizerBars {
    public static func heights(count: Int, state: BeatState, time: TimeInterval) -> [Double] {
        guard count > 0 else { return [] }
        let center = Double(count - 1) / 2
        return (0..<count).map { index in
            // 0 at the center bar, 1 at the outermost.
            let distance = abs(Double(index) - center)
            let x = center > 0 ? distance / center : 0
            let bassWeight = max(0, 1 - x * 1.5)
            let midWeight = max(0, 1 - abs(x - 0.5) * 2.2)
            let highWeight = max(0, (x - 0.35) * 1.6)
            let total = bassWeight + midWeight + highWeight
            let level = total > 0 ? (state.bass * bassWeight + state.mid * midWeight + state.high * highWeight) / total : 0
            // Taller in the middle, tapering toward the edges, like a mirrored spectrum.
            let shape = 1 - 0.5 * pow(x, 1.4)
            let lift = 0.32 * state.pulse * (1 - 0.5 * x)
            // Mirror-symmetric shimmer (phase depends only on distance from the center).
            let shimmer = 0.12 * sin(time * (6.3 + 2.7 * x) + x * 11) * (0.4 + level)
                + 0.05 * sin(time * 13.7 + distance * 2.1)
            return min(1, max(0.06, (0.1 + 0.55 * level + lift) * shape + shimmer))
        }
    }
}

extension PlayerEngine.LyricsStatus {
    /// The lookup finished and there are no synced lyrics to show.
    public var isUnavailable: Bool {
        switch self {
        case .notFound, .plainOnly, .instrumental, .failed: return true
        case .idle, .loading, .synced: return false
        }
    }
}
