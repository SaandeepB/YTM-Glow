import Foundation
import Testing
@testable import YTMGlowCore

final class StepClock: @unchecked Sendable {
    var time: TimeInterval = 500
}

@MainActor
@Suite struct BeatMeterTests {
    @Test func breathesWhenNoLevelsArrive() {
        let clock = StepClock()
        let meter = BeatMeter(now: { clock.time })
        let first = meter.current()
        #expect(!first.live)
        var pulses: [Double] = []
        for _ in 0..<40 {
            clock.time += 0.1
            let state = meter.current()
            #expect(!state.live)
            #expect(state.pulse >= 0.18 - 1e-9 && state.pulse <= 0.4 + 1e-9, "gentle, never flat or wild")
            pulses.append(state.pulse)
        }
        #expect((pulses.max() ?? 0) - (pulses.min() ?? 0) > 0.15, "it actually moves")
    }

    @Test func liveLevelsDriveThePulseAndBands() {
        let clock = StepClock()
        let meter = BeatMeter(now: { clock.time })
        var onBeat: [Double] = []
        var offBeat: [Double] = []
        for frame in 0..<180 {
            clock.time += 1.0 / 30
            let kick = frame % 15 < 2
            meter.feed(LevelsMessage(source: "t", bass: kick ? 0.9 : 0.25, mid: 0.3, high: 0.15))
            let state = meter.current()
            #expect(state.live)
            for value in [state.pulse, state.bass, state.mid, state.high] { #expect(value >= 0 && value <= 1.0001) }
            guard frame > 60 else { continue }
            (kick ? { onBeat.append(state.bass) } : { if frame % 15 > 8 { offBeat.append(state.bass) } })()
        }
        let beatAverage = onBeat.reduce(0, +) / Double(onBeat.count)
        let restAverage = offBeat.reduce(0, +) / Double(offBeat.count)
        #expect(beatAverage > restAverage + 0.3, "bass jumps on the kick (\(beatAverage) vs \(restAverage))")
    }

    @Test func quietMusicIsAutoGained() {
        let clock = StepClock()
        let meter = BeatMeter(now: { clock.time })
        var peak = 0.0
        for frame in 0..<180 {
            clock.time += 1.0 / 30
            meter.feed(LevelsMessage(source: "t", bass: frame % 15 < 2 ? 0.2 : 0.06, mid: 0.05, high: 0.03))
            peak = max(peak, meter.current().bass)
        }
        #expect(peak > 0.7, "quiet songs still move the bars (\(peak))")
    }

    @Test func goesBackToBreathingWhenLevelsStop() {
        let clock = StepClock()
        let meter = BeatMeter(now: { clock.time })
        meter.feed(LevelsMessage(source: "t", bass: 0.8, mid: 0.4, high: 0.2))
        #expect(meter.current().live)
        clock.time += BeatMeter.staleAfter + 0.01
        #expect(!meter.current().live)
    }

    @Test func ignoresGarbage() {
        let clock = StepClock()
        let meter = BeatMeter(now: { clock.time })
        clock.time += 0.03
        meter.feed(LevelsMessage(source: "t", bass: .nan, mid: -3, high: 9))
        let state = meter.current()
        for value in [state.pulse, state.bass, state.mid, state.high] { #expect(value.isFinite && value >= 0 && value <= 1) }
    }
}

@Suite struct VisualizerBarsTests {
    let loud = BeatState(pulse: 1, bass: 1, mid: 0.6, high: 0.4, live: true)
    let quiet = BeatState(pulse: 0, bass: 0.05, mid: 0.05, high: 0.05, live: true)

    @Test func boundedAndMirrored() {
        for time in stride(from: 0.0, through: 3.0, by: 0.37) {
            for state in [loud, quiet, BeatState.silent, BeatMeter.breathing(at: time)] {
                let bars = VisualizerBars.heights(count: 25, state: state, time: time)
                #expect(bars.count == 25)
                #expect(bars.allSatisfy { $0 >= 0.06 && $0 <= 1 })
                for index in 0..<12 { #expect(abs(bars[index] - bars[24 - index]) < 1e-9) }
            }
        }
    }

    @Test func loudBassMakesATallCenterThatTapers() {
        let bars = VisualizerBars.heights(count: 25, state: loud, time: 0)
        #expect(bars[12] > 0.85, "center bar \(bars[12])")
        #expect(bars[0] < bars[12] - 0.3, "edges taper (\(bars[0]) vs \(bars[12]))")
    }

    @Test func quietMusicStaysLow() {
        let bars = VisualizerBars.heights(count: 25, state: quiet, time: 1.2)
        #expect(bars.allSatisfy { $0 < 0.3 })
    }

    @Test func barsMoveOverTimeEvenWithSteadyLevels() {
        let steady = BeatState(pulse: 0.3, bass: 0.5, mid: 0.4, high: 0.3, live: true)
        let a = VisualizerBars.heights(count: 21, state: steady, time: 10)
        let b = VisualizerBars.heights(count: 21, state: steady, time: 10.15)
        #expect(zip(a, b).contains { abs($0 - $1) > 0.02 })
        #expect(VisualizerBars.heights(count: 0, state: steady, time: 0) == [])
        #expect(VisualizerBars.heights(count: 1, state: steady, time: 0).count == 1)
    }

    @Test func unavailableLyricsStatuses() {
        typealias Status = PlayerEngine.LyricsStatus
        #expect(Status.notFound.isUnavailable)
        #expect(Status.plainOnly.isUnavailable)
        #expect(Status.instrumental.isUnavailable)
        #expect(Status.failed("offline").isUnavailable)
        #expect(!Status.loading.isUnavailable, "no visualizer flash while still looking")
        #expect(!Status.idle.isUnavailable)
        #expect(!Status.synced(Lyrics(lrc: "[00:01.00]hi")!).isUnavailable)
    }
}
