import Foundation
import Testing
@testable import YTMGlowCore

@Suite struct PlaybackClockTests {
    @Test func extrapolatesOnlyWhilePlaying() {
        let playing = PlaybackClock(position: 10, duration: 200, paused: false, rate: 1, receivedAt: 100)
        #expect(playing.position(at: 102.5) == 12.5)
        #expect(playing.position(at: 99) == 10, "never runs backwards")
        #expect(playing.position(at: 1000) == 200, "clamped to duration")
        let fast = PlaybackClock(position: 10, duration: nil, paused: false, rate: 2, receivedAt: 100)
        #expect(fast.position(at: 101) == 12)
        let paused = PlaybackClock(position: 10, duration: 200, paused: true, receivedAt: 100)
        #expect(paused.position(at: 150) == 10)
        let buffering = PlaybackClock(position: 10, duration: 200, paused: false, waiting: true, receivedAt: 100)
        #expect(buffering.position(at: 150) == 10)
        #expect(buffering.isPlaying)
        let ended = PlaybackClock(position: 200, duration: 200, paused: false, ended: true, receivedAt: 100)
        #expect(!ended.isPlaying)
    }

    @Test func sanitizesBadNumbers() {
        let clock = PlaybackClock(position: .nan, duration: .infinity, paused: false, rate: 0, receivedAt: 0)
        #expect(clock.position == 0)
        #expect(clock.duration == nil)
        #expect(clock.rate == 1)
    }
}

@Suite struct BeatEnvelopeTests {
    @Test func pulsesOnBeatsAndRestsBetween() {
        var envelope = BeatEnvelope()
        var onBeat: [Double] = []
        var offBeat: [Double] = []
        // 120 BPM kick at 30 Hz for 6 s.
        for frame in 0..<180 {
            let t = Double(frame) / 30
            let phase = t.truncatingRemainder(dividingBy: 0.5)
            let bass = phase < 0.07 ? 0.9 : 0.25
            let value = envelope.update(bass: bass, mid: 0.2, high: 0.1, dt: 1.0 / 30)
            guard t > 2 else { continue } // let it settle
            if phase < 0.07 { onBeat.append(value) } else if phase > 0.3 { offBeat.append(value) }
        }
        let beatAverage = onBeat.reduce(0, +) / Double(onBeat.count)
        let restAverage = offBeat.reduce(0, +) / Double(offBeat.count)
        #expect(beatAverage > restAverage + 0.25, "beats \(beatAverage) vs rests \(restAverage)")
        #expect((onBeat + offBeat).allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func quietSongsStillUseTheRange() {
        var envelope = BeatEnvelope()
        var peak = 0.0
        for frame in 0..<180 {
            let phase = (Double(frame) / 30).truncatingRemainder(dividingBy: 0.5)
            peak = max(peak, envelope.update(bass: phase < 0.07 ? 0.18 : 0.05, mid: 0.02, high: 0.01, dt: 1.0 / 30))
        }
        #expect(peak > 0.5, "auto-gain lifts quiet material (\(peak))")
    }

    @Test func silenceAndDecayFallToZero() {
        var envelope = BeatEnvelope()
        // Constant loud input is not a beat: it settles on the loudness term alone.
        for _ in 0..<30 { envelope.update(bass: 1, mid: 1, high: 1, dt: 1.0 / 30) }
        #expect(envelope.value > 0.4 && envelope.value < 0.5)
        for _ in 0..<60 { envelope.decay(dt: 1.0 / 30) }
        #expect(envelope.value < 0.01)
        envelope.reset()
        for _ in 0..<60 { envelope.update(bass: 0, mid: 0, high: 0, dt: 1.0 / 30) }
        #expect(envelope.value < 0.01)
    }

    @Test func ignoresGarbageInput() {
        var envelope = BeatEnvelope()
        let value = envelope.update(bass: .nan, mid: -5, high: 10, dt: -1)
        #expect(value.isFinite && value >= 0 && value <= 1)
    }
}

@Suite struct PolicyTests {
    @Test(arguments: [
        (nil, true),
        ("", true),
        ("chrome-extension://abcdefghijklmnop", true),
        ("moz-extension://1234-5678", true),
        ("https://music.youtube.com", false),
        ("http://localhost:3000", false),
        ("null", false),
        ("file://", false),
        ("chrome-extension://", false),
    ] as [(String?, Bool)])
    func originPolicy(origin: String?, allowed: Bool) {
        #expect(OriginPolicy.isAllowed(origin) == allowed)
    }

    @Test(arguments: [
        ("https://lh3.googleusercontent.com/abc=w544-h544", true),
        ("https://i.ytimg.com/vi/x/hqdefault.jpg", true),
        ("https://yt3.ggpht.com/a/b", true),
        ("http://lh3.googleusercontent.com/abc", false),
        ("https://googleusercontent.com.evil.example/x", false),
        ("https://evilgoogleusercontent.com/x", false),
        ("https://user:pw@lh3.googleusercontent.com/x", false),
        ("https://lh3.googleusercontent.com:8443/x", false),
        ("https://127.0.0.1/x", false),
    ])
    func artworkPolicy(url: String, allowed: Bool) {
        #expect(ArtworkPolicy.isAllowed(URL(string: url)!) == allowed)
    }

    @Test func artworkPickPrefersSmallestUsableSize() {
        let images = [
            ArtworkImage(src: "https://lh3.googleusercontent.com/a=w60", sizes: "60x60"),
            ArtworkImage(src: "https://lh3.googleusercontent.com/a=w226", sizes: "226x226"),
            ArtworkImage(src: "https://lh3.googleusercontent.com/a=w544", sizes: "544x544"),
            ArtworkImage(src: "https://evil.example/huge.jpg", sizes: "120x120"),
        ]
        #expect(ArtworkPolicy.pick(images, preferredEdge: 120)?.absoluteString == "https://lh3.googleusercontent.com/a=w226")
        #expect(ArtworkPolicy.pick(images, preferredEdge: 1000)?.absoluteString == "https://lh3.googleusercontent.com/a=w544")
        #expect(ArtworkPolicy.pick([ArtworkImage(src: "https://evil.example/a.jpg")], preferredEdge: 120) == nil)
        #expect(ArtworkPolicy.pick([], preferredEdge: 120) == nil)
    }
}
