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
    func lookup(_ track: CleanedTrack, duration: Double?) async throws -> LyricsLookupResult
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
        let roundedDuration = duration.flatMap { $0.isFinite && $0 > 0 ? Int($0.rounded()) : nil }
        var sawPlain = false
        var sawInstrumental = false

        func consider(_ record: LRCLibRecord?) -> LyricsLookupResult? {
            guard let record else { return nil }
            if record.hasSynced { return .synced(lrc: record.syncedLyrics!, recordID: record.id) }
            if record.instrumental == true { sawInstrumental = true }
            if record.hasPlain { sawPlain = true }
            return nil
        }

        // 1. Exact signature match, then looser variants.
        var attempts: [(artist: String, album: String?)] = [(track.artist, track.album)]
        if track.album != nil { attempts.append((track.artist, nil)) }
        if track.primaryArtist != track.artist { attempts.append((track.primaryArtist, nil)) }
        for attempt in attempts {
            var query = [URLQueryItem(name: "track_name", value: track.title), URLQueryItem(name: "artist_name", value: attempt.artist)]
            if let album = attempt.album { query.append(URLQueryItem(name: "album_name", value: album)) }
            if let roundedDuration { query.append(URLQueryItem(name: "duration", value: String(roundedDuration))) }
            if let found = consider(try await getRecord(query)) { return found }
        }

        // 2. Search, picking the closest duration with synced lyrics.
        let searches: [[URLQueryItem]] = [
            [URLQueryItem(name: "track_name", value: track.title), URLQueryItem(name: "artist_name", value: track.primaryArtist)],
            [URLQueryItem(name: "q", value: "\(track.title) \(track.primaryArtist)")],
        ]
        for query in searches {
            let records = try await search(query)
            if let best = Self.bestMatch(records, for: track, duration: duration) {
                return .synced(lrc: best.syncedLyrics!, recordID: best.id)
            }
            for record in records where Self.namesMatch(record, track) {
                if record.instrumental == true { sawInstrumental = true }
                if record.hasPlain { sawPlain = true }
            }
        }

        if sawInstrumental { return .instrumental }
        if sawPlain { return .plainOnly }
        return .notFound
    }

    /// Closest-duration record with synced lyrics, preferring matching names.
    public static func bestMatch(_ records: [LRCLibRecord], for track: CleanedTrack, duration: Double?) -> LRCLibRecord? {
        let candidates = records.filter(\.hasSynced)
        func score(_ record: LRCLibRecord) -> Double? {
            var penalty = namesMatch(record, track) ? 0.0 : 6.0
            if let duration, duration > 0 {
                guard let recordDuration = record.duration else { return nil }
                let delta = abs(recordDuration - duration)
                guard delta <= searchDurationTolerance else { return nil }
                penalty += delta
            } else if penalty > 0 {
                return nil
            }
            return penalty
        }
        return candidates
            .compactMap { record in score(record).map { (record, $0) } }
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
