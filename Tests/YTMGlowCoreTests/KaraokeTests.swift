import Foundation
import Testing
@testable import YTMGlowCore

@Suite struct KaraokeTimingTests {
    let lyrics = Lyrics(lrc: """
    [00:10.00]Hang the glass lanterns
    [00:14.00]Every one is a wish
    [00:30.00]After the long break
    """)!

    @Test func wordFillsSweepThroughTheLine() throws {
        let line = lyrics.lines[0]
        #expect(lyrics.wordFills(lineIndex: 0, at: 9) == [0, 0, 0, 0])
        #expect(lyrics.wordFills(lineIndex: 0, at: 10) == [0, 0, 0, 0], "nothing is sung at the exact start")

        let midFirst = line.words[0].start + (line.words[0].end - line.words[0].start) / 2
        let fills = lyrics.wordFills(lineIndex: 0, at: midFirst)
        #expect(abs(fills[0] - 0.5) < 1e-9)
        #expect(fills.dropFirst().allSatisfy { $0 == 0 })

        let inThird = line.words[2].start + 0.01
        let later = lyrics.wordFills(lineIndex: 0, at: inThird)
        #expect(later[0] == 1 && later[1] == 1)
        #expect(later[2] > 0 && later[2] < 1)
        #expect(later[3] == 0)

        #expect(lyrics.wordFills(lineIndex: 0, at: 60) == [1, 1, 1, 1])
        #expect(lyrics.wordFills(lineIndex: 9, at: 12) == [])
    }

    @Test func fillsNeverDecreaseOverTime() {
        var previous = lyrics.wordFills(lineIndex: 1, at: 13.9)
        for step in 0..<200 {
            let fills = lyrics.wordFills(lineIndex: 1, at: 14 + Double(step) * 0.02)
            #expect(zip(previous, fills).allSatisfy { $0 <= $1 + 1e-12 })
            #expect(fills.allSatisfy { $0 >= 0 && $0 <= 1 })
            previous = fills
        }
    }

    @Test func zeroLengthWordsAreFullOnceStarted() {
        let line = LyricLine(text: "a b", start: 0, end: 2, words: [
            LyricWord(text: "a", start: 1, end: 1),
            LyricWord(text: "b", start: 1, end: 2),
        ])
        #expect(line.wordFills(at: 1.5) == [1, 0.5])
    }

    @Test func countdownCoversOnlyLongBreaks() throws {
        // Before the first line: a break from 0 to 10.
        let intro = try #require(lyrics.gap(at: 4))
        #expect(intro.start == 0 && intro.end == 10 && intro.nextLineIndex == 0)
        #expect(abs(intro.progress(at: 5) - 0.5) < 1e-9)

        // Between line 2 (ends early) and the line at 30.
        let middle = try #require(lyrics.gap(at: 25))
        #expect(middle.end == 30 && middle.nextLineIndex == 2)
        #expect(middle.start == lyrics.lines[1].end)
        #expect(middle.progress(at: middle.start - 1) == 0)
        #expect(middle.progress(at: 31) == 1)

        // While a line is being sung, or for short breaks, there's no countdown.
        #expect(lyrics.gap(at: 11) == nil)
        #expect(lyrics.gap(at: 4, minimum: 20) == nil)
        #expect(lyrics.gap(at: 99) == nil, "after the last line nothing is coming")
    }
}

@Suite struct StageDisplayPickerTests {
    let main = DisplayInfo(id: 1, name: "Built-in Retina Display", isMain: true)
    let studio = DisplayInfo(id: 7, name: "Studio Display", isMain: false)
    let tv = DisplayInfo(id: 9, name: "Living Room TV", isMain: false)

    @Test func automaticPicksTheFirstNonMainDisplay() {
        #expect(StageDisplayPicker.pick([main, studio, tv], preferredID: nil) == studio)
        #expect(StageDisplayPicker.pick([main, studio, tv], preferredID: 0) == studio)
    }

    @Test func honorsAConnectedPreference() {
        #expect(StageDisplayPicker.pick([main, studio, tv], preferredID: 9) == tv)
        #expect(StageDisplayPicker.pick([main, studio], preferredID: 1) == main, "the main display only when asked for")
    }

    @Test func fallsBackWhenThePreferredDisplayIsUnplugged() {
        #expect(StageDisplayPicker.pick([main, studio], preferredID: 9) == studio)
    }

    @Test func neverCoversTheOnlyDisplayUninvited() {
        #expect(StageDisplayPicker.pick([main], preferredID: nil) == nil)
        #expect(StageDisplayPicker.pick([main], preferredID: 9) == nil)
        #expect(StageDisplayPicker.pick([], preferredID: nil) == nil)
    }
}

@MainActor
@Suite struct KaraokeEngineTests {
    @Test func presenterReportsLyricTimeWithOffset() async throws {
        let clock = TestClock()
        let lrc = "[00:10.00]Hang the glass lanterns\n[00:14.00]Every one"
        let engine = PlayerEngine(lyrics: FakeLyricsProvider(lrcByTitle: ["Song": lrc]),
                                  artwork: FakeArtworkProvider(palette: Palette(primary: SRGBColor(r: 1, g: 0, b: 0), secondary: SRGBColor(r: 0, g: 0, b: 1), isMonochrome: false)),
                                  now: clock.closure)
        engine.lyricsDebounce = 0
        let presenter = LyricsPresenter(engine: engine)
        #expect(presenter.lyricTime() == nil)

        let client = BridgeClientID(raw: 1)
        engine.handle(.message(client, .state(StateMessage(source: "tab", track: TrackPayload(title: "Song", artist: "A"),
                                                           playback: PlaybackPayload(position: 12, duration: 100, paused: false)))))
        #expect(await waitUntil { engine.lyricsStatus.lyrics != nil })
        #expect(presenter.lyricTime() == 12)
        clock.advance(1.5)
        #expect(presenter.lyricTime() == 13.5)
        presenter.offset = 0.5
        #expect(presenter.lyricTime() == 13)
    }

    @Test func levelsReachEveryObserver() {
        let engine = PlayerEngine(lyrics: FakeLyricsProvider(lrcByTitle: [:]),
                                  artwork: FakeArtworkProvider(palette: Palette(primary: SRGBColor(r: 1, g: 0, b: 0), secondary: SRGBColor(r: 0, g: 0, b: 1), isMonochrome: false)))
        engine.lyricsDebounce = 0
        var glow: [Double] = []
        var stage: [Double] = []
        engine.onLevels = { glow.append($0.bass) }
        engine.observeLevels { stage.append($0.bass) }
        let client = BridgeClientID(raw: 1)
        engine.handle(.message(client, .state(StateMessage(source: "tab", track: TrackPayload(title: "Song", artist: "A"),
                                                           playback: PlaybackPayload(position: 1, duration: 100, paused: false)))))
        engine.handle(.message(client, .levels(LevelsMessage(source: "tab", bass: 0.7, mid: 0.2, high: 0.1))))
        #expect(glow == [0.7])
        #expect(stage == [0.7])
    }
}
