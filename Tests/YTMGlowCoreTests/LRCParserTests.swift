import Testing
@testable import YTMGlowCore

@Suite struct LRCParserTests {
    @Test func parsesTimestampsInAllCommonForms() {
        #expect(LRCParser.parseTimestamp("00:10.00") == 10)
        #expect(LRCParser.parseTimestamp("01:02.5") == 62.5)
        #expect(LRCParser.parseTimestamp("01:02.05") == 62.05)
        #expect(LRCParser.parseTimestamp("01:02.123") == 62.123)
        #expect(LRCParser.parseTimestamp("1:02") == 62)
        #expect(LRCParser.parseTimestamp("01:02:50") == 62.5)
        #expect(LRCParser.parseTimestamp("120:00.00") == 7200)
        #expect(LRCParser.parseTimestamp("00:60.00") == nil)
        #expect(LRCParser.parseTimestamp("ar:Someone") == nil)
        #expect(LRCParser.parseTimestamp("aa:bb") == nil)
        #expect(LRCParser.parseTimestamp("") == nil)
    }

    @Test func parsesLinesMetadataAndSortsByTime() {
        let doc = LRCParser.parse("""
        [ti:Song]
        [ar:Artist]
        [00:20.00]Second
        [00:10.00]First
        not a lyric line
        [00:30.00]
        """)
        #expect(doc.metadata["ti"] == "Song")
        #expect(doc.metadata["ar"] == "Artist")
        #expect(doc.lines.map(\.text) == ["First", "Second", ""])
        #expect(doc.lines.map(\.time) == [10, 20, 30])
    }

    @Test func expandsRepeatedTimestamps() {
        let doc = LRCParser.parse("[00:10.00][01:10.00]Chorus line\n[00:40.00]Verse")
        #expect(doc.lines.map(\.time) == [10, 40, 70])
        #expect(doc.lines.map(\.text) == ["Chorus line", "Verse", "Chorus line"])
    }

    @Test func appliesOffsetTag() {
        // Positive offset makes lyrics appear earlier.
        let doc = LRCParser.parse("[offset:+500]\n[00:10.00]A\n[00:00.20]B")
        #expect(doc.lines.map(\.time) == [0, 9.5])
        let negative = LRCParser.parse("[offset:-250]\n[00:10.00]A")
        #expect(negative.lines.first?.time == 10.25)
    }

    @Test func handlesWindowsLineEndingsAndWhitespace() {
        let doc = LRCParser.parse("[00:01.00]  Hello there  \r\n[00:02.00]Bye\r\n")
        #expect(doc.lines.map(\.text) == ["Hello there", "Bye"])
    }

    @Test func parsesEnhancedWordTimestamps() {
        let doc = LRCParser.parse("[00:10.00]<00:10.00>Hello <00:10.60>bright <00:11.40>world")
        let line = try! #require(doc.lines.first)
        #expect(line.text == "Hello bright world")
        #expect(line.words?.map(\.text) == ["Hello", "bright", "world"])
        #expect(line.words?.map(\.time) == [10, 10.6, 11.4])

        let lyrics = try! #require(Lyrics(lrc: "[00:10.00]<00:10.00>Hello <00:10.60>bright <00:11.40>world\n[00:14.00]Next"))
        #expect(lyrics.wordTimingEstimated == false)
        #expect(lyrics.lines[0].words.map(\.start) == [10, 10.6, 11.4])
    }

    @Test func returnsNilLyricsWithoutTimedLines() {
        #expect(Lyrics(lrc: "Just plain text\nNo timestamps") == nil)
        #expect(Lyrics(lrc: "") == nil)
        #expect(Lyrics(lrc: "[00:01.00]\n[00:02.00]") == nil)
    }
}
