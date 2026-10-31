import Foundation
import Testing
@testable import YTMGlowCore

/// Scripted HTTP responses keyed by path, recording every request.
final class FakeHTTP: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [String: [(Int, String)]]
    private(set) var requests: [URL] = []
    private(set) var headers: [[String: String]] = []

    init(_ responses: [String: [(Int, String)]]) { queue = responses }

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        requests.append(url)
        self.headers.append(headers)
        let path = url.path
        guard var list = queue[path], !list.isEmpty else { return (Data(), 404) }
        let next = list.removeFirst()
        if !list.isEmpty || queue[path]!.count == 1 { queue[path] = list.isEmpty ? [next] : list }
        return (Data(next.1.utf8), next.0)
    }

    func query(_ index: Int) -> [String: String] {
        let items = URLComponents(url: requests[index], resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
}

@Suite struct LRCLibClientTests {
    let track = CleanedTrack(title: "Glass Lanterns", artist: "The Paper Moths & Friend", primaryArtist: "The Paper Moths", album: "Night Market")
    let synced = "[00:01.00]Hello"

    func record(_ id: Int, duration: Double, synced: String?, plain: String? = "x", title: String = "Glass Lanterns", artist: String = "The Paper Moths", instrumental: Bool = false) -> String {
        let syncedJSON = synced.map { "\"\($0)\"" } ?? "null"
        let plainJSON = plain.map { "\"\($0)\"" } ?? "null"
        return #"{"id":\#(id),"trackName":"\#(title)","artistName":"\#(artist)","albumName":"Night Market","duration":\#(duration),"instrumental":\#(instrumental),"plainLyrics":\#(plainJSON),"syncedLyrics":\#(syncedJSON)}"#
    }

    @Test func exactGetHitSendsAllParamsAndUserAgent() async throws {
        let http = FakeHTTP(["/api/get": [(200, record(7, duration: 200, synced: synced))]])
        let client = LRCLibClient(http: http, sleep: { _ in })
        let result = try await client.lookup(track, duration: 200.4)
        #expect(result == .synced(lrc: synced, recordID: 7))
        #expect(http.requests.count == 1)
        #expect(http.query(0) == ["track_name": "Glass Lanterns", "artist_name": "The Paper Moths & Friend", "album_name": "Night Market", "duration": "200"])
        #expect(http.headers[0]["User-Agent"]?.hasPrefix("YTMGlow/") == true)
        #expect(http.requests[0].host == "lrclib.net")
        #expect(http.requests[0].scheme == "https")
    }

    @Test func fallsBackThroughLooserGetsThenSearch() async throws {
        let results = "[" + [
            record(1, duration: 260, synced: synced),               // too far from 200 s
            record(2, duration: 203, synced: synced),               // closest with synced lyrics
            record(3, duration: 200, synced: nil),                  // exact duration but no sync
            record(4, duration: 201, synced: synced, title: "Other Song"),
        ].joined(separator: ",") + "]"
        let http = FakeHTTP(["/api/search": [(200, results)]])
        let client = LRCLibClient(http: http, sleep: { _ in })
        let result = try await client.lookup(track, duration: 200)
        #expect(result == .synced(lrc: synced, recordID: 2))
        // get (full), get (no album), get (primary artist), then search.
        #expect(http.requests.map(\.path) == ["/api/get", "/api/get", "/api/get", "/api/search"])
        #expect(http.query(1)["album_name"] == nil)
        #expect(http.query(2)["artist_name"] == "The Paper Moths")
        #expect(http.query(3) == ["track_name": "Glass Lanterns", "artist_name": "The Paper Moths"])
    }

    @Test func plainOnlyGetContinuesSearchingForSynced() async throws {
        let http = FakeHTTP([
            "/api/get": [(200, record(1, duration: 200, synced: nil))],
            "/api/search": [(200, "[]")],
        ])
        let result = try await LRCLibClient(http: http, sleep: { _ in }).lookup(track, duration: 200)
        #expect(result == .plainOnly)
        #expect(http.requests.filter { $0.path == "/api/search" }.count == 2, "track/artist search, then q search")
    }

    @Test func reportsInstrumentalAndNotFound() async throws {
        let instrumental = FakeHTTP(["/api/get": [(200, record(1, duration: 200, synced: nil, plain: nil, instrumental: true))], "/api/search": [(200, "[]")]])
        #expect(try await LRCLibClient(http: instrumental, sleep: { _ in }).lookup(track, duration: 200) == .instrumental)
        let nothing = FakeHTTP(["/api/search": [(200, "[]")]])
        #expect(try await LRCLibClient(http: nothing, sleep: { _ in }).lookup(track, duration: nil) == .notFound)
        #expect(nothing.requests.allSatisfy { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "duration" } != true })
    }

    @Test func retriesOnceAfterOneSecondOn503() async throws {
        let slept = SleepRecorder()
        let http = FakeHTTP(["/api/get": [(503, ""), (200, record(9, duration: 200, synced: synced))]])
        let result = try await LRCLibClient(http: http, sleep: { await slept.record($0) }).lookup(track, duration: 200)
        #expect(result == .synced(lrc: synced, recordID: 9))
        #expect(await slept.values == [1])
        #expect(http.requests.count == 2)
    }

    @Test func secondFailureIsAnError() async throws {
        let http = FakeHTTP(["/api/get": [(503, ""), (503, "")]])
        await #expect(throws: LyricsLookupError.http(503)) {
            try await LRCLibClient(http: http, sleep: { _ in }).lookup(track, duration: 200)
        }
        let broken = FakeHTTP(["/api/get": [(200, "{not json")]])
        await #expect(throws: LyricsLookupError.badResponse) {
            try await LRCLibClient(http: broken, sleep: { _ in }).lookup(track, duration: 200)
        }
    }

    @Test func bestMatchPrefersNamesThenDuration() {
        let records = [
            LRCLibRecord(id: 1, trackName: "Glass Lanterns", artistName: "Someone Else", duration: 200, syncedLyrics: synced),
            LRCLibRecord(id: 2, trackName: "Glass Lanterns (Remastered)", artistName: "The Paper Moths", duration: 204, syncedLyrics: synced),
        ]
        #expect(LRCLibClient.bestMatch(records, for: track, duration: 200)?.id == 2)
        #expect(LRCLibClient.bestMatch(records, for: track, duration: nil)?.id == 2)
        #expect(LRCLibClient.bestMatch(records, for: track, duration: 500) == nil)
    }
}

actor SleepRecorder {
    var values: [TimeInterval] = []
    func record(_ value: TimeInterval) { values.append(value) }
}

@Suite struct LyricsServiceTests {
    struct CountingLookup: LyricsLookup {
        let counter = Counter()
        var result: LyricsLookupResult
        var error: LyricsLookupError?
        func lookup(_ track: CleanedTrack, duration: Double?, preference: LyricsPreference) async throws -> LyricsLookupResult {
            await counter.increment(track)
            if let error { throw error }
            return result
        }
    }

    actor Counter {
        var count = 0
        var lastTrack: CleanedTrack?
        func increment(_ track: CleanedTrack) { count += 1; lastTrack = track }
    }

    func tempCache(now: @escaping @Sendable () -> Date = { Date() }) -> LyricsCache {
        LyricsCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ytmglow-tests-\(UUID().uuidString)"), now: now)
    }

    @Test func cleansNamesAndCachesHits() async throws {
        let lookup = CountingLookup(result: .synced(lrc: "[00:01.00]Hi there", recordID: 1))
        let service = LyricsService(lookup: lookup, cache: tempCache())
        let first = await service.lyrics(title: "Glass Lanterns (Official Video)", artist: "The Paper Moths - Topic", album: "Night Market", duration: 200)
        guard case let .synced(lyrics) = first else { Issue.record("expected synced"); return }
        #expect(lyrics.lines.first?.text == "Hi there")
        #expect(await lookup.counter.lastTrack?.title == "Glass Lanterns")
        #expect(await lookup.counter.lastTrack?.artist == "The Paper Moths")

        _ = await service.lyrics(title: "Glass Lanterns (Official Video)", artist: "The Paper Moths - Topic", album: "Night Market", duration: 200.3)
        #expect(await lookup.counter.count == 1, "second request served from disk cache")
    }

    @Test func errorsAreNotCached() async {
        let lookup = CountingLookup(result: .notFound, error: .network("offline"))
        let service = LyricsService(lookup: lookup, cache: tempCache())
        #expect(await service.lyrics(title: "A", artist: "B", album: nil, duration: 100) == .failed("offline"))
        _ = await service.lyrics(title: "A", artist: "B", album: nil, duration: 100)
        #expect(await lookup.counter.count == 2)
    }

    @Test func missesExpireButHitsDoNot() throws {
        let clock = MutableDate()
        let cache = tempCache(now: { clock.value })
        cache.write(.notFound, for: "miss")
        cache.write(.synced(lrc: "[00:01.00]x", recordID: nil), for: "hit")
        #expect(cache.read("miss") == .notFound)
        clock.value = clock.value.addingTimeInterval(LyricsCache.missLifetime + 60)
        #expect(cache.read("miss") == nil)
        #expect(cache.read("hit") == .synced(lrc: "[00:01.00]x", recordID: nil))
        #expect(cache.read("never-written") == nil)
    }

    @Test func cacheKeyIgnoresDecorationsAndRoundsDuration() {
        let a = TrackNameCleaner.clean(title: "Glass Lanterns (Lyrics)", artist: "The Paper Moths", album: "Night Market")
        let b = TrackNameCleaner.clean(title: "glass lanterns", artist: "THE PAPER MOTHS", album: "Night Market")
        #expect(LyricsCache.key(for: a, duration: 200.2) == LyricsCache.key(for: b, duration: 199.8))
        #expect(LyricsCache.key(for: a, duration: 200) != LyricsCache.key(for: a, duration: 230))
    }
}

final class MutableDate: @unchecked Sendable {
    var value = Date(timeIntervalSince1970: 1_800_000_000)
}
