import Foundation

public protocol HTTPFetching: Sendable {
    /// Returns the body and HTTP status code.
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int)
}

public struct URLSessionFetcher: HTTPFetching {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public struct LRCLibRecord: Codable, Equatable, Sendable {
    public var id: Int?
    public var trackName: String?
    public var artistName: String?
    public var albumName: String?
    public var duration: Double?
    public var instrumental: Bool?
    public var plainLyrics: String?
    public var syncedLyrics: String?

    public init(id: Int? = nil, trackName: String? = nil, artistName: String? = nil, albumName: String? = nil,
                duration: Double? = nil, instrumental: Bool? = nil, plainLyrics: String? = nil, syncedLyrics: String? = nil) {
        self.id = id
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.instrumental = instrumental
        self.plainLyrics = plainLyrics
        self.syncedLyrics = syncedLyrics
    }

    var hasSynced: Bool { !(syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
    var hasPlain: Bool { !(plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
}

public enum LyricsLookupResult: Codable, Equatable, Sendable {
    case synced(lrc: String, recordID: Int?)
    /// Lyrics exist but without timestamps, so they can't be synced.
    case plainOnly
    case instrumental
    case notFound
}

public enum LyricsLookupError: Error, Equatable {
    case http(Int)
    case network(String)
    case badResponse
}

public protocol LyricsLookup: Sendable {
    /// - Parameter script: preferred writing system for the lyrics, or nil for any.
    func lookup(_ track: CleanedTrack, duration: Double?, script: LyricsScript?) async throws -> LyricsLookupResult
}

/// Client for https://lrclib.net (free, no API key).
public struct LRCLibClient: LyricsLookup {
    public static let defaultUserAgent = "YTMGlow/0.1.0 (personal macOS menu bar app; https://github.com/SaandeepB/YTM-Glow)"
    /// Search results further than this from the song's duration are ignored.
    public static let searchDurationTolerance: Double = 10

    let baseURL: URL
    let http: HTTPFetching
    let userAgent: String
    let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        baseURL: URL = URL(string: "https://lrclib.net")!,
        http: HTTPFetching = URLSessionFetcher(),
        userAgent: String = LRCLibClient.defaultUserAgent,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.baseURL = baseURL
        self.http = http
        self.userAgent = userAgent
        self.sleep = sleep
    }

    public func lookup(_ track: CleanedTrack, duration: Double?) async throws -> LyricsLookupResult {
        try await lookup(track, duration: duration, script: nil)
    }

    /// - Parameter script: the writing system the user prefers for lyrics
    ///   (e.g. Telugu script vs English letters); nil for no preference.
    public func lookup(_ track: CleanedTrack, duration: Double?, script preferred: LyricsScript?) async throws -> LyricsLookupResult {
        let roundedDuration = duration.flatMap { $0.isFinite && $0 > 0 ? Int($0.rounded()) : nil }
        var sawPlain = false
        var sawInstrumental = false
        var best: (record: LRCLibRecord, score: Double)?

        func note(_ record: LRCLibRecord) {
            if record.instrumental == true { sawInstrumental = true }
            if record.hasPlain { sawPlain = true }
        }
        func consider(_ record: LRCLibRecord, exact: Bool) {
            guard let score = Self.score(record, for: track, duration: exact ? nil : duration, preferred: preferred, exact: exact) else { return }
            if best == nil || score < best!.score { best = (record, score) }
        }
        /// A candidate in the right script with matching names and duration.
        var goodEnough: Bool { (best?.score ?? .infinity) <= Self.goodEnoughScore }

        // 1. Exact signature match, then looser variants.
        var attempts: [(artist: String, album: String?)] = [(track.artist, track.album)]
        if track.album != nil { attempts.append((track.artist, nil)) }
        if track.primaryArtist != track.artist { attempts.append((track.primaryArtist, nil)) }
        for attempt in attempts {
            var query = [URLQueryItem(name: "track_name", value: track.title), URLQueryItem(name: "artist_name", value: attempt.artist)]
            if let album = attempt.album { query.append(URLQueryItem(name: "album_name", value: album)) }
            if let roundedDuration { query.append(URLQueryItem(name: "duration", value: String(roundedDuration))) }
            guard let record = try await getRecord(query) else { continue }
            note(record)
            consider(record, exact: true)
            if goodEnough { break }
        }

        // 2. Searches, from precise to broad. Multi-language film songs share a
        //    title across versions, so when the right script hasn't turned up,
        //    also search by language name and by album.
        var searches: [[URLQueryItem]] = [
            [URLQueryItem(name: "track_name", value: track.title), URLQueryItem(name: "artist_name", value: track.primaryArtist)],
            [URLQueryItem(name: "q", value: "\(track.title) \(track.primaryArtist)")],
        ]
        let target = preferred?.isIndic == true ? preferred : track.language?.script
        if let name = target?.searchName {
            searches.append([URLQueryItem(name: "q", value: "\(track.title) \(name)")])
            if let album = track.album {
                let movie = TrackNameCleaner.cleanTitleText(album)
                if !movie.isEmpty { searches.append([URLQueryItem(name: "q", value: "\(track.title) \(movie)")]) }
            }
        }
        for query in searches where !goodEnough {
            let records = try await search(query)
            for record in records {
                consider(record, exact: false)
                if Self.namesMatch(record, track) { note(record) }
            }
        }

        if let best { return .synced(lrc: best.record.syncedLyrics!, recordID: best.record.id) }
        if sawInstrumental { return .instrumental }
        if sawPlain { return .plainOnly }
        return .notFound
    }

    /// Scores at or below this stop the lookup early.
    static let goodEnoughScore = 3.0

    /// Lower is better; nil means unusable. Combines name match, duration
    /// distance and script fit. Lyrics in a different Indian script than the
    /// language in the track's metadata are another language's version and
    /// are never used.
    static func score(_ record: LRCLibRecord, for track: CleanedTrack, duration: Double?, preferred: LyricsScript?, exact: Bool) -> Double? {
        guard record.hasSynced else { return nil }
        var penalty = 0.0
        if !exact {
            penalty += namesMatch(record, track) ? 0 : 6
            if let duration, duration > 0 {
                guard let recordDuration = record.duration else { return nil }
                let delta = abs(recordDuration - duration)
                guard delta <= searchDurationTolerance else { return nil }
                penalty += delta
            } else if penalty > 0 {
                return nil
            }
        }
        guard let script = scriptPenalty(LyricsScript.dominant(in: record.syncedLyrics ?? ""), language: track.language, preferred: preferred) else {
            return nil
        }
        return penalty + script
    }

    /// 0 = fits; nil = wrong language version.
    static func scriptPenalty(_ script: LyricsScript?, language: IndianLanguage?, preferred: LyricsScript?) -> Double? {
        guard let script else { return 0 }
        if let language, script.isIndic, script != language.script { return nil }
        // With no explicit preference, the metadata's language script is the target.
        guard let target = preferred ?? language?.script else { return 0 }
        if script == target { return 0 }
        // Another Indian script than wanted: probably another language's version.
        if script.isIndic && target.isIndic { return 8 }
        // Romanized vs. native script: same song, just not the preferred writing.
        return preferred == nil ? 0 : 4
    }

    /// Best synced record from a search result (used by tests and the lookup).
    public static func bestMatch(_ records: [LRCLibRecord], for track: CleanedTrack, duration: Double?, script: LyricsScript? = nil) -> LRCLibRecord? {
        records
            .compactMap { record in score(record, for: track, duration: duration, preferred: script, exact: false).map { (record, $0) } }
            .min { $0.1 < $1.1 }?
            .0
    }

    static func namesMatch(_ record: LRCLibRecord, _ track: CleanedTrack) -> Bool {
        let recordTitle = TrackNameCleaner.normalizeKey(TrackNameCleaner.cleanTitleText(record.trackName ?? ""))
        let recordArtist = TrackNameCleaner.normalizeKey(record.artistName ?? "")
        let title = TrackNameCleaner.normalizeKey(track.title)
        let artist = TrackNameCleaner.normalizeKey(track.primaryArtist)
        guard !recordTitle.isEmpty, !title.isEmpty else { return false }
        let titleMatches = recordTitle == title || recordTitle.hasPrefix(title) || title.hasPrefix(recordTitle)
        let artistMatches = artist.isEmpty || recordArtist.contains(artist) || artist.contains(recordArtist)
        return titleMatches && artistMatches
    }

    // MARK: - HTTP

    private func getRecord(_ query: [URLQueryItem]) async throws -> LRCLibRecord? {
        let (data, status) = try await fetch(path: "/api/get", query: query)
        if status == 404 { return nil }
        guard status == 200 else { throw LyricsLookupError.http(status) }
        do {
            return try JSONDecoder().decode(LRCLibRecord.self, from: data)
        } catch {
            throw LyricsLookupError.badResponse
        }
    }

    private func search(_ query: [URLQueryItem]) async throws -> [LRCLibRecord] {
        let (data, status) = try await fetch(path: "/api/search", query: query)
        if status == 404 { return [] }
        guard status == 200 else { throw LyricsLookupError.http(status) }
        do {
            return try JSONDecoder().decode([LRCLibRecord].self, from: data)
        } catch {
            throw LyricsLookupError.badResponse
        }
    }

    /// GET with one retry after 1 s on 503.
    private func fetch(path: String, query: [URLQueryItem]) async throws -> (Data, Int) {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        guard let url = components.url else { throw LyricsLookupError.badResponse }
        let headers = ["User-Agent": userAgent, "Accept": "application/json"]

        var attempt = 0
        while true {
            attempt += 1
            let response: (Data, Int)
            do {
                response = try await http.get(url, headers: headers)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw LyricsLookupError.network(error.localizedDescription)
            }
            if response.1 == 503 && attempt == 1 {
                try await sleep(1)
                continue
            }
            return response
        }
    }
}
