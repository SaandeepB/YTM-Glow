import Foundation
import Testing
@testable import YTMGlowCore

/// Lyrics fixtures here are short original phrases, not song lyrics.
@Suite struct LyricsScriptTests {
    @Test func detectsTheDominantScript() {
        #expect(LyricsScript.dominant(in: "[00:01.00]చల్లని గాలి నది మీద") == .telugu)
        #expect(LyricsScript.dominant(in: "[00:01.00]நதி மேல் குளிர் காற்று") == .tamil)
        #expect(LyricsScript.dominant(in: "[00:01.00]नदी पर ठंडी हवा") == .devanagari)
        #expect(LyricsScript.dominant(in: "[00:01.00]ನದಿಯ ಮೇಲೆ ತಂಪಾದ ಗಾಳಿ") == .kannada)
        #expect(LyricsScript.dominant(in: "[00:01.00]നദിക്കു മുകളിൽ കാറ്റ്") == .malayalam)
        #expect(LyricsScript.dominant(in: "[00:01.00]Challani gaali nadi meeda") == .latin)
        // English words mixed into Telugu lines don't flip the result.
        #expect(LyricsScript.dominant(in: "[00:01.00]Hey బేబీ చల్లని గాలి నది మీద\n[00:03.00]Oh చల్లని రాత్రి") == .telugu)
        // Tags are ignored; scripts we don't classify give nil.
        #expect(LyricsScript.dominant(in: "[ar:Someone][ti:Title]") == nil)
        #expect(LyricsScript.dominant(in: "[00:01.00]夜の川") == nil)
        #expect(LyricsScript.dominant(in: "") == nil)
    }

    @Test func findsLanguageHintsAsWholeWords() {
        #expect(IndianLanguage.hint(in: ["Pushpa - The Rise (Telugu)"]) == .telugu)
        #expect(IndianLanguage.hint(in: [nil, "Srivalli (Tamil Version)"]) == .tamil)
        #expect(IndianLanguage.hint(in: ["RRR - Hindi"]) == .hindi)
        #expect(IndianLanguage.hint(in: ["Bangla Hits"]) == .bengali)
        #expect(IndianLanguage.hint(in: ["Tamilnadu Tour", "Telugus"]) == nil, "only whole words")
        #expect(IndianLanguage.hint(in: ["Night Market", nil]) == nil)
        #expect(IndianLanguage.telugu.script == .telugu)
        #expect(IndianLanguage.marathi.script == .devanagari)
        #expect(IndianLanguage.punjabi.script == .gurmukhi)
    }
}

@Suite struct IndianTitleCleanupTests {
    @Test(arguments: [
        (#"Naatu Naatu (From "RRR")"#, "Naatu Naatu"),
        (#"Srivalli (From "Pushpa - The Rise")"#, "Srivalli"),
        (#"Srivalli - From "Pushpa - The Rise""#, "Srivalli"),
        ("Samajavaragamana Full Video Song | Ala Vaikunthapurramuloo | Allu Arjun", "Samajavaragamana"),
        ("Butta Bomma (Telugu Version)", "Butta Bomma"),
        ("Butta Bomma [Telugu]", "Butta Bomma"),
        ("Kesariya - Hindi", "Kesariya"),
        ("Oo Antava Oo Oo Antava (Lyrical)", "Oo Antava Oo Oo Antava"),
        ("Ramuloo Ramulaa - Full Video Song", "Ramuloo Ramulaa"),
        ("Inkem Inkem Inkem Kaavaale (Lyrical Video)", "Inkem Inkem Inkem Kaavaale"),
        ("From The Start", "From The Start"),
        ("(From Me) To You", "(From Me) To You"),
        ("Home Video", "Home Video"),
        ("Samajavaragamana - Video Song", "Samajavaragamana"),
    ])
    func cleans(raw: String, expected: String) {
        #expect(TrackNameCleaner.cleanTitleText(raw) == expected)
    }

    @Test func carriesTheLanguageHint() {
        let track = TrackNameCleaner.clean(title: #"Srivalli (From "Pushpa - The Rise")"#, artist: "Sid Sriram", album: "Pushpa - The Rise (Telugu)")
        #expect(track.title == "Srivalli")
        #expect(track.language == .telugu)
        #expect(track.album == "Pushpa - The Rise (Telugu)")
        let plain = TrackNameCleaner.clean(title: "Samajavaragamana", artist: "Sid Sriram, Thaman S", album: "Ala Vaikunthapurramuloo")
        #expect(plain.language == nil)
        #expect(plain.primaryArtist == "Sid Sriram")
    }
}

@Suite struct IndianWordTimingTests {
    @Test func countsAksharas() {
        #expect(SyllableCounter.count("నాటు") == 2)          // నా·టు
        #expect(SyllableCounter.count("नदी") == 2)            // न·दी
        #expect(SyllableCounter.count("मुझको") == 3)          // मु·झ·को
        #expect(SyllableCounter.count("நான்") == 1.5, "dead consonant (pulli) is half a beat")
        let conjunct = SyllableCounter.count("చుట్టమల్లె")   // చు·ట్ట·మ·ల్లె
        #expect(conjunct >= 4 && conjunct <= 5)
        #expect(SyllableCounter.count("suttukunte") == 3.5, "romanized: the final e is sung")
        #expect(SyllableCounter.count("Samajavaragamana") == 8)    // sa·ma·ja·va·ra·ga·ma·na
    }

    @Test func teluguLinesGetWordTimingInOrder() throws {
        let lyrics = try #require(Lyrics(lrc: "[00:10.00]చల్లని గాలి నది మీద\n[00:14.00]వెన్నెల రాత్రి"))
        let words = lyrics.lines[0].words
        #expect(words.map(\.text) == ["చల్లని", "గాలి", "నది", "మీద"])
        #expect(words.allSatisfy(\.spaceAfter) == false || words.dropLast().allSatisfy(\.spaceAfter))
        for (a, b) in zip(words, words.dropFirst()) { #expect(a.end == b.start) }
        // Longer words (more aksharas) get more time.
        #expect(words[0].end - words[0].start > words[2].end - words[2].start)
        #expect(lyrics.locate(10.1).lineIndex == 0)
    }
}

@Suite struct IndianLyricsSelectionTests {
    let telugu = "[00:10.00]చల్లని గాలి నది మీద"
    let tamil = "[00:10.00]நதி மேல் குளிர் காற்று"
    let romanized = "[00:10.00]Challani gaali nadi meeda"

    func record(_ id: Int, _ lrc: String, duration: Double = 221, title: String = "Srivalli", album: String = "Pushpa") -> String {
        let escaped = lrc.replacingOccurrences(of: "\n", with: "\\n")
        return #"{"id":\#(id),"trackName":"\#(title)","artistName":"Sid Sriram","albumName":"\#(album)","duration":\#(duration),"instrumental":false,"plainLyrics":"x","syncedLyrics":"\#(escaped)"}"#
    }

    func track(language: IndianLanguage?) -> CleanedTrack {
        CleanedTrack(title: "Srivalli", artist: "Sid Sriram", primaryArtist: "Sid Sriram",
                     album: language == nil ? "Pushpa - The Rise" : "Pushpa - The Rise (Telugu)", language: language)
    }

    @Test func rejectsAnotherLanguagesVersionAndSearchesByLanguage() async throws {
        // LRCLIB's exact match and first searches only have the Tamil version
        // (even filed under the Telugu album); "Srivalli Telugu" finds the right one.
        let http = FakeHTTP([
            "/api/get": [(200, record(1, tamil, album: "Pushpa - The Rise (Telugu)"))],
            "/api/search": [(200, "[" + record(2, tamil) + "]"), (200, "[" + record(3, tamil) + "]"), (200, "[" + record(4, telugu) + "]")],
        ])
        let result = try await LRCLibClient(http: http, sleep: { _ in }).lookup(track(language: .telugu), duration: 221, script: nil)
        #expect(result == .synced(lrc: telugu, recordID: 4))
        let queries = http.requests.indices.map { http.query($0)["q"] }.compactMap { $0 }
        #expect(queries.contains("Srivalli Telugu"))
    }

    @Test func neverShowsTheWrongLanguage() async throws {
        let http = FakeHTTP([
            "/api/get": [(200, record(1, tamil))],
            "/api/search": [(200, "[" + record(2, tamil) + "]")],
        ])
        let result = try await LRCLibClient(http: http, sleep: { _ in }).lookup(track(language: .telugu), duration: 221, script: nil)
        #expect(result == .plainOnly, "better no synced lyrics (beat visualizer) than Tamil lyrics on a Telugu song")
    }

    @Test func romanizedLyricsAreFineWithoutAPreference() async throws {
        let http = FakeHTTP(["/api/get": [(200, record(1, romanized))]])
        let result = try await LRCLibClient(http: http, sleep: { _ in }).lookup(track(language: .telugu), duration: 221, script: nil)
        #expect(result == .synced(lrc: romanized, recordID: 1))
        #expect(http.requests.count == 1)
    }

    @Test func preferenceForTeluguScriptPicksItOverRomanized() async throws {
        let http = FakeHTTP([
            "/api/get": [(200, record(1, romanized))],
            "/api/search": [(200, "[" + record(2, romanized) + "," + record(3, telugu) + "]")],
        ])
        let result = try await LRCLibClient(http: http, sleep: { _ in }).lookup(track(language: nil), duration: 221, script: .telugu)
        #expect(result == .synced(lrc: telugu, recordID: 3))
    }

    @Test func preferenceForEnglishLettersPicksRomanized() async throws {
        let http = FakeHTTP([
            "/api/get": [(200, record(1, telugu))],
            "/api/search": [(200, "[" + record(2, telugu) + "," + record(3, romanized, duration: 223) + "]")],
        ])
        let result = try await LRCLibClient(http: http, sleep: { _ in }).lookup(track(language: .telugu), duration: 221, script: .latin)
        #expect(result == .synced(lrc: romanized, recordID: 3))
    }

    @Test func preferenceFallsBackWhenOnlyOtherWritingExists() async throws {
        let http = FakeHTTP(["/api/get": [(200, record(1, romanized))], "/api/search": [(200, "[]")]])
        let result = try await LRCLibClient(http: http, sleep: { _ in }).lookup(track(language: nil), duration: 221, script: .telugu)
        #expect(result == .synced(lrc: romanized, recordID: 1), "romanized beats nothing")
    }

    @Test func teluguPreferenceWithoutHintAvoidsTamilWhenTeluguExists() async throws {
        let http = FakeHTTP([
            "/api/get": [(200, record(1, tamil))],
            "/api/search": [(200, "[" + record(2, tamil) + "]"), (200, "[]"), (200, "[" + record(5, telugu) + "]")],
        ])
        let result = try await LRCLibClient(http: http, sleep: { _ in }).lookup(track(language: nil), duration: 221, script: .telugu)
        #expect(result == .synced(lrc: telugu, recordID: 5))
    }

    @Test func noPreferenceNoHintKeepsOldBehavior() async throws {
        let http = FakeHTTP(["/api/get": [(200, record(1, tamil))]])
        let result = try await LRCLibClient(http: http, sleep: { _ in }).lookup(track(language: nil), duration: 221, script: nil)
        #expect(result == .synced(lrc: tamil, recordID: 1))
        #expect(http.requests.count == 1)
    }

    @Test func cacheKeySeparatesScripts() {
        let cleaned = track(language: .telugu)
        let english = LyricsPreference(writing: .english)
        let telugu = LyricsPreference(writing: .original, language: .telugu)
        #expect(LyricsCache.key(for: cleaned, duration: 221) != LyricsCache.key(for: cleaned, duration: 221, preference: english))
        #expect(LyricsCache.key(for: cleaned, duration: 221, preference: english) != LyricsCache.key(for: cleaned, duration: 221, preference: telugu))
    }
}

/// Real LRCLIB lookups for popular Telugu songs. Opt-in (network, rate limits):
/// `YTMGLOW_LIVE_LRCLIB=1 swift test --filter LiveIndianLyricsTests`
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YTMGLOW_LIVE_LRCLIB"] == "1"))
struct LiveIndianLyricsTests {
    let service = LyricsService(lookup: LRCLibClient(), cache: nil)

    func script(of outcome: LyricsOutcome) -> LyricsScript? {
        guard case let .synced(lyrics) = outcome else { return nil }
        return LyricsScript.dominant(in: lyrics.lines.map(\.text).joined(separator: " "))
    }

    @Test(arguments: [
        ("Srivalli", "Sid Sriram", "Pushpa - The Rise (Telugu)", 221.0, nil as LyricsScript?),
        ("Srivalli", "Sid Sriram", "Pushpa - The Rise", 221.0, LyricsScript.telugu),
        ("Naatu Naatu", "Rahul Sipligunj & Kaala Bhairava", "RRR (Telugu)", 214.0, nil),
        ("Samajavaragamana", "Sid Sriram", "Ala Vaikunthapurramuloo", 227.0, nil),
        ("Chuttamalle", "Shilpa Rao", "Devara Part 1 (Telugu)", 219.0, LyricsScript.telugu),
    ])
    func finds(title: String, artist: String, album: String, duration: Double, preferred: LyricsScript?) async throws {
        let preference = preferred == .telugu ? LyricsPreference(writing: .original, language: .telugu) : LyricsPreference(writing: .original)
        let outcome = await service.lyrics(title: title, artist: artist, album: album, duration: duration, preference: preference)
        if case let .failed(message) = outcome {
            withKnownIssue("LRCLIB unavailable: \(message)") { Issue.record("network") }
            return
        }
        let found = script(of: outcome)
        print("LIVE \(title) [\(album)] preferred=\(preferred?.rawValue ?? "any") -> \(found?.rawValue ?? "\(outcome)")")
        #expect(found != nil, "synced lyrics found")
        #expect(found != .tamil && found != .kannada && found != .malayalam && found != .devanagari, "not another language's version")
        if preferred == .telugu { #expect(found == .telugu) }
    }

    @Test(arguments: [
        ("Srivalli", "Sid Sriram", "Pushpa - The Rise (Telugu)", 221.0),
        ("Chuttamalle", "Shilpa Rao", "Devara Part 1 (Telugu)", 219.0),
    ])
    func englishLettersByDefault(title: String, artist: String, album: String, duration: Double) async throws {
        let outcome = await service.lyrics(title: title, artist: artist, album: album, duration: duration,
                                           preference: .init(writing: .english, language: .telugu))
        if case let .failed(message) = outcome {
            withKnownIssue("LRCLIB unavailable: \(message)") { Issue.record("network") }
            return
        }
        guard case let .synced(lyrics) = outcome else { Issue.record("no lyrics: \(outcome)"); return }
        let sample = lyrics.lines.prefix(2).map(\.text).joined(separator: " / ")
        print("LIVE-EN \(title): \(sample)  [from \(lyrics.transliteratedFrom?.rawValue ?? "romanized source")]")
        #expect(script(of: outcome) == .latin, "English letters only")
        #expect(lyrics.transliteratedFrom == nil || lyrics.transliteratedFrom == .telugu, "transliterated from Telugu, not Tamil")
    }
}
