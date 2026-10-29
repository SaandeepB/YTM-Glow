import Testing
@testable import YTMGlowCore

@Suite struct WordTimingTests {
    @Test func countsSyllables() {
        #expect(SyllableCounter.count("a") == 1)
        #expect(SyllableCounter.count("light") == 1)
        #expect(SyllableCounter.count("river") == 2)
        #expect(SyllableCounter.count("lanterns") == 2)
        #expect(SyllableCounter.count("love") == 1, "silent e")
        #expect(SyllableCounter.count("little") == 2, "-le keeps its syllable")
        #expect(SyllableCounter.count("beautiful") == 3)
        #expect(SyllableCounter.count("corazón") == 3)
        #expect(SyllableCounter.count("любовь") == 2)
        #expect(SyllableCounter.count("사랑해") == 3, "one per Hangul block")
        #expect(SyllableCounter.count("君の名は") == 4, "one per kana/kanji")
        #expect(SyllableCounter.count("—") == 0.5)
        #expect(SyllableCounter.count("1999") == 4)
    }

    @Test func tokenizesSpacedAndUnspacedScripts() {
        #expect(WordTimingEstimator.tokenize("Hang the  lanterns").map(\.text) == ["Hang", "the", "lanterns"])
        let japanese = WordTimingEstimator.tokenize("君の名は。")
        #expect(japanese.map(\.text) == ["君", "の", "名", "は。"])
        #expect(japanese.map(\.spaceAfter) == [false, false, false, false])
        let mixed = WordTimingEstimator.tokenize("Hello世界 again")
        #expect(mixed.map(\.text) == ["Hello", "世", "界", "again"])
        #expect(mixed.map(\.spaceAfter) == [false, false, true, false])
    }

    @Test func wordsFillTheLineInOrderWeightedBySyllables() {
        let words = WordTimingEstimator.estimateWords(text: "Hang the glass lanterns over the river", start: 10, available: 4.5)
        #expect(words.count == 7)
        #expect(words.first?.start == 10)
        for (a, b) in zip(words, words.dropFirst()) {
            #expect(a.end == b.start, "contiguous")
            #expect(a.start < b.start, "increasing")
        }
        let end = words.last!.end
        #expect(end <= 10 + 4.5 * WordTimingEstimator.fillRatio + 1e-9, "leaves a little room before the next line")
        // "lanterns" (2 syllables) lasts longer than "the" (1).
        let the = words[1], lanterns = words[3]
        #expect(lanterns.end - lanterns.start > the.end - the.start)
    }

    @Test func doesNotStretchAcrossLongGaps() {
        // Four words then 30 s of instrumental: sung at a natural pace, not over 30 s.
        let words = WordTimingEstimator.estimateWords(text: "Carry the light home", start: 0, available: 30)
        #expect(words.last!.end < 4)
        let lines = WordTimingEstimator.build([LRCLine(time: 0, text: "Carry the light home"), LRCLine(time: 30, text: "Next")], songDuration: 60)
        #expect(lines[0].end < 8, "line clears during the instrumental")
        #expect(lines[0].end >= lines[0].words.last!.end)
    }

    @Test func compressesFastLines() {
        let words = WordTimingEstimator.estimateWords(text: "one two three four five six seven eight nine ten", start: 5, available: 2)
        #expect(words.last!.end <= 7)
        #expect(words.allSatisfy { $0.end > $0.start })
    }

    @Test func emptyLinesEndThePreviousLine() {
        let lines = WordTimingEstimator.build([
            LRCLine(time: 10, text: "Hold the light till morning"),
            LRCLine(time: 13, text: ""),
            LRCLine(time: 20, text: "After the break"),
        ], songDuration: nil)
        #expect(lines.count == 2)
        #expect(lines[0].end <= 13)
        #expect(lines[1].start == 20)
    }

    @Test func lastLineUsesSongDurationOrDefault() {
        let withDuration = WordTimingEstimator.build([LRCLine(time: 100, text: "The very last words")], songDuration: 103)
        #expect(withDuration[0].end <= 103)
        let without = WordTimingEstimator.build([LRCLine(time: 100, text: "The very last words")], songDuration: nil)
        #expect(without[0].end > 100 && without[0].end <= 106)
    }

    @Test func locateFindsLineWordAndProgress() throws {
        let lyrics = try #require(Lyrics(lrc: "[00:10.00]Hang the glass lanterns\n[00:14.00]Every one is a wish\n[00:30.00]Later"))
        #expect(lyrics.locate(5) == LyricPosition(lineIndex: nil, wordIndex: nil, wordProgress: 0, nextLineIndex: 0))
        let start = lyrics.locate(10)
        #expect(start.lineIndex == 0 && start.wordIndex == 0 && start.wordProgress == 0)
        let last = lyrics.locate(13.9)
        #expect(last.lineIndex == 0 && last.wordIndex == 3)
        #expect(lyrics.locate(14).lineIndex == 1)
        // After line 2 is sung, the long gap before "Later" has no current line.
        let gap = lyrics.locate(25)
        #expect(gap.lineIndex == nil && gap.nextLineIndex == 2)
        #expect(lyrics.locate(31).lineIndex == 2)
        #expect(lyrics.locate(31).nextLineIndex == nil)
    }

    @Test func nextBoundaryWalksEveryWord() throws {
        let lyrics = try #require(Lyrics(lrc: "[00:10.00]Hang the glass lanterns\n[00:14.00]Next line"))
        var t = 0.0
        var boundaries: [Double] = []
        while let next = lyrics.nextBoundary(after: t), boundaries.count < 50 {
            boundaries.append(next)
            t = next
        }
        let starts = lyrics.lines.flatMap { $0.words.map(\.start) }
        for start in starts { #expect(boundaries.contains { abs($0 - start) < 1e-9 }) }
        #expect(boundaries == boundaries.sorted())
    }
}
