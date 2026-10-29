import Foundation

/// Search terms derived from player metadata.
public struct CleanedTrack: Equatable, Sendable {
    public var title: String
    /// All credited artists, as shown by the player but tidied.
    public var artist: String
    /// The first credited artist; LRCLIB usually files songs under it.
    public var primaryArtist: String
    public var album: String?

    public init(title: String, artist: String, primaryArtist: String, album: String?) {
        self.title = title
        self.artist = artist
        self.primaryArtist = primaryArtist
        self.album = album
    }
}

/// Removes video decorations ("(Official Video)", "[Lyrics]", "feat. X") and
/// channel-name artifacts ("- Topic", "VEVO") so lyric lookups match.
public enum TrackNameCleaner {
    /// Bracketed segments containing any of these words are dropped from titles.
    static let noiseWords: [String] = [
        "official", "video", "audio", "lyric", "lyrics", "visualizer", "visualiser",
        "mv", "m/v", "hd", "hq", "4k", "8k", "remaster", "remastered", "explicit",
        "clean", "color coded", "colour coded", "music video", "performance video",
        "full song", "sub español", "subtitulado", "legendado", "letra",
        "feat", "feat.", "ft", "ft.", "featuring", "with", "prod", "prod.",
    ]

    public static func clean(title: String, artist: String, album: String?) -> CleanedTrack {
        var cleanArtist = cleanArtistName(artist)
        var cleanTitle = cleanTitleText(title)

        // Uploads often use "Artist - Title" with the channel as artist.
        if let split = splitArtistTitle(cleanTitle) {
            let channelLike = artist.hasSuffix(" - Topic") || artist.uppercased().hasSuffix("VEVO") || cleanArtist.isEmpty
            let artistKey = normalizeKey(cleanArtist)
            let matchesArtist = !artistKey.isEmpty && normalizeKey(split.artist).contains(artistKey)
            if channelLike || matchesArtist {
                if channelLike { cleanArtist = cleanArtistName(split.artist) }
                cleanTitle = cleanTitleText(split.title)
            }
        }

        let primary = primaryArtist(of: cleanArtist)

        var cleanAlbum = album?.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanAlbum?.isEmpty == true { cleanAlbum = nil }
        return CleanedTrack(title: cleanTitle, artist: cleanArtist, primaryArtist: primary, album: cleanAlbum)
    }

    public static func cleanTitleText(_ title: String) -> String {
        var text = title
        // Drop noisy (...) and [...] segments; keep meaningful ones like "(Acoustic)".
        for (open, close) in [("(", ")"), ("[", "]"), ("【", "】"), ("「", "」")] {
            text = removeBracketed(text, open: open, close: close) { inner in
                let lower = inner.lowercased()
                return noiseWords.contains { word in containsWord(lower, word) }
            }
        }
        // Trailing "feat. X" / "ft. X" without brackets.
        if let range = text.range(of: #"\s+(feat\.?|ft\.?|featuring)\s+.*$"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        // Trailing " - Remastered 2011" / " - Mono" release notes.
        if let range = text.range(of: #"\s+[-–—]\s+(\d{4}\s+)?(remaster(ed)?|mono|stereo)(\s+\d{4})?(\s+(version|mix))?$"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        // Trailing "| Official Video" style suffixes.
        if let range = text.range(of: #"\s*[|｜]\s*.*(official|video|audio|lyric).*$"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        return collapseSpaces(text).trimmingCharacters(in: CharacterSet(charactersIn: " -–—|"))
    }

    public static func cleanArtistName(_ artist: String) -> String {
        var text = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - Topic", " – Topic"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }
        if text.count > 4, text.uppercased().hasSuffix("VEVO") {
            text = String(text.dropLast(4))
            // "TaylorSwiftVEVO" -> "Taylor Swift"
            text = text.replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
        }
        if let range = text.range(of: #"\s*(official)$"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        return collapseSpaces(text)
    }

    /// "A, B & C" -> "A"; "A feat. B" -> "A"; "A x B" -> "A".
    public static func primaryArtist(of artist: String) -> String {
        let pattern = #"\s*(,|&|\band\b|\bx\b|×|\bfeat\.?|\bft\.?|\bfeaturing\b|\bwith\b|\bvs\.?|/|;|、)\s*"#
        guard let range = artist.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
              range.lowerBound > artist.startIndex else { return artist }
        return String(artist[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// Lowercased, accent- and punctuation-free key used for comparisons and cache keys.
    public static func normalizeKey(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let kept = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return collapseSpaces(String(String.UnicodeScalarView(kept)))
    }

    static func fuzzyEqual(_ a: String, _ b: String) -> Bool {
        let left = normalizeKey(a)
        return !left.isEmpty && left == normalizeKey(b)
    }

    private static func splitArtistTitle(_ title: String) -> (artist: String, title: String)? {
        for separator in [" - ", " – ", " — "] {
            if let range = title.range(of: separator) {
                let artist = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let rest = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !artist.isEmpty, !rest.isEmpty { return (artist, rest) }
            }
        }
        return nil
    }

    private static func removeBracketed(_ text: String, open: String, close: String, shouldRemove: (String) -> Bool) -> String {
        var result = text
        var searchStart = result.startIndex
        while let openRange = result.range(of: open, range: searchStart..<result.endIndex),
              let closeRange = result.range(of: close, range: openRange.upperBound..<result.endIndex) {
            let inner = String(result[openRange.upperBound..<closeRange.lowerBound])
            if shouldRemove(inner) {
                result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                searchStart = openRange.lowerBound
            } else {
                searchStart = closeRange.upperBound
            }
        }
        return result
    }

    private static func containsWord(_ haystack: String, _ word: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        return haystack.range(of: #"(^|[^\p{L}\p{N}])"# + escaped + #"($|[^\p{L}\p{N}])"#, options: .regularExpression) != nil
    }

    private static func collapseSpaces(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
