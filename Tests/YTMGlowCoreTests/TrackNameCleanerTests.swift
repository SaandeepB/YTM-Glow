import Testing
@testable import YTMGlowCore

@Suite struct TrackNameCleanerTests {
    @Test(arguments: [
        ("Glass Lanterns (Official Video)", "Glass Lanterns"),
        ("Glass Lanterns [Official Music Video]", "Glass Lanterns"),
        ("Glass Lanterns (Lyrics)", "Glass Lanterns"),
        ("Glass Lanterns (Official Audio) [HD]", "Glass Lanterns"),
        ("Glass Lanterns (feat. Someone Else)", "Glass Lanterns"),
        ("Glass Lanterns ft. Someone Else", "Glass Lanterns"),
        ("Glass Lanterns (Acoustic)", "Glass Lanterns (Acoustic)"),
        ("Glass Lanterns (Live at Home)", "Glass Lanterns (Live at Home)"),
        ("Glass Lanterns - Remastered 2011", "Glass Lanterns"),
        ("Glass Lanterns - 2009 Remaster", "Glass Lanterns"),
        ("Glass Lanterns | Official Visualizer", "Glass Lanterns"),
        ("Glass Lanterns 【MV】", "Glass Lanterns"),
        ("Remix (Something)", "Remix (Something)"),
    ])
    func cleansTitles(raw: String, expected: String) {
        #expect(TrackNameCleaner.cleanTitleText(raw) == expected)
    }

    @Test func cleansArtists() {
        #expect(TrackNameCleaner.cleanArtistName("The Paper Moths - Topic") == "The Paper Moths")
        #expect(TrackNameCleaner.cleanArtistName("PaperMothsVEVO") == "Paper Moths")
        #expect(TrackNameCleaner.cleanArtistName("  The Paper Moths  ") == "The Paper Moths")
        #expect(TrackNameCleaner.cleanArtistName("Paper Moths Official") == "Paper Moths")
    }

    @Test func findsPrimaryArtist() {
        #expect(TrackNameCleaner.primaryArtist(of: "A, B & C") == "A")
        #expect(TrackNameCleaner.primaryArtist(of: "A & B") == "A")
        #expect(TrackNameCleaner.primaryArtist(of: "A feat. B") == "A")
        #expect(TrackNameCleaner.primaryArtist(of: "A x B") == "A")
        #expect(TrackNameCleaner.primaryArtist(of: "Xavier") == "Xavier", "x inside a word is not a separator")
        #expect(TrackNameCleaner.primaryArtist(of: "Simon & Garfunkel") == "Simon")
        #expect(TrackNameCleaner.primaryArtist(of: "Solo") == "Solo")
    }

    @Test func splitsArtistDashTitleUploads() {
        let vevo = TrackNameCleaner.clean(title: "Paper Moths - Glass Lanterns (Official Video)", artist: "PaperMothsVEVO", album: nil)
        #expect(vevo.title == "Glass Lanterns")
        #expect(vevo.artist == "Paper Moths")

        let sameArtist = TrackNameCleaner.clean(title: "The Paper Moths - Glass Lanterns", artist: "The Paper Moths", album: "")
        #expect(sameArtist.title == "Glass Lanterns")
        #expect(sameArtist.album == nil)

        // A dash that is part of the song title is kept.
        let kept = TrackNameCleaner.clean(title: "Night - Day", artist: "The Paper Moths", album: "Night Market")
        #expect(kept.title == "Night - Day")
        #expect(kept.album == "Night Market")

        // Release notes after a dash never become the artist.
        let topic = TrackNameCleaner.clean(title: "Glass Lanterns - Remastered 2011", artist: "The Paper Moths - Topic", album: nil)
        #expect(topic.title == "Glass Lanterns")
        #expect(topic.artist == "The Paper Moths")
    }

    @Test func normalizesKeys() {
        #expect(TrackNameCleaner.normalizeKey("Corazón  Partío!") == "corazon partio")
        #expect(TrackNameCleaner.normalizeKey("ＡＢＣ") == "abc")
    }
}
