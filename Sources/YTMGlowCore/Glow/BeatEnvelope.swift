import Foundation

/// Turns ~30 Hz bass/mid/high levels into a 0…1 pulse for the glow.
///
/// Combines how far the current energy jumps above its recent average (beats)
/// with the overall loudness, normalized by a slowly decaying peak so quiet
/// and loud songs both use the full range. Fast attack, slower release.
public struct BeatEnvelope: Sendable {
    public var attackTime: Double = 0.03
    public var releaseTime: Double = 0.28
    /// Time constant of the running average that beats are measured against.
    public var averageTime: Double = 1.2
    /// How quickly the normalization peak forgets loud passages.
    public var peakDecayTime: Double = 6

    public private(set) var value: Double = 0
    private var average: Double = 0
    private var peak: Double = 0.05
    private var primed = false

    public init() {}

    public mutating func reset() {
        value = 0
        average = 0
        peak = 0.05
        primed = false
    }

    /// Feeds one level sample taken `dt` seconds after the previous one.
    @discardableResult
    public mutating func update(bass: Double, mid: Double, high: Double, dt: Double) -> Double {
        let dt = min(max(dt, 0.001), 0.25)
        let energy = 0.65 * clamp(bass) + 0.25 * clamp(mid) + 0.10 * clamp(high)

        if !primed {
            average = energy
            primed = true
        }
        average += (energy - average) * (1 - exp(-dt / averageTime))
        peak = max(energy, peak * exp(-dt / peakDecayTime), 0.05)

        let loudness = energy / peak
        let onset = max(0, energy - average) / max(0.02, peak - average)
        let target = clamp(0.55 * min(1, onset * 1.4) + 0.45 * loudness * loudness)

        let time = target > value ? attackTime : releaseTime
        value += (target - value) * (1 - exp(-dt / time))
        return value
    }

    /// Lets the pulse fall back toward zero when no levels arrive.
    @discardableResult
    public mutating func decay(dt: Double) -> Double {
        value *= exp(-max(0, dt) / releaseTime)
        return value
    }

    private func clamp(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 0 }
}
