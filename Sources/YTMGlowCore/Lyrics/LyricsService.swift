import CryptoKit
import Foundation

/// On-disk cache of lyric lookups, one small JSON file per track.
public final class LyricsCache: @unchecked Sendable {
    struct Entry: Codable {
        var key: String
        var result: LyricsLookupResult
        var storedAt: Date
    }

    /// Misses are retried after this long, since LRCLIB grows daily.
    public static let missLifetime: TimeInterval = 3 * 24 * 3600

    let directory: URL
    private let lock = NSLock()
    private let now: @Sendable () -> Date

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    public static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("YTMGlow/lyrics", isDirectory: true)
    }

    public static func key(for track: CleanedTrack, duration: Double?) -> String {
        let seconds = duration.map { String(Int($0.rounded())) } ?? "?"
        return [track.title, track.primaryArtist, track.album ?? ""]
            .map(TrackNameCleaner.normalizeKey)
            .joined(separator: "|") + "|" + seconds
    }

    public func read(_ key: String) -> LyricsLookupResult? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL(for: key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.key == key else { return nil }
        switch entry.result {
        case .notFound, .plainOnly:
            if now().timeIntervalSince(entry.storedAt) > Self.missLifetime { return nil }
        case .synced, .instrumental:
            break
        }
        return entry.result
    }

    public func write(_ result: LyricsLookupResult, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        let entry = Entry(key: key, result: result, storedAt: now())
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).json")
    }
}

public enum LyricsOutcome: Equatable, Sendable {
    case synced(Lyrics)
    case plainOnly
    case instrumental
    case notFound
    case failed(String)
}

/// Cleans track names, checks the cache, then asks the lookup.
public final class LyricsService: Sendable {
    let lookup: LyricsLookup
    let cache: LyricsCache?

    public init(lookup: LyricsLookup = LRCLibClient(), cache: LyricsCache? = LyricsCache(directory: LyricsCache.defaultDirectory)) {
        self.lookup = lookup
        self.cache = cache
    }

    public func lyrics(title: String, artist: String, album: String?, duration: Double?) async -> LyricsOutcome {
        let track = TrackNameCleaner.clean(title: title, artist: artist, album: album)
        guard !track.title.isEmpty else { return .notFound }
        let key = LyricsCache.key(for: track, duration: duration)

        let result: LyricsLookupResult
        if let cached = cache?.read(key) {
            result = cached
        } else {
            do {
                result = try await lookup.lookup(track, duration: duration)
            } catch is CancellationError {
                return .failed("cancelled")
            } catch {
                return .failed(Self.describe(error))
            }
            cache?.write(result, for: key)
        }

        switch result {
        case let .synced(lrc, _):
            guard let lyrics = Lyrics(lrc: lrc, songDuration: duration) else { return .plainOnly }
            return .synced(lyrics)
        case .plainOnly: return .plainOnly
        case .instrumental: return .instrumental
        case .notFound: return .notFound
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let LyricsLookupError.http(code): return "LRCLIB returned HTTP \(code)"
        case let LyricsLookupError.network(message): return message
        case LyricsLookupError.badResponse: return "Unexpected response from LRCLIB"
        default: return error.localizedDescription
        }
    }
}
