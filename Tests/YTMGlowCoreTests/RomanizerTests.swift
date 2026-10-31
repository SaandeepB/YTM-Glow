import Foundation
import Testing
@testable import YTMGlowCore

/// Fixtures are short original phrases, not song lyrics.
@Suite struct RomanizerTests {
    @Test(arguments: [
        // Telugu: long vowels doubled, c → ch, ś → sh, anusvara → n/m.
        ("చల్లని గాలి నది మీద పాట పాడింది", "challani gaali nadi meeda paata paadindi"),
        ("నువ్వు నేను చెప్పిన మాట", "nuvvu nenu cheppina maata"),
        ("రాత్రంతా మనసు నిండా సంగీతం", "raatranta manasu ninda sangeetam"),
        ("వెన్నెల వెలుగులో దీపాలు మెరిశాయి", "vennela velugulo deepaalu merishaayi"),
        ("మనసులో ప్రేమ కృష్ణా", "manasulo prema krishna"),
        // Hindi: silent inherent "a" dropped at word ends and mid-word.
        ("मेरा दिल तेरे लिए", "mera dil tere liye"),
        ("मुझको इतना बताए कोई", "mujhko itna bataye koi"),
        ("नदी पर ठंडी हवा गाना गा रही है", "nadi par thandi hava gaana ga rahi hai"),
        ("मित्र सपना", "mitra sapna"),
        // Tamil: voiced consonants as sung.
        ("நதி மேல் குளிர் காற்று பாடல்", "nadhi mel kulir kaatru paadal"),
        ("தமிழ் தங்கம் சந்தோஷம்", "thamizh thangam santhosham"),
        // Kannada and Malayalam.
        ("ನದಿಯ ಮೇಲೆ ತಂಪಾದ ಗಾಳಿ", "nadiya mele tampaada gaali"),
        ("നദിക്കു മുകളിൽ തണുത്ത കാറ്റ്", "nadikku mukalil tanutta kaattu"),
    ])
    func romanizes(source: String, expected: String) {
        #expect(Romanizer.romanize(source) == expected)
    }

    @Test func leavesEnglishAndOtherScriptsAlone() {
        #expect(Romanizer.romanize("Hey baby, come back!") == "Hey baby, come back!")
        #expect(Romanizer.romanize("Hey నువ్వే (oh)") == "Hey nuvve (oh)")
        #expect(Romanizer.romanize("夜の川") == "夜の川", "only Indian scripts are transliterated")
        #expect(Romanizer.romanize("") == "")
    }
}

@Suite struct RomanizedLyricsTests {
    let lrc = "[00:10.00]చల్లని గాలి నది మీద\n[00:14.00]Hey నువ్వే\n[00:18.00]Oh oh oh"

    @Test func keepsWordsAndTimingOneForOne() throws {
        let native = try #require(Lyrics(lrc: lrc))
        let english = native.romanized()
        #expect(english.transliteratedFrom == .telugu)
        #expect(english.lines.map(\.text) == ["Challani gaali nadi meeda", "Hey nuvve", "Oh oh oh"])
        for (a, b) in zip(native.lines, english.lines) {
            #expect(a.start == b.start && a.end == b.end)
            #expect(a.words.count == b.words.count)
            #expect(zip(a.words, b.words).allSatisfy { $0.start == $1.start && $0.end == $1.end })
        }
        // Timing came from the Telugu aksharas: the long first word got the most time.
        let first = english.lines[0].words
        #expect(first[0].end - first[0].start > first[2].end - first[2].start)
    }

    @Test func englishLyricsAreUntouched() throws {
        let lyrics = try #require(Lyrics(lrc: "[00:01.00]Hang the glass lanterns"))
        #expect(lyrics.romanized() == lyrics)
        #expect(lyrics.romanized().transliteratedFrom == nil)
    }
}

@Suite struct EnglishLettersModeTests {
    struct OneShot: LyricsLookup {
        let result: LyricsLookupResult
        func lookup(_ track: CleanedTrack, duration: Double?, preference: LyricsPreference) async throws -> LyricsLookupResult { result }
    }

    let telugu = "[00:10.00]చల్లని గాలి నది మీద"

    @Test func englishModeNeverShowsIndianScript() async throws {
        let service = LyricsService(lookup: OneShot(result: .synced(lrc: telugu, recordID: 1)), cache: nil)
        let outcome = await service.lyrics(title: "Song", artist: "Singer", album: nil, duration: 200, preference: .init(writing: .english))
        guard case let .synced(lyrics) = outcome else { Issue.record("expected lyrics"); return }
        #expect(lyrics.lines[0].text == "Challani gaali nadi meeda")
        #expect(LyricsScript.dominant(in: lyrics.lines.map(\.text).joined()) == .latin)
    }

    @Test func originalModeKeepsTheScript() async throws {
        let service = LyricsService(lookup: OneShot(result: .synced(lrc: telugu, recordID: 1)), cache: nil)
        let outcome = await service.lyrics(title: "Song", artist: "Singer", album: nil, duration: 200, preference: .init(writing: .original))
        guard case let .synced(lyrics) = outcome else { Issue.record("expected lyrics"); return }
        #expect(lyrics.lines[0].text == "చల్లని గాలి నది మీద")
        #expect(lyrics.transliteratedFrom == nil)
    }

    @Test func defaultIsEnglishLetters() {
        #expect(LyricsPreference.default.writing == .english)
        #expect(LyricsPreference.default.preferredScript == .latin)
    }
}

@Suite struct ListenerLanguageTests {
    let telugu = "[00:10.00]చల్లని గాలి నది మీద"
    let tamil = "[00:10.00]நதி மேல் குளிர் காற்று"
    let romanized = "[00:10.00]Challani gaali nadi meeda"

    func record(_ id: Int, _ lrc: String) -> String {
        #"{"id":\#(id),"trackName":"Srivalli","artistName":"Sid Sriram","albumName":"Pushpa","duration":221,"instrumental":false,"plainLyrics":"x","syncedLyrics":"\#(lrc)"}"#
    }
    let track = CleanedTrack(title: "Srivalli", artist: "Sid Sriram", primaryArtist: "Sid Sriram", album: "Pushpa - The Rise")

    @Test func yourLanguagePicksYourVersionWhenMetadataDoesNotSay() async throws {
        // English letters, listener's language Telugu, no language in the metadata:
        // the Tamil version loses to the Telugu one (which is then transliterated).
        let http = FakeHTTP([
            "/api/get": [(200, record(1, tamil))],
            "/api/search": [(200, "[" + record(2, tamil) + "," + record(3, telugu) + "]")],
        ])
        let result = try await LRCLibClient(http: http, sleep: { _ in }).lookup(track, duration: 221, preference: .init(writing: .english, language: .telugu))
        #expect(result == .synced(lrc: telugu, recordID: 3))
    }

    @Test func englishModePrefersAHumanRomanization() async throws {
        let http = FakeHTTP([
            "/api/get": [(200, record(1, telugu))],
            "/api/search": [(200, "[" + record(2, romanized) + "]")],
        ])
        let result = try await LRCLibClient(http: http, sleep: { _ in }).lookup(track, duration: 221, preference: .init(writing: .english, language: .telugu))
        #expect(result == .synced(lrc: romanized, recordID: 2))
    }

    @Test func englishSongsStayOneRequest() async throws {
        let english = CleanedTrack(title: "Glass Lanterns", artist: "The Paper Moths", primaryArtist: "The Paper Moths", album: nil)
        let http = FakeHTTP(["/api/get": [(200, #"{"id":9,"trackName":"Glass Lanterns","artistName":"The Paper Moths","duration":200,"syncedLyrics":"[00:01.00]Hello there"}"#)]])
        let result = try await LRCLibClient(http: http, sleep: { _ in }).lookup(english, duration: 200, preference: .init(writing: .english, language: .telugu))
        #expect(result == .synced(lrc: "[00:01.00]Hello there", recordID: 9))
        #expect(http.requests.count == 1)
    }
}
